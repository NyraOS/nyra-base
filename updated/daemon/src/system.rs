// SPDX-License-Identifier: GPL-3.0-or-later
//! The real [`System`]: bootc, systemctl, systemd-bless-boot and curl, each with a time limit.

use crate::{BootInfo, Deployment, Error, Status, System};
use nyra_channel_sheet::MAX_ENVELOPE_BYTES;
use serde::Deserialize;
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// Set by systemd-boot when it starts an entry that has a tries counter.
const LOADER_BOOT_COUNT_PATH: &str =
    "/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f";
const SHORT: Duration = Duration::from_secs(60);
/// Pulling a version: generous for slow links, but bounded, because bootc hangs forever when
/// the server goes away mid-download (`docs/LESSONS.md`). The next timer run retries;
/// layers already downloaded are kept.
const STAGE: Duration = Duration::from_secs(2 * 60 * 60);
/// Most output read from a command (bootc status is a few KiB); the rest is not read.
const MAX_OUTPUT: u64 = 1024 * 1024;

/// Runs `cmd` in its own process group. After `limit` the whole group is killed (bootc starts
/// helpers such as skopeo) and the result is [`Error::Timeout`].
pub fn run(cmd: &mut Command, limit: Duration) -> Result<Output, Error> {
    let what = format!("{:?}", cmd.get_program());
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .map_err(|e| Error::Command(format!("{what}: {e}")))?;
    let read = |pipe: Box<dyn Read + Send>| {
        thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = pipe.take(MAX_OUTPUT).read_to_end(&mut buf);
            buf
        })
    };
    let stdout = read(Box::new(child.stdout.take().expect("piped")));
    let stderr = read(Box::new(child.stderr.take().expect("piped")));
    let deadline = Instant::now() + limit;
    let status = loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|e| Error::Command(format!("{what}: {e}")))?
        {
            break status;
        }
        if Instant::now() >= deadline {
            // SAFETY: kill(2) with a negative pid signals the process group we created above.
            unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL) };
            let _ = child.wait();
            return Err(Error::Timeout(what));
        }
        thread::sleep(Duration::from_millis(50));
    };
    Ok(Output {
        status,
        stdout: stdout.join().unwrap_or_default(),
        stderr: stderr.join().unwrap_or_default(),
    })
}

/// [`run`], and a non-zero exit is an error carrying stderr.
fn run_ok(cmd: &mut Command, limit: Duration) -> Result<Vec<u8>, Error> {
    let out = run(cmd, limit)?;
    if !out.status.success() {
        return Err(Error::Command(format!(
            "{:?} failed ({}): {}",
            cmd.get_program(),
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        )));
    }
    Ok(out.stdout)
}

/// The fields of `bootc status --format json` this daemon needs.
pub fn parse_status(json: &[u8]) -> Result<Status, Error> {
    #[derive(Deserialize)]
    struct Host {
        status: HostStatus,
    }
    #[derive(Deserialize)]
    struct HostStatus {
        staged: Option<Entry>,
        booted: Option<Entry>,
        rollback: Option<Entry>,
        #[serde(rename = "rollbackQueued", default)]
        rollback_queued: bool,
    }
    #[derive(Deserialize)]
    struct Entry {
        image: Option<ImageStatus>,
    }
    #[derive(Deserialize)]
    struct ImageStatus {
        image: Option<ImageReference>,
        version: Option<String>,
        #[serde(rename = "imageDigest")]
        image_digest: String,
    }
    #[derive(Deserialize)]
    struct ImageReference {
        image: String,
        transport: String,
    }
    let host: Host =
        serde_json::from_slice(json).map_err(|e| Error::Command(format!("bootc status: {e}")))?;
    let dep = |e: Option<Entry>| {
        e.and_then(|e| e.image).map(|i| Deployment {
            digest: i.image_digest,
            version: i.version,
            image: i
                .image
                .filter(|r| r.transport == "registry")
                .map(|r| r.image),
        })
    };
    Ok(Status {
        booted: dep(host.status.booted),
        staged: dep(host.status.staged),
        rollback: dep(host.status.rollback),
        rollback_queued: host.status.rollback_queued,
    })
}

/// The curl command for the channel sheet: no `.curlrc` (`-q` must come first), HTTPS only with
/// TLS 1.2 or newer, no redirects, bounded in time and size, with our own User-Agent.
pub fn curl(url: &str) -> Command {
    let mut cmd = Command::new("curl");
    cmd.args([
        "-q",
        "--fail",
        "--silent",
        "--show-error",
        "--proto",
        "=https",
        "--tlsv1.2",
        "--max-time",
        "60",
        "--max-filesize",
        &MAX_ENVELOPE_BYTES.to_string(),
        "--user-agent",
        concat!("nyra-updated/", env!("CARGO_PKG_VERSION")),
        "--",
        url,
    ]);
    cmd
}

/// `systemd-bless-boot status`: the booted entry still counts tries. `indeterminate` while tries
/// are left, `dirty` on the last one (seen in the VM on the third try), `bad` once marked bad.
pub fn on_trial(bless_status: &str) -> bool {
    matches!(bless_status.trim(), "indeterminate" | "dirty" | "bad")
}

/// The staged deployment discarded on this boot (rules 7 and 11). It lives in `/run`, like bootc's
/// own record of the staged deployment, so it ends with this boot. `esp-sync` reads it at shutdown
/// and removes the staged boot entries before `bootc-finalize-staged` would swap them in.
pub const DISCARDED: &str = "/run/nyra-updated/discarded";

pub struct Real;

impl System for Real {
    fn status(&mut self) -> Result<Status, Error> {
        parse_status(&run_ok(
            Command::new("bootc").args(["status", "--format", "json"]),
            SHORT,
        )?)
    }

    fn boot_complete(&mut self) -> Result<bool, Error> {
        let out = run(
            Command::new("systemctl").args(["is-active", "--quiet", "boot-complete.target"]),
            SHORT,
        )?;
        Ok(out.status.success())
    }

    fn boot_info(&mut self) -> Result<BootInfo, Error> {
        let soft = run_ok(
            Command::new("systemctl").args(["show", "--property=SoftRebootsCount", "--value"]),
            SHORT,
        )?;
        // Prints good, bad, indeterminate, dirty or clean; exits non-zero for some of them.
        let bless = run(
            Command::new("/usr/lib/systemd/systemd-bless-boot").arg("status"),
            SHORT,
        )?;
        let bless = String::from_utf8_lossy(&bless.stdout);
        Ok(BootInfo {
            soft_rebooted: String::from_utf8_lossy(&soft)
                .trim()
                .parse::<u64>()
                .unwrap_or(0)
                > 0,
            on_trial: on_trial(&bless),
            counted: Path::new(LOADER_BOOT_COUNT_PATH).exists(),
        })
    }

    fn fetch_sheet(&mut self, url: &str) -> Result<Vec<u8>, Error> {
        let sheet = run_ok(&mut curl(url), SHORT)?;
        if sheet.len() > MAX_ENVELOPE_BYTES {
            return Err(Error::Sheet(nyra_channel_sheet::Error::TooLarge));
        }
        Ok(sheet)
    }

    fn stage(&mut self, image_ref: &str) -> Result<(), Error> {
        run_ok(
            Command::new("bootc").args(["switch", "--quiet", "--", image_ref]),
            STAGE,
        )
        .map(drop)
    }

    fn rollback(&mut self) -> Result<(), Error> {
        run_ok(Command::new("bootc").arg("rollback"), SHORT).map(drop)
    }

    fn discard_staged(&mut self, digest: &str) -> Result<(), Error> {
        let path = Path::new(DISCARDED);
        let dir = path.parent().expect("a directory");
        std::fs::create_dir_all(dir).map_err(|e| Error::Io(format!("{}: {e}", dir.display())))?;
        std::fs::write(path, digest).map_err(|e| Error::Io(format!("{DISCARDED}: {e}")))
    }

    fn discarded(&mut self) -> Result<Option<String>, Error> {
        match std::fs::read_to_string(DISCARDED) {
            Ok(d) => Ok(Some(d.trim().to_string())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(Error::Io(format!("{DISCARDED}: {e}"))),
        }
    }

    fn reboot(&mut self) -> Result<(), Error> {
        run_ok(Command::new("systemctl").arg("reboot"), SHORT).map(drop)
    }
}
