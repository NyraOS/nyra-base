// SPDX-License-Identifier: GPL-3.0-or-later
//! `nyra-updated`: the safety rules Nyra OS adds around bootc (`docs/UPDATES.md`; what bootc does
//! not do by itself is in `docs/LESSONS.md`).
//!
//! Two entry points, both run by systemd:
//!
//! - [`check`] (timer, after `boot-complete.target`): learns the outcome of the last update,
//!   fetches and verifies the signed channel sheet with `nyra-channel-sheet`, and prepares the
//!   version the sheet picks for this machine, pinned by digest, without applying it. The reboot
//!   stays the user's choice.
//! - [`on_health_failure`] (`OnFailure=` of the health checks): a full reboot while the new version
//!   is still on trial, so systemd-boot's boot counting can fall back to the previous one; off trial,
//!   the system stays up and the pending version is not blamed (rule 12).
//!
//! The rules, each with a unit test in `tests.rs`:
//!
//! 1. One update at a time ([`Lock`]); every bootc, systemctl and curl call has a time limit and
//!    is killed with its children when it hangs (`system::run`). A download that fails while the
//!    machine has no network is reported as that ([`Error::Offline`]), a warning: nothing is
//!    marked failed, and the next check tries again. A refusal (a signature, a digest, a
//!    certificate) stays what it is, even when the link went down at the same moment. Checks that
//!    have not succeeded for [`STALE_AFTER_DAYS`], whatever the cause, are reported as errors
//!    ([`Report`]).
//! 2. The sheet's sequence and retracted digests are written atomically to the state directory
//!    **before** anything acts on the sheet; a lower sequence is refused, an equal one only for
//!    the identical payload.
//! 3. A retracted digest is remembered and never a target again, even if a later sheet serves it;
//!    an installed version retracted by any accepted sheet may still go back.
//! 4. No downgrade ([`nyra_channel_sheet::Sheet::decide`]), and no target below the image's
//!    version floor, including signed retractions (a leaked old key cannot send machines back to
//!    any image ever signed).
//! 5. A version the machine fell back from is marked failed and never prepared or offered again
//!    (one exception: rule 15).
//! 6. A retraction to the version that is already the local rollback deployment uses
//!    `bootc rollback` (bootc would answer "No changes" to a switch), once: when bootc already
//!    reports that deployment as the next boot (`rollbackQueued`), a check before the reboot runs
//!    nothing, because a second `bootc rollback` would swap the boot order back. Not for a version
//!    forgiven under rule 12: that one is staged afresh, as there.
//! 7. The image is pulled pinned by digest, and the staged digest must be the sheet's; a wrong
//!    staged deployment is discarded: it is never finalized ([`System::discard_staged`]), whatever
//!    the rollback deployment is, and nothing else is staged until the next reboot.
//! 8. A failed health check reboots fully: never a soft reboot, always after a soft reboot (which
//!    bypasses boot counting), and never on a version that is not on trial (no reboot loop).
//! 9. The first healthy boot of a new version must have been a full boot with a boot counter
//!    (`LoaderBootCountPath` set by systemd-boot): otherwise it is reported as an error, not
//!    swallowed, because the counter service can fail silently and a soft reboot skips counting.
//!    This daemon never soft-reboots (the [`System`] trait has no soft reboot at all).
//! 10. Nothing is done when the booted image is not from [`HOST`] (fixed in code,
//!     `docs/SIGNING.md`): an owner who switched to their own image keeps it. The outcome says so
//!     ([`Outcome::ForeignImage`]), so such a machine is not silently without updates. Any
//!     repository on [`HOST`] is ours, so a version that moves its updates to another repository
//!     keeps getting them.
//! 11. A staged version that becomes unacceptable before the reboot (retracted, failed, or below the
//!     version floor) is discarded the same way as in rule 7. A rollback queued for the next boot
//!     (`rollbackQueued`) to such a version is undone with another `bootc rollback`, which puts the
//!     running version first again.
//! 12. A version is marked failed (rule 5) only when the version the machine fell back to passes its
//!     health checks. When the older version fails them too (a boot that is not on trial), the
//!     version fallen back from is forgiven instead, once: the machine's own settings (`/etc`) are
//!     what is broken. Once they are repaired the version is offered again (as an update or as the
//!     target of a retraction); a second fallback from it marks it failed. Its deployment, the
//!     rollback one by then, kept the `/etc` it was tried with (bootc keeps one per deployment), so
//!     it is deleted ([`System::delete_rollback`]) and the version staged afresh, on trial again.
//!     Once it boots healthy it is no longer forgiven.
//! 13. A version the machine went back from on purpose (`bootc rollback`, run by the user or by
//!     root; the only way a version that is neither failed, retracted nor forgiven becomes the
//!     rollback deployment) is not staged again ([`Outcome::HeldBack`], a warning: the machine runs
//!     a version without the latest fixes): the machine stays where the user put it until the sheet
//!     offers another version, or the running version is retracted.
//! 14. The channel is the one root chose ([`set_channel`]), or else the image's. After a change of
//!     channel (a choice, or a new image default on a machine without one), the new channel's
//!     version may be older than the running one: the machine goes to it anyway, once, but only
//!     with a sheet issued after the change (a replayed or old sheet cannot do it), and never to
//!     a version that rules 3-5 refuse. Until such a sheet comes, nothing is done
//!     ([`Outcome::WaitingForSheet`]). The version is staged afresh, never reached by
//!     `bootc rollback`: a rollback deployment kept the `/etc` of its time. Within a channel, an
//!     older version stays refused (rule 4).
//! 15. A version marked failed only by the network health check (its last try had carrier but no
//!     address, and the version fallen back to does not fail that check: `network-fallback` in the
//!     state directory, written by it) is tried once more ([`NetworkRetry`]): from a day later, or
//!     as soon as the machine is on another network (another list of links with an address,
//!     `network-links`). The version fallen back to passes when it gets an address, and also when
//!     it judges nothing (no carrier, no such link, `networkctl` lists no links): the cost is at
//!     most one more try, cheaper than telling those apart.
//!     It is staged afresh, like a forgiven version (rule 12). A second fallback from it is final.
//!     Any other failure is final at once, as before.
//!
//! Boot counting itself (`+3` on the new entry, `systemd-bless-boot` after `boot-complete.target`)
//! belongs to nyra-base (`docs/BOOT.md`); this crate only reads its state and never blesses a boot.
//! The install code never leaves the machine: it only feeds [`rollout_group`]. There is no
//! `/run/ostree/auth.json`.

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use ed25519_dalek::VerifyingKey;
use nyra_channel_sheet::{
    compare_versions, parse_public_keys, rollout_group, verify, Decision, Image,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub mod install;
pub mod system;

/// The public key of the `seed1` test fixture (private key = 32 bytes of 1, known to anyone).
const TEST_KEY: &str = include_str!("../../channel-sheet/tests/data/seed1.pub.pem");
/// Bytes of a new install code (at least 128 random bits; the code never leaves the machine).
const INSTALL_CODE_BYTES: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Sheet(nyra_channel_sheet::Error),
    /// A sheet with the accepted sequence but another payload.
    SameSequenceDifferentSheet(u64),
    /// The target was retracted by an accepted sheet.
    Retracted(String),
    /// The machine already fell back from the target.
    Failed(String),
    BelowFloor {
        version: String,
        floor: String,
    },
    DigestMismatch {
        expected: String,
        found: String,
    },
    NoBootedImage,
    /// A new version booted without boot counting (rule 9).
    NotBootCounted(String),
    /// The running version was retracted, and the machine could not leave it: the version the
    /// sheet sends it to is refused (rules 3-5), or its download failed.
    RetractedRunning {
        running: String,
        reason: Box<Error>,
    },
    /// Another `nyra-updated` holds the lock.
    Busy,
    Timeout(String),
    /// The download of the sheet or of the version failed while the machine had no network
    /// ([`System::offline`]): a warning, not a failure (`docs/UPDATES.md`).
    Offline(Box<Error>),
    /// No check has succeeded for [`STALE_AFTER_DAYS`] or more: the report of this one, which says
    /// for how long ([`Report`]).
    NoSuccessfulCheck(String),
    Command(String),
    Io(String),
    Config(String),
    /// A test fixture key in the production key file.
    TestKey,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Sheet(e) => write!(f, "{e}"),
            Error::SameSequenceDifferentSheet(s) => {
                write!(f, "channel sheet {s} differs from the accepted sheet {s}")
            }
            Error::Retracted(d) => write!(f, "refusing {d}: it was retracted"),
            Error::Failed(d) => write!(f, "refusing {d}: this machine fell back from it"),
            Error::BelowFloor { version, floor } => {
                write!(f, "refusing {version}: below the version floor {floor}")
            }
            Error::DigestMismatch { expected, found } => {
                write!(f, "staged {found}, expected {expected}")
            }
            Error::NoBootedImage => write!(f, "bootc reports no booted image"),
            Error::NotBootCounted(d) => write!(
                f,
                "{d} booted without a boot counter: an unhealthy version would not have fallen back"
            ),
            Error::RetractedRunning { running, reason } => write!(
                f,
                "the running version {running} was retracted and this check could not move the \
                 machine off it: {reason}"
            ),
            Error::Busy => write!(f, "another nyra-updated is running"),
            Error::Timeout(what) => write!(f, "{what} timed out and was stopped"),
            Error::Offline(e) => write!(
                f,
                "no network connection ({e}): the running version stays, the next check tries again"
            ),
            Error::NoSuccessfulCheck(e) | Error::Command(e) | Error::Io(e) | Error::Config(e) => {
                write!(f, "{e}")
            }
            Error::TestKey => write!(f, "the channel sheet key file holds a test key"),
        }
    }
}

impl std::error::Error for Error {}

impl From<nyra_channel_sheet::Error> for Error {
    fn from(e: nyra_channel_sheet::Error) -> Self {
        Error::Sheet(e)
    }
}

fn io(what: &Path, e: std::io::Error) -> Error {
    Error::Io(format!("{}: {e}", what.display()))
}

// --- configuration (from the image) -----------------------------------------------------------

/// The report of a check on an image without a channel sheet key (`docs/UPDATES.md`): a warning at
/// every check, never an error, as there is nothing to update from.
pub const NOT_CONFIGURED: &str =
    "updates are not configured: no channel sheet key in /usr/lib/nyra/updates/channel-sheet.pem";

/// The update server. Fixed in code, never configured: the image's signature policy requires our
/// signature only for exactly this registry scope (`docs/SIGNING.md`), so any other spelling (a port, a
/// trailing dot, another host) would pull system images without signature verification.
pub const HOST: &str = "updates.nyraos.com";
/// The channels the update server publishes.
pub const CHANNELS: [&str; 3] = ["dev", "beta", "stable"];

/// What the image says: which repository and channel, the trusted keys and the version floor.
#[derive(Debug, Clone)]
pub struct Config {
    pub repository: String,
    /// The image's default; a channel chosen on the machine wins (rule 14).
    pub channel: String,
    /// No target older than this, not even a signed retraction.
    pub version_floor: String,
    pub keys: Vec<VerifyingKey>,
    /// How long pulling a version may take before bootc is stopped (`stage_timeout_seconds`,
    /// optional): [`STAGE_TIMEOUT`], or shorter. Only the tests' images shorten it.
    pub stage_timeout: Duration,
}

/// Pulling a version: generous for slow links, but bounded, because bootc hangs forever when the
/// server goes away mid-download (`docs/LESSONS.md`). The next timer run retries; layers already
/// downloaded are kept.
pub const STAGE_TIMEOUT: Duration = Duration::from_secs(2 * 60 * 60);

/// An OCI repository name under [`HOST`]: `/`-separated components of lowercase letters, digits
/// and `._-`, each starting and ending with a letter or digit. No `:` (port or tag), no `@`.
fn is_repository(name: &str) -> bool {
    name.split('/').all(|c| {
        let alnum = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit();
        let bytes = c.as_bytes();
        !bytes.is_empty()
            && alnum(bytes[0])
            && alnum(bytes[bytes.len() - 1])
            && bytes.iter().all(|&b| alnum(b) || b"._-".contains(&b))
    })
}

impl Config {
    /// `conf`: `key = value` lines (`repository`, `channel`, `version_floor`, and optionally
    /// `stage_timeout_seconds`, at most the default), `#` comments.
    /// `pem`: the channel sheet keys. Everything is required: no defaults, no unknown or repeated
    /// keys (a repeated key must not silently win).
    pub fn parse(conf: &str, pem: &str) -> Result<Config, Error> {
        let mut map = BTreeMap::new();
        for line in conf.lines().map(str::trim) {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (k, v) = line
                .split_once('=')
                .ok_or_else(|| Error::Config(format!("not key = value: {line:?}")))?;
            if map
                .insert(k.trim().to_string(), v.trim().to_string())
                .is_some()
            {
                return Err(Error::Config(format!("{} is set twice", k.trim())));
            }
        }
        let stage_timeout = match map.remove("stage_timeout_seconds") {
            None => STAGE_TIMEOUT,
            Some(v) => v
                .parse::<u64>()
                .ok()
                .filter(|s| (1..=STAGE_TIMEOUT.as_secs()).contains(s))
                .map(Duration::from_secs)
                .ok_or_else(|| Error::Config("invalid stage_timeout_seconds".into()))?,
        };
        let mut get = |k: &str, valid: &dyn Fn(&str) -> bool| {
            map.remove(k)
                .filter(|v| valid(v))
                .ok_or_else(|| Error::Config(format!("missing or invalid {k}")))
        };
        let config = Config {
            repository: get("repository", &is_repository)?,
            channel: get("channel", &|v| CHANNELS.contains(&v))?,
            version_floor: get("version_floor", &|v| compare_versions(v, v).is_ok())?,
            keys: load_keys(pem)?,
            stage_timeout,
        };
        if let Some(k) = map.keys().next() {
            return Err(Error::Config(format!("unknown key {k}")));
        }
        Ok(config)
    }

    /// Reads the configuration files of the image. `Ok(None)`: the key file holds no key, so
    /// updates are not configured (every sheet would be refused; there is nothing to check). A
    /// missing or unreadable file, a broken key or an invalid configuration is an error.
    pub fn load(conf: &Path, keys: &Path) -> Result<Option<Config>, Error> {
        let read = |p: &Path| fs::read_to_string(p).map_err(|e| io(p, e));
        match Config::parse(&read(conf)?, &read(keys)?) {
            Ok(cfg) => Ok(Some(cfg)),
            Err(Error::Sheet(nyra_channel_sheet::Error::NoTrustedKeys)) => Ok(None),
            Err(e) => Err(e),
        }
    }

    pub fn sheet_url(&self) -> String {
        format!(
            "https://{HOST}/channels/{}/{}",
            self.repository, self.channel
        )
    }

    /// The image reference, pinned by digest (never a tag).
    pub fn image_ref(&self, digest: &str) -> String {
        format!("{HOST}/{}@{}", self.repository, digest)
    }

    /// The booted image comes from our registry, any repository (`bootc status` reference, by tag
    /// or digest): a version may move its updates to another repository (rule 10). Anything else
    /// was chosen on purpose by the machine's owner.
    pub fn is_official(&self, image: Option<&str>) -> bool {
        image
            .and_then(|i| i.strip_prefix(HOST))
            .and_then(|i| i.strip_prefix('/'))
            .and_then(|i| i.find([':', '@']).map(|n| i.split_at(n)))
            .is_some_and(|(repository, _)| is_repository(repository))
    }

    fn sheet_key(&self) -> String {
        format!("{}:{}", self.repository, self.channel)
    }
}

/// The trusted channel sheet keys, refusing the `seed1` test fixture (its private key is known).
pub fn load_keys(pem: &str) -> Result<Vec<VerifyingKey>, Error> {
    let keys = parse_public_keys(pem)?;
    if keys.is_empty() {
        return Err(Error::Sheet(nyra_channel_sheet::Error::NoTrustedKeys));
    }
    let test = parse_public_keys(TEST_KEY)?;
    if keys.iter().any(|k| test.contains(k)) {
        return Err(Error::TestKey);
    }
    Ok(keys)
}

// --- persisted state --------------------------------------------------------------------------

/// The last sheet accepted for a repository and channel.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Accepted {
    pub sequence: u64,
    /// SHA-256 (hex) of the sheet's payload bytes.
    pub payload_sha256: String,
}

/// Everything `nyra-updated` remembers, in `<state dir>/state.json`. Unknown fields are ignored
/// and missing ones default, so an older daemon (after a rollback) still reads a newer file.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct State {
    /// Key `repository:channel`.
    pub sheets: BTreeMap<String, Accepted>,
    /// Every digest retracted by an accepted sheet.
    pub retracted: BTreeSet<String>,
    /// Digests this machine fell back from.
    pub failed: BTreeSet<String>,
    /// The digest prepared by the last update and not yet confirmed good.
    pub pending: Option<String>,
    /// The last digest forgiven under rule 12, until it boots healthy: a second fallback from it
    /// marks it failed. One digest, not a set: an older daemon (booted after a rollback) must still
    /// read the file, and a forgiven version that comes back after another was forgiven only costs
    /// three more boots (`docs/UPDATES.md`).
    pub forgiven: Option<String>,
    /// The channel root chose ([`set_channel`]); `None`: the image's (rule 14).
    pub channel: Option<String>,
    /// The channel the last check followed.
    pub following: Option<String>,
    /// When a check first followed another channel than before (Unix seconds), until the machine
    /// has acted on the new one: going to an older version is allowed only with a sheet issued
    /// from then on, and only once (rule 14).
    pub channel_changed: Option<u64>,
    /// The version marked failed only by the network health check, which is tried once more
    /// (rule 15). One version, like `forgiven`; an older daemon drops it and keeps it failed.
    pub network_retry: Option<NetworkRetry>,
}

/// A version marked failed only by the network health check (rule 15).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworkRetry {
    pub digest: String,
    /// When it was marked failed (Unix seconds).
    pub failed_at: u64,
    /// The links with a routable address then (`network-links`).
    pub links: String,
    /// Taken off the failed list and staged again: a second fallback from it is final.
    pub retried: bool,
}

impl NetworkRetry {
    /// Its second try is due: not taken yet, and a day has passed or the network is another.
    fn due(&self, digest: &str, now: u64, links: &str) -> bool {
        self.digest == digest
            && !self.retried
            && (now >= self.failed_at.saturating_add(DAY_SECONDS) || self.links != links)
    }
}

/// The state directory (`/var/lib/nyra-updated`, 0700, files 0600).
pub struct Store {
    pub dir: PathBuf,
}

impl Store {
    fn ensure_dir(&self) -> Result<(), Error> {
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.dir)
            .map_err(|e| io(&self.dir, e))?;
        fs::set_permissions(&self.dir, fs::Permissions::from_mode(0o700))
            .map_err(|e| io(&self.dir, e))
    }

    /// A missing file is a first run. A file that does not parse is an error: the daemon stops
    /// rather than forget the sequence and the retractions (fail closed).
    pub fn load(&self) -> Result<State, Error> {
        let path = self.dir.join("state.json");
        match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| io(&path, e.into())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(State::default()),
            Err(e) => Err(io(&path, e)),
        }
    }

    /// Atomic: a temporary file, fsync, rename over the old one, fsync of the directory. A crash
    /// at any point leaves either the old state or the new one.
    pub fn save(&self, state: &State) -> Result<(), Error> {
        let bytes = serde_json::to_vec_pretty(state).expect("state serializes");
        self.write_atomic("state.json", &bytes)
    }

    fn write_atomic(&self, name: &str, bytes: &[u8]) -> Result<(), Error> {
        self.ensure_dir()?;
        let path = self.dir.join(name);
        let tmp = self.dir.join(format!("{name}.tmp"));
        let mut f = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(|e| io(&tmp, e))?;
        f.write_all(bytes).map_err(|e| io(&tmp, e))?;
        f.sync_all().map_err(|e| io(&tmp, e))?;
        fs::rename(&tmp, &path).map_err(|e| io(&path, e))?;
        File::open(&self.dir)
            .and_then(|d| d.sync_all())
            .map_err(|e| io(&self.dir, e))
    }

    /// Writes the outcome of this check (`time`: Unix seconds) to `last-check.json` and returns
    /// it, keeping the time of the last successful check from the previous report. A failed check
    /// [`STALE_AFTER_DAYS`] or more after it says so first: "no successful check for N days: …".
    /// [`NOT_CONFIGURED`] is no failed check (no update is held up): the count starts again. The
    /// message is stored as [`one_line`]. Callers hold the [`Lock`]: the file has one writer.
    pub fn save_report(&self, time: u64, ok: bool, message: &str) -> Result<Report, Error> {
        let path = self.dir.join("last-check.json");
        let message = one_line(message);
        // A report without `last_success` (written by an older nyra-updated, after a rollback) or
        // none at all: the count starts now.
        let previous = fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Report>(&bytes).ok())
            .map(|r| r.last_success);
        // A failed check keeps the last success as it is, even one later than now: the clock may
        // be behind at this check (a dead RTC, offline), and a time from it would count days that
        // never passed once the clock is right. A success that reads the sheet needs one that has
        // not expired (at most 31 days of validity), so a clock that was ahead then delays the
        // count by at most that.
        let last_success = match (ok || message == NOT_CONFIGURED, previous) {
            (false, Some(t)) => t,
            _ => time,
        };
        let mut report = Report {
            time,
            ok,
            message: message.clone(),
            last_success,
        };
        if let Some(days) = report.days_without_success() {
            report.message = one_line(&format!("no successful check for {days} days: {message}"));
        }
        let bytes = serde_json::to_vec(&report).expect("the report serializes");
        self.write_atomic("last-check.json", &bytes)?;
        Ok(report)
    }

    /// The links with a routable address at this check (`network-links`, written by
    /// `/usr/lib/nyra/health/network record` just before it); empty when there is none.
    pub fn network_links(&self) -> String {
        fs::read_to_string(self.dir.join("network-links")).unwrap_or_default()
    }

    /// Whether the network health check says that the version just fallen back from failed only
    /// that check (`network-fallback`, written on the boot after the fallback). Taken by every
    /// check: it is about the fallback the next check settles, never a later one.
    pub fn take_network_fallback(&self) -> Result<bool, Error> {
        let path = self.dir.join("network-fallback");
        match fs::remove_file(&path) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(io(&path, e)),
        }
    }

    /// The install code: 32 random bytes made on first use, kept in `install-code` (0600). It
    /// never leaves the machine; it only picks the rollout group.
    pub fn install_code(&self) -> Result<Vec<u8>, Error> {
        let path = self.dir.join("install-code");
        match fs::read(&path) {
            Ok(code) => Ok(code),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let mut code = vec![0u8; INSTALL_CODE_BYTES];
                File::open("/dev/urandom")
                    .and_then(|mut r| r.read_exact(&mut code))
                    .map_err(|e| io(Path::new("/dev/urandom"), e))?;
                self.write_atomic("install-code", &code)?;
                Ok(code)
            }
            Err(e) => Err(io(&path, e)),
        }
    }
}

/// The longest message written to the journal or to `last-check.json`, in characters.
pub const MAX_MESSAGE: usize = 2000;

/// `text` as one line that is safe to log and store: what bootc and curl print can come from the
/// registry or the server, and a control character (a newline followed by `<0>`, an escape
/// sequence) would forge journal lines or garble a terminal. Control characters become spaces, and
/// the text is cut at [`MAX_MESSAGE`] characters.
pub fn one_line(text: &str) -> String {
    let mut line: String = text
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .take(MAX_MESSAGE)
        .collect();
    if text.chars().nth(MAX_MESSAGE).is_some() {
        line.push('…');
    }
    line
}

/// After this many days without a successful check, every check that fails is an error, whatever
/// the cause, a lost network included: someone who controls the machine's link could otherwise
/// keep it on an old version with only warnings to show. Two weeks: a laptop offline for a holiday
/// is not flagged, and a server signs the sheet at least daily.
pub const STALE_AFTER_DAYS: u64 = 14;

const DAY_SECONDS: u64 = 24 * 60 * 60;

/// The outcome of the last check, `last-check.json`: a broken state or an image without updates
/// must not stay silent. The journal has the same line; Settings will read this file through the
/// daemon.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Report {
    /// Unix seconds.
    pub time: u64,
    pub ok: bool,
    pub message: String,
    /// The last check that was ok or found updates not configured (Unix seconds); until one is, the
    /// first check reported.
    pub last_success: u64,
}

impl Report {
    /// Whole days since the last successful check, when this check failed too and they are
    /// [`STALE_AFTER_DAYS`] or more.
    pub fn days_without_success(&self) -> Option<u64> {
        let days = self.time.saturating_sub(self.last_success) / DAY_SECONDS;
        (!self.ok && days >= STALE_AFTER_DAYS).then_some(days)
    }
}

/// One update at a time: an exclusive lock on a file, held until dropped. A second holder gets
/// [`Error::Busy`] at once instead of queueing behind a bootc that may hang (`docs/LESSONS.md`).
pub struct Lock(#[allow(dead_code)] File);

impl Lock {
    pub fn acquire(path: &Path) -> Result<Lock, Error> {
        let f = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(path)
            .map_err(|e| io(path, e))?;
        match f.try_lock() {
            Ok(()) => Ok(Lock(f)),
            Err(fs::TryLockError::WouldBlock) => Err(Error::Busy),
            Err(fs::TryLockError::Error(e)) => Err(io(path, e)),
        }
    }
}

// --- what the system reports ------------------------------------------------------------------

/// A deployment as `bootc status` reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Deployment {
    pub digest: String,
    pub version: Option<String>,
    /// The image reference it was pulled by, for the `registry` transport only.
    pub image: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Status {
    pub booted: Option<Deployment>,
    pub staged: Option<Deployment>,
    pub rollback: Option<Deployment>,
    /// The rollback deployment is the next boot (`bootc rollback` was run).
    pub rollback_queued: bool,
}

impl Status {
    fn digest(d: &Option<Deployment>) -> Option<&str> {
        d.as_ref().map(|d| d.digest.as_str())
    }
}

/// The current boot as systemd sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BootInfo {
    /// A soft reboot happened since the last full boot: boot counting did not run for the
    /// version now running.
    pub soft_rebooted: bool,
    /// The booted entry is on trial (systemd-boot counts its tries; `systemd-bless-boot status`
    /// is `indeterminate`, `dirty` on the last try, or `bad`).
    pub on_trial: bool,
    /// systemd-boot started this boot's entry with a tries counter (`LoaderBootCountPath`).
    pub counted: bool,
}

/// Everything that touches the machine. The real one is [`system::Real`]; the tests use a fake.
/// Every call returns within its time limit.
pub trait System {
    fn status(&mut self) -> Result<Status, Error>;
    /// `boot-complete.target` is active: the health checks passed on this boot.
    fn boot_complete(&mut self) -> Result<bool, Error>;
    fn boot_info(&mut self) -> Result<BootInfo, Error>;
    fn fetch_sheet(&mut self, url: &str) -> Result<Vec<u8>, Error>;
    /// The machine has no network now (no link up with an address), as systemd-networkd sees it.
    fn offline(&mut self) -> bool;
    /// Prepares `image_ref` for the next boot, without applying it (`bootc switch`).
    fn stage(&mut self, image_ref: &str) -> Result<(), Error>;
    /// Discards a staged deployment and swaps the boot order (`bootc rollback`): the rollback
    /// deployment becomes the next boot, or, if it already was, the booted one again. Fails when
    /// there is no rollback deployment.
    fn rollback(&mut self) -> Result<(), Error>;
    /// Deletes the rollback deployment, its boot entries and its `/etc` (`bootc delete-deployment`),
    /// only if its image is `digest`.
    fn delete_rollback(&mut self, digest: &str) -> Result<(), Error>;
    /// The staged deployment (this digest) must never boot: its staged boot entries are removed now
    /// and again at shutdown, so it is not finalized and the boot entries stay as they are
    /// (`/run/nyra-updated/discarded`, `esp-sync`). Until the next reboot, anything staged is
    /// discarded with it. An error after the digest is recorded still leaves it unfinalized.
    fn discard_staged(&mut self, digest: &str) -> Result<(), Error>;
    /// The digest discarded on this boot, if any.
    fn discarded(&mut self) -> Result<Option<String>, Error>;
    /// A full reboot. There is deliberately no soft reboot here.
    fn reboot(&mut self) -> Result<(), Error>;
}

// --- the rules --------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// `boot-complete.target` is not active: nothing is done on a boot that is not healthy.
    NotHealthy,
    /// The booted image is not from our registry and repository: the owner chose it, nothing
    /// is done (rule 10).
    ForeignImage(Option<String>),
    UpToDate,
    /// The target is already the next boot (staged, or the rollback deployment after
    /// `bootc rollback`); the user reboots when they want.
    WaitingForReboot(Image),
    Staged(Image),
    /// The target is the local rollback deployment: `bootc rollback` made it the next boot.
    RolledBack(Image),
    /// The staged deployment (this digest) must not boot and was discarded (rules 7 and 11); nothing
    /// more happens until the next reboot.
    Discarded(String),
    /// A rollback to this digest was queued for the next boot, and it must not boot: another
    /// `bootc rollback` put the running version first again (rule 11).
    RollbackUndone(String),
    /// The machine went back from the target by a rollback: it is not staged again (rule 13).
    HeldBack(Image),
    /// The channel changed and its version is older than the running one: going to it needs a
    /// sheet issued after the change (rule 14).
    WaitingForSheet(Image),
}

impl Outcome {
    /// The journal priority (sd-daemon: 4 warning, 6 info) and the line. A machine that gets no
    /// updates says so as a warning at every check: an owner's own image (rule 10), or a version the
    /// user went back from (rule 13), which leaves the machine without the latest fixes.
    pub fn report(&self) -> (u8, String) {
        match self {
            Outcome::ForeignImage(_) => (4, format!("{self:?}")),
            Outcome::HeldBack(target) => (
                4,
                format!(
                    "this machine went back from {} ({}) to an older version, without the latest \
                     fixes: {} is not installed again, the next version the channel offers will be",
                    target.version, target.digest, target.version
                ),
            ),
            _ => (6, format!("{self:?}")),
        }
    }
}

/// Rule 14: from now on this machine follows `channel` (one of [`CHANNELS`]), whatever the image
/// says. Root only: the state is root's.
pub fn set_channel(store: &Store, channel: &str) -> Result<(), Error> {
    if !CHANNELS.contains(&channel) {
        return Err(Error::Config(format!(
            "unknown channel {channel:?}: not one of {}",
            CHANNELS.join(", ")
        )));
    }
    let mut state = store.load()?;
    state.channel = Some(channel.to_string());
    store.save(&state)
}

/// SHA-256 (hex) of the payload of a sheet envelope that [`verify`] accepted.
fn payload_sha256(envelope: &[u8]) -> Result<String, Error> {
    #[derive(Deserialize)]
    struct Envelope {
        payload: String,
    }
    let bad = || Error::Sheet(nyra_channel_sheet::Error::Malformed("payload".into()));
    let env: Envelope = serde_json::from_slice(envelope).map_err(|_| bad())?;
    let payload = BASE64.decode(env.payload).map_err(|_| bad())?;
    Ok(Sha256::digest(payload)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// The machine came back from `digest`: it is the rollback deployment, and not the booted one.
fn fell_back_from(status: &Status, digest: &str) -> bool {
    Status::digest(&status.rollback) == Some(digest)
        && Status::digest(&status.booted) != Some(digest)
}

/// Learns what became of the version prepared last time (rule 5). `network_fallback`, `links` and
/// `now`: for a fallback caused only by the network health check (rule 15).
fn settle_pending(
    state: &mut State,
    status: &Status,
    network_fallback: bool,
    links: &str,
    now: u64,
) {
    let Some(pending) = state.pending.clone() else {
        return;
    };
    if Status::digest(&status.staged) == Some(&pending) {
        return; // still waiting for the reboot
    }
    if fell_back_from(status, &pending) {
        // It booted and the machine came back: systemd-boot's fallback after three tries.
        state.failed.insert(pending.clone());
        let second_try = state
            .network_retry
            .as_ref()
            .is_some_and(|r| r.digest == pending && r.retried);
        if network_fallback && !second_try {
            state.network_retry = Some(NetworkRetry {
                digest: pending,
                failed_at: now,
                links: links.into(),
                retried: false,
            });
        }
    } else if Status::digest(&status.booted) == Some(&pending) {
        // Booted healthy: a fallback (rule 12) or a failed network check (rule 15) is behind it.
        if state.forgiven.as_ref() == Some(&pending) {
            state.forgiven = None;
        }
        if state
            .network_retry
            .as_ref()
            .is_some_and(|r| r.digest == pending)
        {
            state.network_retry = None;
        }
    }
    // Booted and healthy, failed, or staging never finished (retried below): settled.
    state.pending = None;
}

/// Rules 3-5 on the version a sheet picked.
pub fn check_target(target: &Image, state: &State, floor: &str) -> Result<(), Error> {
    if state.retracted.contains(&target.digest) {
        return Err(Error::Retracted(target.digest.clone()));
    }
    if state.failed.contains(&target.digest) {
        return Err(Error::Failed(target.digest.clone()));
    }
    if compare_versions(&target.version, floor)? == Ordering::Less {
        return Err(Error::BelowFloor {
            version: target.version.clone(),
            floor: floor.to_string(),
        });
    }
    Ok(())
}

/// Rules 3-5 on a local deployment: retracted, failed, or below the version floor.
fn unacceptable(d: &Deployment, state: &State, floor: &str) -> bool {
    let below_floor = match d.version.as_deref().map(|v| compare_versions(v, floor)) {
        Some(Ok(order)) => order == Ordering::Less,
        // No version, or one that does not parse: refused, as in `check_target`.
        _ => true,
    };
    state.retracted.contains(&d.digest) || state.failed.contains(&d.digest) || below_floor
}

/// The local version "go back to the previous version" may offer: the rollback deployment, unless
/// it is unacceptable (rule 11 would undo the rollback), the machine fell back from it (failed, or
/// forgiven under rule 12), or bootc already reports it as the next boot (`rollbackQueued`): a
/// rollback already queued, or a version fallen back from, since bootc does not see boot counting.
pub fn offered_rollback<'a>(
    status: &'a Status,
    state: &State,
    floor: &str,
) -> Option<&'a Deployment> {
    status.rollback.as_ref().filter(|d| {
        !status.rollback_queued
            && state.forgiven.as_ref() != Some(&d.digest)
            && !unacceptable(d, state, floor)
    })
}

/// A download that failed while the machine has no network (a laptop offline, the link lost in
/// the middle of a pull) is [`Error::Offline`]: nothing is wrong with the server or the version.
/// Only the machine's own link state counts: a server or a network that stops answering while the
/// link is up stays an error. So does a refusal ([`REFUSALS`]), even if the link went down at the
/// same moment. Only what comes from running a command or from its timeout can be a lost link: any
/// other error (a bad sheet, a failed verification) is not about the network, whatever its text.
fn when_offline(sys: &mut impl System, e: Error) -> Error {
    if !matches!(e, Error::Command(_) | Error::Timeout(_)) {
        return e;
    }
    let message = e.to_string().to_lowercase();
    if REFUSALS.iter().any(|r| message.contains(r)) || !sys.offline() {
        return e;
    }
    Error::Offline(Box::new(e))
}

/// What bootc (with the image proxy under it) and curl say when they refuse what they were sent: a
/// signature ("A signature was required, but no signature exists", "Source image rejected"), a
/// digest ("corrupted blob, expecting …", "does not match"), a certificate. Lowercase. Not "digest"
/// alone: bootc names the image config's digest in the context of any failed pull.
const REFUSALS: [&str; 7] = [
    "signature",
    "rejected",
    "corrupted",
    "mismatch",
    "does not match",
    "did not match",
    "certificate",
];

/// One update check (see the crate documentation). `now`: Unix seconds.
pub fn check(
    sys: &mut impl System,
    store: &Store,
    cfg: &Config,
    now: u64,
) -> Result<Outcome, Error> {
    if !sys.boot_complete()? {
        return Ok(Outcome::NotHealthy);
    }
    let mut state = store.load()?;
    let status = sys.status()?;
    let booted = status.booted.clone().ok_or(Error::NoBootedImage)?;
    if !cfg.is_official(booted.image.as_deref()) {
        return Ok(Outcome::ForeignImage(booted.image));
    }

    let first_boot_of_pending = state.pending.as_deref() == Some(booted.digest.as_str());
    let before = state.clone();
    let network_fallback = store.take_network_fallback()?;
    let links = store.network_links();
    settle_pending(&mut state, &status, network_fallback, &links, now);
    if state != before {
        store.save(&state)?;
    }
    if first_boot_of_pending {
        // Rule 9. Reported once: the pending version is settled above.
        let info = sys.boot_info()?;
        if info.soft_rebooted || !info.counted {
            return Err(Error::NotBootCounted(booted.digest));
        }
    }
    // Rules 7 and 11: after a discard nothing is staged until the next reboot.
    if let Some(digest) = sys.discarded()? {
        return Ok(Outcome::Discarded(digest));
    }

    // Rule 14: the channel this machine follows, and whether it just changed.
    let channel = state.channel.clone().unwrap_or_else(|| cfg.channel.clone());
    if !CHANNELS.contains(&channel.as_str()) {
        return Err(Error::Config(format!(
            "unknown channel {channel:?} in the state"
        )));
    }
    if state.following.as_ref() != Some(&channel) {
        if state.following.is_some() {
            // Not before the newest sheet already accepted (a sequence is the time of issue): a
            // clock that is behind cannot let an older sheet through.
            let newest = state.sheets.values().map(|a| a.sequence).max().unwrap_or(0);
            state.channel_changed = Some(now.max(newest));
        }
        // Saved with the sheet below (rule 2): a sheet refused before that changes nothing.
        state.following = Some(channel.clone());
    }
    let cfg = &Config {
        channel,
        ..cfg.clone()
    };

    // Rule 2: verify, then persist the sequence and the retractions before acting.
    let envelope = sys
        .fetch_sheet(&cfg.sheet_url())
        .map_err(|e| when_offline(sys, e))?;
    let key = cfg.sheet_key();
    let last = state.sheets.get(&key).cloned();
    let sheet = verify(
        &envelope,
        &cfg.keys,
        &cfg.repository,
        &cfg.channel,
        now,
        last.as_ref().map(|a| a.sequence),
    )?;
    let hash = payload_sha256(&envelope)?;
    if let Some(a) = &last {
        if a.sequence == sheet.sequence && a.payload_sha256 != hash {
            return Err(Error::SameSequenceDifferentSheet(sheet.sequence));
        }
    }
    state.sheets.insert(
        key,
        Accepted {
            sequence: sheet.sequence,
            payload_sha256: hash,
        },
    );
    state.retracted.extend(sheet.retracted.iter().cloned());
    store.save(&state)?;

    // Rule 11: a staged version that must not boot is discarded now, not after the reboot.
    let floor = cfg.version_floor.as_str();
    if let Some(staged) = &status.staged {
        if unacceptable(staged, &state, floor) {
            sys.discard_staged(&staged.digest)?;
            state.pending = None;
            store.save(&state)?;
            return Ok(Outcome::Discarded(staged.digest.clone()));
        }
    }
    // Rule 11 for a queued rollback (by the user, or rule 6 before a later sheet). After a fallback
    // bootc still reports the failed version as the next boot; this sets its order right too.
    if let Some(rollback) = &status.rollback {
        if status.rollback_queued && unacceptable(rollback, &state, floor) {
            sys.rollback()?;
            return Ok(Outcome::RollbackUndone(rollback.digest.clone()));
        }
    }

    let installed = Image {
        digest: booted.digest.clone(),
        version: booted.version.clone().unwrap_or_default(),
    };
    let group = rollout_group(&store.install_code()?, &sheet)?;
    // Rule 3: decide with every retraction remembered, not only the ones this sheet still lists.
    let mut sheet = sheet;
    sheet.retracted = state.retracted.iter().cloned().collect();
    let target_staged = Status::digest(&status.staged) == Some(sheet.target(group).digest.as_str());
    let decision = match (sheet.decide(&installed, group), state.channel_changed) {
        // An older version already staged (by rule 14, at an earlier check): like any staged
        // version, it waits for the reboot.
        (Err(nyra_channel_sheet::Error::Downgrade { .. }), _) if target_staged => {
            return Ok(Outcome::WaitingForReboot(sheet.target(group).clone()));
        }
        // Rule 14: an older version, right after a change of channel.
        (Err(nyra_channel_sheet::Error::Downgrade { .. }), Some(changed)) => {
            let target = sheet.target(group).clone();
            if sheet.issued_at < changed {
                return Ok(Outcome::WaitingForSheet(target));
            }
            check_target(&target, &state, floor)?;
            // Never `bootc rollback` here: the rollback deployment kept the `/etc` of its time
            // (bootc keeps one per deployment), so a routine change of channel would bring back
            // old passwords, accounts and settings. It is deleted, and the version staged like
            // any update: merged with today's settings, on trial.
            if Status::digest(&status.rollback) == Some(&target.digest) {
                sys.delete_rollback(&target.digest)?;
            }
            let outcome = stage_target(sys, store, cfg, &mut state, target)?;
            state.channel_changed = None;
            store.save(&state)?;
            return Ok(outcome);
        }
        (decision, _) => decision?,
    };
    // Rule 14: the machine follows the new channel as usual from now on.
    if state.channel_changed.take().is_some() {
        store.save(&state)?;
    }
    let (target, retraction) = match decision {
        Decision::UpToDate => return Ok(Outcome::UpToDate),
        Decision::Update(t) => (t, false),
        Decision::Retract(t) => (t, true),
    };
    let running_retracted = state.retracted.contains(&booted.digest);
    // Rule 15: the second try of a version failed only by the network health check.
    if let Some(retry) = state.network_retry.as_mut() {
        if retry.due(&target.digest, now, &links) && state.failed.remove(&target.digest) {
            retry.retried = true;
            store.save(&state)?;
        }
    }
    let network_retry = state
        .network_retry
        .as_ref()
        .is_some_and(|r| r.digest == target.digest && r.retried);
    // Whatever keeps the machine on a retracted version (a refused target, a failed download), the
    // report says that it still runs one.
    let still_retracted = |e: Error| {
        if running_retracted {
            Error::RetractedRunning {
                running: booted.digest.clone(),
                reason: Box::new(e),
            }
        } else {
            e
        }
    };
    check_target(&target, &state, floor).map_err(still_retracted)?;

    if Status::digest(&status.staged) == Some(&target.digest) {
        return Ok(Outcome::WaitingForReboot(target));
    }
    if Status::digest(&status.rollback) == Some(&target.digest) {
        if state.forgiven.as_ref() != Some(&target.digest) && !network_retry {
            // Already the next boot (rule 6 ran, or the user queued it): another `bootc rollback`
            // would swap the order back.
            if status.rollback_queued {
                return Ok(Outcome::WaitingForReboot(target));
            }
            // Rule 6.
            if retraction {
                sys.rollback().map_err(still_retracted)?;
                return Ok(Outcome::RolledBack(target));
            }
            // Rule 13: the machine went back from it on purpose.
            if !running_retracted {
                return Ok(Outcome::HeldBack(target));
            }
        }
        // Rule 12: a version offered again after it was forgiven (a newer one, or the target of a
        // retraction), and rule 15: its second try after a failed network check. Its deployment
        // would boot with the settings it was tried with, not today's, and has no tries left
        // (bootc still reports it as the next boot: `rollbackQueued` does not see boot
        // counting): it goes, and the version is staged like any update. The same when the
        // running version is retracted and the target is one the user went back from.
        sys.delete_rollback(&target.digest)
            .map_err(still_retracted)?;
    }
    stage_target(sys, store, cfg, &mut state, target).map_err(still_retracted)
}

/// Stages `target`, pinned by digest, as the pending version (rule 7).
fn stage_target(
    sys: &mut impl System,
    store: &Store,
    cfg: &Config,
    state: &mut State,
    target: Image,
) -> Result<Outcome, Error> {
    state.pending = Some(target.digest.clone());
    store.save(state)?;
    sys.stage(&cfg.image_ref(&target.digest))
        .map_err(|e| when_offline(sys, e))?;
    let after = sys.status()?;
    let staged = Status::digest(&after.staged)
        .unwrap_or_default()
        .to_string();
    if staged != target.digest {
        // Rule 7: the wrong deployment must not boot.
        if after.staged.is_some() {
            sys.discard_staged(&staged)?;
        }
        return Err(Error::DigestMismatch {
            expected: target.digest,
            found: staged,
        });
    }
    Ok(Outcome::Staged(target))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HealthAction {
    /// Full reboot started: the next try, or systemd-boot's fallback.
    Reboot,
    /// The running version is not on trial: a reboot would boot it again (a loop). It stays up,
    /// unhealthy, for the user and the repair tools. It holds the version fallen back from, if it
    /// was forgiven (rule 12).
    Stay(Option<String>),
}

/// A health check failed on this boot (rules 8 and 12). Off trial, it takes `lock` (rule 1), the
/// one [`check`] runs under, before it reads the state; with a pending version it reads
/// `bootc status`. A lock held by a check is an error: the version stays unforgiven.
pub fn on_health_failure(
    sys: &mut impl System,
    store: &Store,
    lock: &Path,
) -> Result<HealthAction, Error> {
    let info = sys.boot_info()?;
    if info.soft_rebooted || info.on_trial {
        sys.reboot()?;
        return Ok(HealthAction::Reboot);
    }
    // Rule 12: if the machine fell back from the pending version and this older one fails too,
    // the settings are to blame, not that version: it is forgiven, once. Anything else (a version
    // only staged, or booted without a boot counter: rule 9) stays for the next check to settle.
    let _lock = Lock::acquire(lock)?;
    let mut state = store.load()?;
    let Some(pending) = state.pending.clone() else {
        return Ok(HealthAction::Stay(None));
    };
    if !fell_back_from(&sys.status()?, &pending) || state.forgiven.as_ref() == Some(&pending) {
        return Ok(HealthAction::Stay(None));
    }
    state.pending = None;
    state.forgiven = Some(pending.clone());
    store.save(&state)?;
    Ok(HealthAction::Stay(Some(pending)))
}

#[cfg(test)]
mod tests;
