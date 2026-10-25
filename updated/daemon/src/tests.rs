// SPDX-License-Identifier: GPL-3.0-or-later
//! One test (at least) per rule of the crate documentation, with a fake [`System`].

use super::system::{
    curl, esp_sync_discard, on_trial, parse_status, rollback_id, run, DISCARDED, SHORT,
};
use super::*;
use ed25519_dalek::{Signer, SigningKey};
use nyra_channel_sheet::{pae, PAYLOAD_TYPE};
use serde_json::{json, Value};
use std::os::fd::AsRawFd;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

const NOW: u64 = 1_791_547_200; // 2026-10-09T12:00:00Z
const DAY: u64 = 24 * 60 * 60;
const Z: &str = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
const A: &str = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B: &str = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const C: &str = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const SHEET_URL: &str = "https://updates.nyraos.com/channels/nyra/stable";
const FLOOR: &str = "2026.10.1";

fn version(d: &str) -> &'static str {
    match d {
        Z => "2026.9.1",
        A => "2026.10.1",
        B => "2026.10.2",
        C => "2026.10.3",
        _ => unreachable!(),
    }
}

fn image(d: &str) -> Image {
    Image {
        digest: d.into(),
        version: version(d).into(),
    }
}

fn dep(d: &str) -> Option<Deployment> {
    Some(Deployment {
        digest: d.into(),
        version: Some(version(d).into()),
        image: Some(format!("updates.nyraos.com/nyra@{d}")),
    })
}

/// Held by the lock test and by every test that starts a process. A child started by another
/// test thread holds a copy of every open fd between fork and exec (O_CLOEXEC closes it only at
/// exec), so for a few milliseconds it can keep the lock file's flock alive after `drop`.
static SPAWN: Mutex<()> = Mutex::new(());

fn no_parallel_spawns() -> MutexGuard<'static, ()> {
    SPAWN.lock().unwrap_or_else(|e| e.into_inner())
}

/// A temporary state directory, removed at the end of the test.
struct TempDir(PathBuf);

impl TempDir {
    fn new() -> TempDir {
        static N: AtomicUsize = AtomicUsize::new(0);
        let n = N.fetch_add(1, AtomicOrdering::SeqCst);
        let dir = std::env::temp_dir().join(format!("nyra-updated-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        TempDir(dir)
    }
    fn store(&self) -> Store {
        Store {
            dir: self.0.join("state"),
        }
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn signer() -> SigningKey {
    SigningKey::from_bytes(&[2; 32])
}

fn config() -> Config {
    Config {
        repository: "nyra".into(),
        channel: "stable".into(),
        version_floor: FLOOR.into(),
        keys: vec![signer().verifying_key()],
        stage_timeout: STAGE_TIMEOUT,
    }
}

/// A sheet payload for everybody (100%), without a previous version.
fn payload(sequence: u64, current: &str, retracted: &[&str]) -> Value {
    json!({
        "schema": 1, "repository": "nyra", "channel": "stable", "sequence": sequence,
        "issued_at": NOW - DAY, "expires_at": NOW + 6 * DAY,
        "current": {"digest": current, "version": version(current)},
        "previous": null, "percent": 100, "halted": false, "retracted": retracted
    })
}

fn sign(p: &Value) -> Vec<u8> {
    let bytes = serde_json::to_vec(p).unwrap();
    let sig = signer().sign(&pae(PAYLOAD_TYPE, &bytes));
    serde_json::to_vec(&json!({
        "payloadType": PAYLOAD_TYPE,
        "payload": BASE64.encode(&bytes),
        "signatures": [{"keyid": "", "sig": BASE64.encode(sig.to_bytes())}]
    }))
    .unwrap()
}

fn sheet(sequence: u64, current: &str, retracted: &[&str]) -> Vec<u8> {
    sign(&payload(sequence, current, retracted))
}

struct Fake {
    status: Status,
    healthy: bool,
    boot: BootInfo,
    sheet: Vec<u8>,
    fetch_error: Option<Error>,
    /// The machine has no network ([`System::offline`]).
    offline: bool,
    stage_error: Option<Error>,
    /// `bootc rollback` and the deletion of the rollback deployment fail with it.
    rollback_error: Option<Error>,
    /// What bootc ends up staging, if not the digest it was asked for.
    stage_digest: Option<String>,
    calls: Vec<String>,
    store_dir: PathBuf,
    /// The state on disk at the moment `stage` was called.
    state_at_stage: Option<State>,
    /// The staged deployment discarded on this boot (`/run/nyra-updated/discarded`).
    discarded: Option<String>,
}

impl Fake {
    fn new(dir: &TempDir, booted: &str, sheet: Vec<u8>) -> Fake {
        Fake {
            status: Status {
                booted: dep(booted),
                ..Status::default()
            },
            healthy: true,
            boot: BootInfo {
                soft_rebooted: false,
                on_trial: false,
                counted: true,
            },
            sheet,
            fetch_error: None,
            offline: false,
            stage_error: None,
            rollback_error: None,
            stage_digest: None,
            calls: Vec::new(),
            store_dir: dir.store().dir,
            state_at_stage: None,
            discarded: None,
        }
    }
    fn staged(&self) -> Vec<&String> {
        self.calls
            .iter()
            .filter(|c| c.starts_with("stage "))
            .collect()
    }
}

impl System for Fake {
    fn status(&mut self) -> Result<Status, Error> {
        Ok(self.status.clone())
    }
    fn boot_complete(&mut self) -> Result<bool, Error> {
        Ok(self.healthy)
    }
    fn boot_info(&mut self) -> Result<BootInfo, Error> {
        Ok(self.boot)
    }
    fn fetch_sheet(&mut self, url: &str) -> Result<Vec<u8>, Error> {
        self.calls.push(format!("fetch {url}"));
        match self.fetch_error.clone() {
            Some(e) => Err(e),
            None => Ok(self.sheet.clone()),
        }
    }
    fn offline(&mut self) -> bool {
        self.offline
    }
    fn stage(&mut self, image_ref: &str) -> Result<(), Error> {
        self.calls.push(format!("stage {image_ref}"));
        let store = Store {
            dir: self.store_dir.clone(),
        };
        self.state_at_stage = Some(store.load().unwrap());
        if let Some(e) = self.stage_error.clone() {
            return Err(e);
        }
        let digest = self
            .stage_digest
            .clone()
            .unwrap_or_else(|| image_ref.rsplit('@').next().unwrap().to_string());
        self.status.staged = Some(Deployment {
            image: Some(format!("updates.nyraos.com/nyra@{digest}")),
            version: Some(version(&digest).into()),
            digest,
        });
        Ok(())
    }
    /// Like `bootc rollback` on composefs: fails without a rollback deployment, otherwise
    /// discards a staged deployment and swaps the boot order.
    fn rollback(&mut self) -> Result<(), Error> {
        self.calls.push("rollback".into());
        if let Some(e) = self.rollback_error.clone() {
            return Err(e);
        }
        if self.status.rollback.is_none() {
            return Err(Error::Command("bootc rollback failed".into()));
        }
        self.status.staged = None;
        self.status.rollback_queued = !self.status.rollback_queued;
        Ok(())
    }
    fn delete_rollback(&mut self, digest: &str) -> Result<(), Error> {
        self.calls.push(format!("delete rollback {digest}"));
        if let Some(e) = self.rollback_error.clone() {
            return Err(e);
        }
        if Status::digest(&self.status.rollback) != Some(digest) {
            return Err(Error::Command("not the rollback deployment".into()));
        }
        self.status.rollback = None;
        self.status.rollback_queued = false;
        Ok(())
    }
    /// The staged deployment stays in bootc's status until the reboot; it is just not finalized.
    fn discard_staged(&mut self, digest: &str) -> Result<(), Error> {
        self.calls.push(format!("discard {digest}"));
        self.discarded = Some(digest.into());
        Ok(())
    }
    fn discarded(&mut self) -> Result<Option<String>, Error> {
        Ok(self.discarded.clone())
    }
    fn reboot(&mut self) -> Result<(), Error> {
        self.calls.push("reboot".into());
        Ok(())
    }
}

fn run_check(fake: &mut Fake, dir: &TempDir) -> Result<Outcome, Error> {
    check(fake, &dir.store(), &config(), NOW)
}

fn lock_path(dir: &TempDir) -> PathBuf {
    fs::create_dir_all(&dir.0).unwrap();
    dir.0.join("lock")
}

/// `on_health_failure` with the lock in `dir`. No process starts while it holds the lock (see
/// [`SPAWN`]), so a later call in the same test finds it free.
fn health_failed(fake: &mut Fake, dir: &TempDir) -> Result<HealthAction, Error> {
    let _spawns = no_parallel_spawns();
    on_health_failure(fake, &dir.store(), &lock_path(dir))
}

// --- the normal path, pinned by digest (rule 7) ----------------------------------------------

#[test]
fn a_newer_version_is_staged_pinned_by_digest_and_not_applied() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    assert_eq!(
        fake.calls,
        vec![
            format!("fetch {SHEET_URL}"),
            format!("stage updates.nyraos.com/nyra@{C}"),
        ]
    );
    assert_eq!(dir.store().load().unwrap().pending.as_deref(), Some(C));
}

fn discards(fake: &Fake) -> Vec<&String> {
    fake.calls
        .iter()
        .filter(|c| c.starts_with("discard "))
        .collect()
}

#[test]
fn a_staged_digest_other_than_the_sheet_is_an_error() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, B, sheet(100, C, &[]));
    fake.status.rollback = dep(A);
    fake.stage_digest = Some(Z.into());
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::DigestMismatch {
            expected: C.into(),
            found: Z.into()
        })
    );
    // The wrong deployment is never finalized; the boot order is not touched.
    assert_eq!(discards(&fake), vec![&format!("discard {Z}")]);
    assert!(!fake.calls.contains(&"rollback".to_string()));
    assert!(!fake.status.rollback_queued);
}

#[test]
fn a_wrong_staged_deployment_is_discarded_whatever_the_rollback_deployment_is() {
    // No rollback deployment (the first update), one below the floor, one that failed.
    for (rollback, failed) in [(None, None), (dep(Z), None), (dep(A), Some(A))] {
        let dir = TempDir::new();
        if let Some(f) = failed {
            dir.store()
                .save(&State {
                    failed: [f.to_string()].into(),
                    ..State::default()
                })
                .unwrap();
        }
        let mut fake = Fake::new(&dir, B, sheet(100, C, &[]));
        fake.status.rollback = rollback.clone();
        fake.stage_digest = Some(Z.into());
        assert!(matches!(
            run_check(&mut fake, &dir),
            Err(Error::DigestMismatch { .. })
        ));
        assert_eq!(fake.discarded.as_deref(), Some(Z), "{rollback:?}");
        assert!(
            !fake.calls.contains(&"rollback".to_string()),
            "{rollback:?}"
        );
    }
}

// --- rule 10: only our own images -------------------------------------------------------------

#[test]
fn nothing_happens_on_an_image_the_owner_chose() {
    for image in [
        Some("quay.io/someone/nyra:stable"),
        Some("updates.nyraos.com:443/nyra@sha256:x"),
        Some("updates.nyraos.com./nyra:stable"),
        Some("updates.nyraos.com.evil.test/nyra:stable"),
        Some("updates.nyraos.com/Nyra:stable"),
        Some("updates.nyraos.com/nyra"),
        None, // containers-storage or another transport
    ] {
        let dir = TempDir::new();
        let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
        fake.status.booted.as_mut().unwrap().image = image.map(String::from);
        assert_eq!(
            run_check(&mut fake, &dir),
            Ok(Outcome::ForeignImage(image.map(String::from)))
        );
        assert!(fake.calls.is_empty(), "{image:?}");
    }
}

#[test]
fn our_images_by_tag_or_digest_are_official() {
    let cfg = config();
    assert!(cfg.is_official(Some("updates.nyraos.com/nyra:stable")));
    assert!(cfg.is_official(Some(&format!("updates.nyraos.com/nyra@{A}"))));
    assert!(!cfg.is_official(Some("updates.nyraos.com/nyra")));
    // Any repository on our server: a version may move its updates to another one.
    assert!(cfg.is_official(Some("updates.nyraos.com/nyra-fork:stable")));
    assert!(cfg.is_official(Some("updates.nyraos.com/other/nyra:stable")));
}

#[test]
fn a_version_that_moves_its_updates_to_another_repository_keeps_getting_them() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    fake.status.booted.as_mut().unwrap().image = Some(format!("updates.nyraos.com/nyra-old@{A}"));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    assert_eq!(
        fake.calls,
        vec![
            format!("fetch {SHEET_URL}"),
            format!("stage updates.nyraos.com/nyra@{C}"),
        ]
    );
}

#[test]
fn the_installed_version_is_up_to_date() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, C, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    assert!(fake.staged().is_empty());
}

#[test]
fn nothing_happens_on_a_boot_that_is_not_healthy() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    fake.healthy = false;
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::NotHealthy));
    assert!(fake.calls.is_empty());
}

// --- rule 1: one update at a time, time limits ------------------------------------------------

#[test]
fn a_second_updater_is_refused_while_the_first_holds_the_lock() {
    let _spawns = no_parallel_spawns();
    let dir = TempDir::new();
    fs::create_dir_all(&dir.0).unwrap();
    let path = dir.0.join("lock");
    let first = Lock::acquire(&path).unwrap();
    // Close-on-exec, so bootc and curl started while it is held never inherit it.
    // SAFETY: F_GETFD on a file descriptor this test owns.
    let flags = unsafe { libc::fcntl(first.0.as_raw_fd(), libc::F_GETFD) };
    assert_eq!(flags & libc::FD_CLOEXEC, libc::FD_CLOEXEC);
    assert!(matches!(Lock::acquire(&path), Err(Error::Busy)));
    drop(first);
    assert!(Lock::acquire(&path).is_ok());
}

#[test]
fn an_already_staged_target_is_not_staged_again() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    // The same sheet again (equal sequence, identical payload): accepted, nothing new to do.
    assert_eq!(
        run_check(&mut fake, &dir),
        Ok(Outcome::WaitingForReboot(image(C)))
    );
    assert_eq!(fake.staged().len(), 1);
}

#[test]
fn a_hung_command_is_killed_with_its_children_after_the_time_limit() {
    let _spawns = no_parallel_spawns();
    let dir = TempDir::new();
    fs::create_dir_all(&dir.0).unwrap();
    let pidfile = dir.0.join("child.pid");
    let start = Instant::now();
    let result = run(
        Command::new("sh")
            .arg("-c")
            .arg(format!("sleep 30 & echo $! > {}; wait", pidfile.display())),
        Duration::from_millis(300),
    );
    assert!(matches!(result, Err(Error::Timeout(_))), "{result:?}");
    assert!(start.elapsed() < Duration::from_secs(5));
    // The grandchild (like skopeo under bootc) is gone too: no process, or a zombie.
    let pid = fs::read_to_string(&pidfile).unwrap().trim().to_string();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let ps = Command::new("ps")
            .args(["-o", "stat=", "-p", &pid])
            .output()
            .unwrap();
        let stat = String::from_utf8_lossy(&ps.stdout).trim().to_string();
        if stat.is_empty() || stat.starts_with('Z') {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "child {pid} still running: {stat}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn a_command_within_the_time_limit_returns_its_output() {
    let _spawns = no_parallel_spawns();
    let out = run(
        Command::new("sh").args(["-c", "echo hello; exit 3"]),
        Duration::from_secs(10),
    )
    .unwrap();
    assert_eq!(out.stdout, b"hello\n");
    assert_eq!(out.status.code(), Some(3));
}

#[test]
fn a_timed_out_stage_is_retried_at_the_next_check() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    fake.stage_error = Some(Error::Timeout("bootc".into()));
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::Timeout("bootc".into()))
    );
    fake.stage_error = None;
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    assert!(!dir.store().load().unwrap().failed.contains(C));
}

// --- no network (rule 1) ---------------------------------------------------------------------

#[test]
fn only_a_failed_command_or_its_timeout_is_offline() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    fake.offline = true;
    let refused = Error::DigestMismatch {
        expected: A.into(),
        found: B.into(),
    };
    assert_eq!(when_offline(&mut fake, refused.clone()), refused);
    let command = Error::Command("curl failed".into());
    assert_eq!(
        when_offline(&mut fake, command.clone()),
        Error::Offline(Box::new(command))
    );
}

#[test]
fn a_check_without_a_network_says_so_and_stages_once_the_network_is_back() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    let unreachable = Error::Command("curl failed: Network is unreachable".into());
    fake.offline = true;
    fake.fetch_error = Some(unreachable.clone());
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::Offline(Box::new(unreachable)))
    );
    assert!(fake.staged().is_empty());
    fake.offline = false;
    fake.fetch_error = None;
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
}

#[test]
fn a_pull_cut_off_by_a_lost_network_marks_nothing_failed() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    fake.offline = true;
    fake.stage_error = Some(Error::Timeout("bootc".into()));
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::Offline(Box::new(Error::Timeout("bootc".into()))))
    );
    assert_eq!(fake.status.staged, None);
    fake.offline = false;
    fake.stage_error = None;
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    assert!(dir.store().load().unwrap().failed.is_empty());
}

#[test]
fn only_a_failed_download_without_a_network_counts_as_offline() {
    // A server that stops answering on a working link stays an error.
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    fake.stage_error = Some(Error::Timeout("bootc".into()));
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::Timeout("bootc".into()))
    );
    // Without a network, a sheet that does not verify is still refused for what it is.
    let mut fake = Fake::new(&dir, A, b"<html>captive portal</html>".to_vec());
    fake.offline = true;
    assert!(matches!(run_check(&mut fake, &dir), Err(Error::Sheet(_))));
}

#[test]
fn a_refusal_is_not_reported_as_no_network_when_the_link_drops_at_the_same_moment() {
    let refusals = [
        "error: Switching: Opening image docker://updates.nyraos.com/nyra@sha256:cc: failed to \
         invoke method OpenImage: A signature was required, but no signature exists",
        "failed to invoke method OpenImage: cryptographic signature verification failed",
        "Failed to pull config Descriptor { media_type: ImageConfig, digest: Digest { .. } }: \
         failed to invoke method FinishPipe: corrupted blob, expecting sha256:26a4",
        "Manifest does not match provided manifest digest sha256:cc",
        "Source image rejected: Running image docker://updates.nyraos.com/nyra:x is rejected by policy.",
    ];
    for refusal in refusals {
        let dir = TempDir::new();
        let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
        fake.offline = true;
        fake.stage_error = Some(Error::Command(refusal.into()));
        assert_eq!(
            run_check(&mut fake, &dir),
            Err(Error::Command(refusal.into()))
        );
    }
    // The sheet's server certificate, refused by curl.
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    let tls = Error::Command(
        "curl: (60) SSL: no alternative certificate subject name matches target hostname".into(),
    );
    fake.offline = true;
    fake.fetch_error = Some(tls.clone());
    assert_eq!(run_check(&mut fake, &dir), Err(tls));
    // bootc names the config's digest in the context of any failed pull: that is no refusal.
    let lost = Error::Command(
        "Failed to pull config Descriptor { media_type: ImageConfig, digest: Digest { .. } }: \
         dial tcp 10.0.2.2:80: connect: network is unreachable"
            .into(),
    );
    let mut fake = Fake::new(&dir, A, sheet(101, C, &[]));
    fake.offline = true;
    fake.stage_error = Some(lost.clone());
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::Offline(Box::new(lost)))
    );
}

// --- rule 2: sequence persisted before acting -------------------------------------------------

#[test]
fn the_sequence_and_retractions_are_saved_before_staging() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[B]));
    run_check(&mut fake, &dir).unwrap();
    let saved = fake.state_at_stage.unwrap();
    assert_eq!(saved.sheets["nyra:stable"].sequence, 100);
    assert!(saved.retracted.contains(B));
    assert_eq!(saved.pending.as_deref(), Some(C));
}

#[test]
fn the_sequence_is_saved_even_when_staging_fails() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[B]));
    fake.stage_error = Some(Error::Command("bootc switch failed".into()));
    assert!(run_check(&mut fake, &dir).is_err());
    let state = dir.store().load().unwrap();
    assert_eq!(state.sheets["nyra:stable"].sequence, 100);
    assert!(state.retracted.contains(B));
}

#[test]
fn a_lower_sequence_is_refused() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(200, A, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    fake.sheet = sheet(100, C, &[]);
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::Sheet(nyra_channel_sheet::Error::SequenceRollback {
            last: 200,
            found: 100
        }))
    );
    assert!(fake.staged().is_empty());
    assert_eq!(
        dir.store().load().unwrap().sheets["nyra:stable"].sequence,
        200
    );
}

#[test]
fn an_equal_sequence_with_another_payload_is_refused() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, A, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    let accepted = dir.store().load().unwrap();
    fake.sheet = sheet(100, C, &[]);
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::SameSequenceDifferentSheet(100))
    );
    assert!(fake.staged().is_empty());
    assert_eq!(dir.store().load().unwrap(), accepted);
}

#[test]
fn an_expired_sheet_changes_nothing() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[B]));
    let late = NOW + 30 * DAY;
    assert_eq!(
        check(&mut fake, &dir.store(), &config(), late),
        Err(Error::Sheet(nyra_channel_sheet::Error::Expired))
    );
    assert_eq!(dir.store().load().unwrap(), State::default());
    assert!(fake.staged().is_empty());
}

// --- rule 3: retracted digests are remembered -------------------------------------------------

#[test]
fn a_retracted_digest_is_never_a_target_again() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[B]));
    run_check(&mut fake, &dir).unwrap();
    // A later sheet no longer lists B as retracted and serves it.
    fake.status.staged = None;
    fake.sheet = sheet(101, B, &[]);
    assert_eq!(run_check(&mut fake, &dir), Err(Error::Retracted(B.into())));
    assert_eq!(fake.staged().len(), 1);
}

#[test]
fn an_installed_version_retracted_by_an_earlier_sheet_still_goes_back() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, B, sheet(100, A, &[B]));
    fake.stage_error = Some(Error::Timeout("bootc".into()));
    assert!(run_check(&mut fake, &dir).is_err());
    // The next sheet no longer lists B; the machine still runs it.
    fake.stage_error = None;
    fake.sheet = sheet(101, A, &[]);
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(A))));
}

// --- rule 4: no downgrade, version floor ------------------------------------------------------

#[test]
fn an_older_version_is_refused() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, C, sheet(100, B, &[]));
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::Sheet(nyra_channel_sheet::Error::Downgrade {
            installed: "2026.10.3".into(),
            offered: "2026.10.2".into()
        }))
    );
    assert!(fake.staged().is_empty());
}

#[test]
fn a_signed_retraction_below_the_version_floor_is_refused() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, B, sheet(100, Z, &[B]));
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::RetractedRunning {
            running: B.into(),
            reason: Box::new(Error::BelowFloor {
                version: "2026.9.1".into(),
                floor: "2026.10.1".into()
            })
        })
    );
    assert_eq!(fake.calls, vec![format!("fetch {SHEET_URL}")]);
}

#[test]
fn a_signed_retraction_to_an_older_version_is_staged() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, B, sheet(100, A, &[B]));
    fake.status.rollback = dep(Z);
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(A))));
}

#[test]
fn a_failed_download_off_a_retracted_version_still_says_it_runs_one() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, B, sheet(100, A, &[B]));
    fake.stage_error = Some(Error::Timeout("bootc".into()));
    let refused = run_check(&mut fake, &dir).unwrap_err();
    assert_eq!(
        refused,
        Error::RetractedRunning {
            running: B.into(),
            reason: Box::new(Error::Timeout("bootc".into()))
        }
    );
    assert!(refused
        .to_string()
        .starts_with(&format!("the running version {B} was retracted")));
    // Without a network too.
    fake.offline = true;
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::RetractedRunning {
            running: B.into(),
            reason: Box::new(Error::Offline(Box::new(Error::Timeout("bootc".into()))))
        })
    );
    // Not when the running version is not retracted.
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    fake.stage_error = Some(Error::Timeout("bootc".into()));
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::Timeout("bootc".into()))
    );
}

// --- rule 5: failed versions ------------------------------------------------------------------

#[test]
fn a_version_the_machine_fell_back_from_is_marked_failed_and_never_staged_again() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    // C booted, failed its health checks three times; systemd-boot went back to A.
    fake.status = Status {
        booted: dep(A),
        staged: None,
        rollback: dep(C),
        ..Status::default()
    };
    assert_eq!(run_check(&mut fake, &dir), Err(Error::Failed(C.into())));
    let state = dir.store().load().unwrap();
    assert!(state.failed.contains(C));
    assert_eq!(state.pending, None);
    assert_eq!(fake.staged().len(), 1);
    assert_eq!(offered_rollback(&fake.status, &state, FLOOR), None);
}

#[test]
fn a_version_that_booted_healthy_is_confirmed() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    run_check(&mut fake, &dir).unwrap();
    fake.status = Status {
        booted: dep(C),
        staged: None,
        rollback: dep(A),
        ..Status::default()
    };
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    let state = dir.store().load().unwrap();
    assert_eq!(state.pending, None);
    assert!(state.failed.is_empty());
    assert_eq!(
        offered_rollback(&fake.status, &state, FLOOR),
        dep(A).as_ref()
    );
}

#[test]
fn a_new_version_booted_without_a_boot_counter_is_reported() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    run_check(&mut fake, &dir).unwrap();
    fake.status = Status {
        booted: dep(C),
        staged: None,
        rollback: dep(A),
        ..Status::default()
    };
    fake.boot.counted = false; // nyra-boot-counter failed silently
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::NotBootCounted(C.into()))
    );
    // Reported once, and the healthy version is not marked failed.
    let state = dir.store().load().unwrap();
    assert_eq!(state.pending, None);
    assert!(state.failed.is_empty());
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
}

#[test]
fn a_new_version_reached_by_a_soft_reboot_is_reported() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    run_check(&mut fake, &dir).unwrap();
    fake.status.booted = dep(C);
    fake.status.staged = None;
    // LoaderBootCountPath survives from the previous full boot: it proves nothing here.
    fake.boot.soft_rebooted = true;
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::NotBootCounted(C.into()))
    );
}

#[test]
fn staging_cut_short_by_a_power_loss_is_retried_not_marked_failed() {
    let dir = TempDir::new();
    let store = dir.store();
    store
        .save(&State {
            pending: Some(C.into()),
            ..State::default()
        })
        .unwrap();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    assert!(store.load().unwrap().failed.is_empty());
}

#[test]
fn a_retracted_rollback_deployment_is_not_offered() {
    let state = State {
        retracted: [B.to_string()].into(),
        ..State::default()
    };
    let status = Status {
        booted: dep(C),
        staged: None,
        rollback: dep(B),
        ..Status::default()
    };
    assert_eq!(offered_rollback(&status, &state, FLOOR), None);
}

#[test]
fn the_version_fallen_back_from_is_not_offered() {
    // C failed its tries and systemd-boot went back to A; bootc still reports C as the next boot.
    let fallback = Status {
        booted: dep(A),
        rollback: dep(C),
        rollback_queued: true,
        ..Status::default()
    };
    // Before a check settles it (C still pending), and once it is forgiven (rule 12).
    let pending = State {
        pending: Some(C.into()),
        ..State::default()
    };
    let forgiven = State {
        forgiven: Some(C.into()),
        ..State::default()
    };
    assert_eq!(offered_rollback(&fallback, &pending, FLOOR), None);
    assert_eq!(offered_rollback(&fallback, &forgiven, FLOOR), None);
    // Forgiven, even with a bootc that would see the fallback.
    let seen = Status {
        rollback_queued: false,
        ..fallback
    };
    assert_eq!(offered_rollback(&seen, &forgiven, FLOOR), None);
    assert_eq!(
        offered_rollback(&seen, &State::default(), FLOOR),
        dep(C).as_ref()
    );
}

#[test]
fn a_rollback_already_queued_or_below_the_floor_is_not_offered() {
    let status = Status {
        booted: dep(B),
        rollback: dep(A),
        ..Status::default()
    };
    assert_eq!(
        offered_rollback(&status, &State::default(), FLOOR),
        dep(A).as_ref()
    );
    assert_eq!(
        offered_rollback(&status, &State::default(), "2026.10.2"),
        None
    );
    let queued = Status {
        rollback_queued: true,
        ..status
    };
    assert_eq!(offered_rollback(&queued, &State::default(), FLOOR), None);
}

// --- rule 6: retraction to the local rollback deployment --------------------------------------

#[test]
fn a_retraction_to_the_local_rollback_deployment_uses_bootc_rollback() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, B, sheet(100, A, &[B]));
    fake.status.rollback = dep(A);
    assert_eq!(
        run_check(&mut fake, &dir),
        Ok(Outcome::RolledBack(image(A)))
    );
    assert_eq!(
        fake.calls,
        vec![format!("fetch {SHEET_URL}"), "rollback".to_string()]
    );
}

#[test]
fn a_second_check_before_the_reboot_does_not_roll_back_again() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, B, sheet(100, A, &[B]));
    fake.status.rollback = dep(A);
    assert_eq!(
        run_check(&mut fake, &dir),
        Ok(Outcome::RolledBack(image(A)))
    );
    assert_eq!(
        run_check(&mut fake, &dir),
        Ok(Outcome::WaitingForReboot(image(A)))
    );
    // One `bootc rollback`: A stays the next boot.
    assert_eq!(
        fake.calls
            .iter()
            .filter(|c| c.as_str() == "rollback")
            .count(),
        1
    );
    assert!(fake.status.rollback_queued);
}

#[test]
fn a_failed_rollback_off_a_retracted_version_still_says_it_runs_one() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, B, sheet(100, A, &[B]));
    fake.status.rollback = dep(A);
    fake.rollback_error = Some(Error::Timeout("bootc".into()));
    let still_retracted = Err(Error::RetractedRunning {
        running: B.into(),
        reason: Box::new(Error::Timeout("bootc".into())),
    });
    assert_eq!(run_check(&mut fake, &dir), still_retracted);
    assert_eq!(fake.calls.last().map(String::as_str), Some("rollback"));
    // The deletion of a forgiven version's deployment (rule 12) the same way.
    let mut state = dir.store().load().unwrap();
    state.forgiven = Some(A.into());
    dir.store().save(&state).unwrap();
    assert_eq!(run_check(&mut fake, &dir), still_retracted);
    assert_eq!(fake.calls.last(), Some(&format!("delete rollback {A}")));
}

#[test]
fn a_failed_rollback_deployment_is_not_used_for_a_retraction() {
    let dir = TempDir::new();
    dir.store()
        .save(&State {
            failed: [A.to_string()].into(),
            ..State::default()
        })
        .unwrap();
    let mut fake = Fake::new(&dir, B, sheet(100, A, &[B]));
    fake.status.rollback = dep(A);
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::RetractedRunning {
            running: B.into(),
            reason: Box::new(Error::Failed(A.into()))
        })
    );
    assert!(!fake.calls.contains(&"rollback".to_string()));
}

// --- rule 11: a staged version that must not boot ---------------------------------------------

#[test]
fn a_staged_version_retracted_before_the_reboot_is_discarded() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, B, sheet(100, C, &[]));
    fake.status.rollback = dep(A);
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    fake.sheet = sheet(101, B, &[C]);
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Discarded(C.into())));
    assert_eq!(discards(&fake), vec![&format!("discard {C}")]);
    assert!(!fake.calls.contains(&"rollback".to_string()));
    assert_eq!(dir.store().load().unwrap().pending, None);
    // Until the reboot nothing more happens, not even a sheet fetch.
    let calls = fake.calls.len();
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Discarded(C.into())));
    assert_eq!(fake.calls.len(), calls);
}

#[test]
fn a_retracted_staged_version_is_discarded_when_the_rollback_deployment_failed() {
    // B failed its health checks and the machine came back to A; C was staged, then retracted
    // before the reboot. The rollback deployment is B: C must not boot anyway.
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, B, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(B))));
    fake.status = Status {
        booted: dep(A),
        rollback: dep(B),
        ..Status::default()
    };
    fake.sheet = sheet(101, C, &[]);
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    assert!(dir.store().load().unwrap().failed.contains(B));
    fake.sheet = sheet(102, A, &[C]);
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Discarded(C.into())));
    assert_eq!(fake.discarded.as_deref(), Some(C));
    assert!(!fake.calls.contains(&"rollback".to_string()));
}

#[test]
fn a_staged_version_below_the_floor_or_failed_is_discarded() {
    for (staged, failed) in [(Z, None), (C, Some(C))] {
        let dir = TempDir::new();
        if let Some(f) = failed {
            dir.store()
                .save(&State {
                    failed: [f.to_string()].into(),
                    ..State::default()
                })
                .unwrap();
        }
        let mut fake = Fake::new(&dir, B, sheet(100, B, &[]));
        fake.status.staged = dep(staged); // staged by hand
        assert_eq!(
            run_check(&mut fake, &dir),
            Ok(Outcome::Discarded(staged.into()))
        );
        assert_eq!(fake.discarded.as_deref(), Some(staged));
    }
}

#[test]
fn a_staged_or_rollback_version_without_a_readable_version_is_unacceptable() {
    for label in [None, Some("garbage"), Some("")] {
        let unlabeled = Some(Deployment {
            version: label.map(String::from),
            ..dep(C).unwrap()
        });
        // Staged: discarded, as one below the floor would be.
        let dir = TempDir::new();
        let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
        fake.status.staged = unlabeled.clone();
        assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Discarded(C.into())));
        // A rollback queued to it: undone; and never offered.
        let dir = TempDir::new();
        let mut fake = Fake::new(&dir, A, sheet(100, A, &[]));
        fake.status.rollback = unlabeled;
        assert_eq!(
            offered_rollback(&fake.status, &State::default(), FLOOR),
            None
        );
        fake.status.rollback_queued = true;
        assert_eq!(
            run_check(&mut fake, &dir),
            Ok(Outcome::RollbackUndone(C.into()))
        );
    }
}

fn rollbacks(fake: &Fake) -> usize {
    fake.calls
        .iter()
        .filter(|c| c.as_str() == "rollback")
        .count()
}

#[test]
fn a_queued_rollback_to_a_version_retracted_before_the_reboot_is_undone() {
    // The user goes back from B to A (bootc rollback); before the reboot a sheet retracts A.
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, B, sheet(100, B, &[]));
    fake.status.rollback = dep(A);
    fake.rollback().unwrap();
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    assert!(fake.status.rollback_queued);
    fake.sheet = sheet(101, B, &[A]);
    assert_eq!(
        run_check(&mut fake, &dir),
        Ok(Outcome::RollbackUndone(A.into()))
    );
    assert!(!fake.status.rollback_queued);
    // Once: B stays the next boot.
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    assert_eq!(rollbacks(&fake), 2);
}

#[test]
fn a_queued_rollback_to_a_failed_or_below_the_floor_version_is_undone() {
    // Below the floor (queued by hand), and failed (bootc still reports the version fallen back from
    // as the next boot).
    for (rollback, failed) in [(Z, None), (C, Some(C))] {
        let dir = TempDir::new();
        if let Some(f) = failed {
            dir.store()
                .save(&State {
                    failed: [f.to_string()].into(),
                    ..State::default()
                })
                .unwrap();
        }
        let mut fake = Fake::new(&dir, B, sheet(100, B, &[]));
        fake.status.rollback = dep(rollback);
        fake.status.rollback_queued = true;
        assert_eq!(
            run_check(&mut fake, &dir),
            Ok(Outcome::RollbackUndone(rollback.into()))
        );
        assert!(!fake.status.rollback_queued, "{rollback}");
        assert_eq!(rollbacks(&fake), 1);
    }
}

// --- rule 13: a version the user went back from -----------------------------------------------

#[test]
fn a_version_the_user_went_back_from_is_not_staged_again() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    fake.status = Status {
        booted: dep(C),
        rollback: dep(A),
        ..Status::default()
    };
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    // The user goes back to A: nothing changes before the reboot, nor after it.
    fake.rollback().unwrap();
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    fake.status = Status {
        booted: dep(A),
        rollback: dep(C),
        ..Status::default()
    };
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::HeldBack(image(C))));
    assert_eq!(fake.staged().len(), 1);
    assert!(!fake.calls.iter().any(|c| c.starts_with("delete rollback")));
    assert_eq!(dir.store().load().unwrap().pending, None);
    // The user goes forward again: C is the next boot and stays it.
    fake.rollback().unwrap();
    assert_eq!(
        run_check(&mut fake, &dir),
        Ok(Outcome::WaitingForReboot(image(C)))
    );
    assert!(fake.status.rollback_queued);
}

#[test]
fn a_version_held_back_is_reported_as_a_warning_in_words() {
    let (priority, message) = Outcome::HeldBack(image(C)).report();
    assert_eq!(priority, 4);
    assert_eq!(
        message,
        format!(
            "this machine went back from 2026.10.3 ({C}) to an older version, without the latest \
             fixes: 2026.10.3 is not installed again, the next version the channel offers will be"
        )
    );
    assert_eq!(Outcome::ForeignImage(None).report().0, 4);
    assert_eq!(
        Outcome::Staged(image(C)).report(),
        (6, format!("{:?}", Outcome::Staged(image(C))))
    );
}

#[test]
fn a_version_the_user_went_back_from_gives_way_to_another_or_to_a_retraction() {
    let back_from_c = |dir: &TempDir, sheet: Vec<u8>| {
        let mut fake = Fake::new(dir, A, sheet);
        fake.status.rollback = dep(C);
        fake
    };
    // Another version: staged.
    let dir = TempDir::new();
    let mut fake = back_from_c(&dir, sheet(100, B, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(B))));
    // The running version retracted: C goes, with the settings it was left with, and is staged afresh.
    let dir = TempDir::new();
    let mut fake = back_from_c(&dir, sheet(100, C, &[A]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    assert_eq!(
        fake.calls[fake.calls.len() - 2..],
        [
            format!("delete rollback {C}"),
            format!("stage updates.nyraos.com/nyra@{C}")
        ]
    );
}

// --- rule 8: health check failures ------------------------------------------------------------

#[test]
fn a_failed_health_check_on_trial_reboots_fully() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, C, Vec::new());
    fake.boot.on_trial = true;
    assert_eq!(health_failed(&mut fake, &dir), Ok(HealthAction::Reboot));
    assert_eq!(fake.calls, vec!["reboot"]);
}

#[test]
fn a_failed_health_check_after_a_soft_reboot_reboots_fully() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, C, Vec::new());
    fake.boot.soft_rebooted = true;
    assert_eq!(health_failed(&mut fake, &dir), Ok(HealthAction::Reboot));
    assert_eq!(fake.calls, vec!["reboot"]);
}

#[test]
fn every_try_of_a_counted_entry_is_on_trial() {
    // systemd-bless-boot status on the three tries of an unhealthy version, then after blessing.
    for s in ["indeterminate\n", "indeterminate\n", "dirty\n", "bad\n"] {
        assert!(on_trial(s), "{s}");
    }
    for s in ["good\n", "clean\n", ""] {
        assert!(!on_trial(s), "{s}");
    }
}

#[test]
fn a_failed_health_check_off_trial_does_not_loop_reboots() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, C, Vec::new());
    assert_eq!(health_failed(&mut fake, &dir), Ok(HealthAction::Stay(None)));
    assert!(fake.calls.is_empty());
}

#[test]
fn a_failed_health_check_on_trial_keeps_the_pending_version() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    run_check(&mut fake, &dir).unwrap();
    fake.status = Status {
        booted: dep(C),
        rollback: dep(A),
        ..Status::default()
    };
    fake.boot.on_trial = true;
    assert_eq!(health_failed(&mut fake, &dir), Ok(HealthAction::Reboot));
    assert_eq!(dir.store().load().unwrap().pending.as_deref(), Some(C));
}

#[test]
fn a_failed_health_check_off_trial_waits_for_no_check_and_changes_nothing() {
    // C failed its tries, the machine fell back to A, which fails too: C would be forgiven. A check
    // holds the lock (root started one by hand).
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    fake.status = Status {
        booted: dep(A),
        rollback: dep(C),
        ..Status::default()
    };
    fake.healthy = false;
    let _spawns = no_parallel_spawns();
    let lock = lock_path(&dir);
    let check = Lock::acquire(&lock).unwrap();
    assert_eq!(
        on_health_failure(&mut fake, &dir.store(), &lock),
        Err(Error::Busy)
    );
    let state = dir.store().load().unwrap();
    assert_eq!((state.pending.as_deref(), state.forgiven), (Some(C), None));
    // On trial, the reboot does not need it.
    fake.boot.on_trial = true;
    assert_eq!(
        on_health_failure(&mut fake, &dir.store(), &lock),
        Ok(HealthAction::Reboot)
    );
    drop(check);
}

#[test]
fn health_failed_has_time_for_its_slowest_path() {
    // Off trial: systemctl show and systemd-bless-boot status (the boot state), bootc status and the
    // notice, each up to SHORT. systemd's default (90 s) would stop it before the notice.
    let unit =
        include_str!("../../../files/usr/lib/systemd/system/nyra-updated-health-failed.service");
    let limit = unit
        .lines()
        .find_map(|l| l.strip_prefix("TimeoutStartSec="))
        .and_then(|v| v.strip_suffix("min"))
        .and_then(|m| m.parse::<u64>().ok())
        .map(|m| Duration::from_secs(m * 60))
        .expect("TimeoutStartSec=<minutes>min");
    assert!(limit > 4 * SHORT, "{limit:?}");
}

// --- rule 12: the machine's settings, not the version ------------------------------------------

#[test]
fn a_version_is_not_failed_when_the_version_fallen_back_to_fails_too() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    // The settings were broken after C was staged: C failed three times, systemd-boot went back to
    // A, and A fails its health checks too (not on trial, so it stays up). bootc still orders C's
    // entry first (by sort key, not by tries left).
    fake.status = Status {
        booted: dep(A),
        staged: None,
        rollback: dep(C),
        rollback_queued: true,
    };
    fake.healthy = false;
    assert_eq!(
        health_failed(&mut fake, &dir),
        Ok(HealthAction::Stay(Some(C.into())))
    );
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::NotHealthy));
    // The settings repaired, A is healthy: C is not failed. Its deployment, with the settings it
    // failed with, is deleted, and C is staged again (pending, on trial).
    fake.healthy = true;
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    let state = dir.store().load().unwrap();
    assert!(state.failed.is_empty());
    assert_eq!(state.pending.as_deref(), Some(C));
    assert_eq!(
        fake.calls[fake.calls.len() - 2..],
        [
            format!("delete rollback {C}"),
            format!("stage updates.nyraos.com/nyra@{C}")
        ]
    );
    assert!(!fake.calls.contains(&"rollback".to_string()));
    // C boots, counted: confirmed.
    fake.status = Status {
        booted: dep(C),
        rollback: dep(A),
        ..Status::default()
    };
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    let state = dir.store().load().unwrap();
    assert!(state.failed.is_empty());
    assert_eq!(state.pending, None);
}

#[test]
fn a_retraction_to_a_forgiven_version_stages_it_afresh() {
    // B is retracted and A, not a local deployment, is staged by switch.
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, B, sheet(100, A, &[B]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(A))));
    // The settings were broken: A failed three times, systemd-boot went back to B, which fails too.
    // A is forgiven. bootc still reports A as the next boot: it does not see that A has no tries
    // left.
    fake.status = Status {
        booted: dep(B),
        staged: None,
        rollback: dep(A),
        rollback_queued: true,
    };
    fake.healthy = false;
    assert_eq!(
        health_failed(&mut fake, &dir),
        Ok(HealthAction::Stay(Some(A.into())))
    );
    // The settings repaired: the retraction to A must not wait for a reboot that boots B again.
    // A's deployment, with the settings it failed with, is deleted and A staged afresh, on trial.
    fake.healthy = true;
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(A))));
    assert_eq!(
        fake.calls[fake.calls.len() - 2..],
        [
            format!("delete rollback {A}"),
            format!("stage updates.nyraos.com/nyra@{A}")
        ]
    );
    assert!(!fake.calls.contains(&"rollback".to_string()));
    let state = dir.store().load().unwrap();
    assert!(state.failed.is_empty());
    assert_eq!(state.pending.as_deref(), Some(A));
    // A boots, counted: confirmed.
    fake.status = Status {
        booted: dep(A),
        rollback: dep(B),
        ..Status::default()
    };
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    assert_eq!(dir.store().load().unwrap().pending, None);
}

#[test]
fn a_new_version_booted_without_a_counter_is_still_reported_after_a_failed_health_check() {
    // Rule 9 is not lost: C's first boot was not counted (not on trial) and a health check failed.
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    run_check(&mut fake, &dir).unwrap();
    fake.status = Status {
        booted: dep(C),
        rollback: dep(A),
        ..Status::default()
    };
    fake.boot.counted = false;
    fake.healthy = false;
    assert_eq!(health_failed(&mut fake, &dir), Ok(HealthAction::Stay(None)));
    fake.healthy = true;
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::NotBootCounted(C.into()))
    );
}

#[test]
fn a_staged_version_is_not_forgiven_by_a_failed_health_check_before_it_booted() {
    // A health check fails (restarted by hand) on the boot that staged C: C has not been tried.
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    assert_eq!(health_failed(&mut fake, &dir), Ok(HealthAction::Stay(None)));
    assert_eq!(dir.store().load().unwrap().pending.as_deref(), Some(C));
    // C fails its tries and the machine comes back to a healthy A: C failed.
    fake.status = Status {
        booted: dep(A),
        rollback: dep(C),
        ..Status::default()
    };
    assert_eq!(run_check(&mut fake, &dir), Err(Error::Failed(C.into())));
}

#[test]
fn a_version_is_forgiven_only_once() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    let fallback = Status {
        booted: dep(A),
        rollback: dep(C),
        ..Status::default()
    };
    // First fallback from C, A unhealthy too: forgiven, C staged again after the repair.
    fake.status = fallback.clone();
    fake.healthy = false;
    assert_eq!(
        health_failed(&mut fake, &dir),
        Ok(HealthAction::Stay(Some(C.into())))
    );
    fake.healthy = true;
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    // Second fallback from C, A unhealthy again: not forgiven, and failed once A is healthy.
    fake.status = fallback;
    fake.healthy = false;
    assert_eq!(health_failed(&mut fake, &dir), Ok(HealthAction::Stay(None)));
    fake.healthy = true;
    assert_eq!(run_check(&mut fake, &dir), Err(Error::Failed(C.into())));
    assert!(dir.store().load().unwrap().failed.contains(C));
}

#[test]
fn a_version_offered_again_that_fails_again_is_failed() {
    let dir = TempDir::new();
    dir.store()
        .save(&State {
            forgiven: Some(C.into()),
            ..State::default()
        })
        .unwrap();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    fake.status.rollback = dep(C);
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    // C fails its three tries; systemd-boot goes back to A, which is healthy now.
    fake.status = Status {
        booted: dep(A),
        rollback: dep(C),
        ..Status::default()
    };
    assert_eq!(run_check(&mut fake, &dir), Err(Error::Failed(C.into())));
    assert!(dir.store().load().unwrap().failed.contains(C));
}

#[test]
fn a_forgiven_version_that_boots_healthy_is_no_longer_forgiven() {
    // C was forgiven, staged afresh and boots healthy.
    let dir = TempDir::new();
    dir.store()
        .save(&State {
            forgiven: Some(C.into()),
            ..State::default()
        })
        .unwrap();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    fake.status = Status {
        booted: dep(C),
        rollback: dep(A),
        ..Status::default()
    };
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    assert_eq!(dir.store().load().unwrap().forgiven, None);
    // So when the user goes back from it, it is held back like any other (rule 13).
    fake.status = Status {
        booted: dep(A),
        rollback: dep(C),
        ..Status::default()
    };
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::HeldBack(image(C))));
}

#[test]
fn a_retraction_target_that_fails_again_leaves_a_clear_report() {
    // B retracted; A, forgiven once, staged afresh (the chain of the test above), fails again and
    // the machine falls back to B, which fails too: A is not forgiven twice.
    let dir = TempDir::new();
    dir.store()
        .save(&State {
            forgiven: Some(A.into()),
            ..State::default()
        })
        .unwrap();
    let mut fake = Fake::new(&dir, B, sheet(100, A, &[B]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(A))));
    fake.status = Status {
        booted: dep(B),
        staged: None,
        rollback: dep(A),
        rollback_queued: true,
    };
    fake.healthy = false;
    assert_eq!(health_failed(&mut fake, &dir), Ok(HealthAction::Stay(None)));
    // The settings repaired: A is failed, bootc's order set right, and the report says that the
    // machine runs a retracted version with nowhere to go.
    fake.healthy = true;
    assert_eq!(
        run_check(&mut fake, &dir),
        Ok(Outcome::RollbackUndone(A.into()))
    );
    let refused = run_check(&mut fake, &dir).unwrap_err();
    assert_eq!(
        refused,
        Error::RetractedRunning {
            running: B.into(),
            reason: Box::new(Error::Failed(A.into()))
        }
    );
    assert!(refused.to_string().starts_with(&format!(
        "the running version {B} was retracted and this check could not move the machine off it: \
         refusing {A}: this machine fell back from it"
    )));
    assert_eq!(fake.staged().len(), 1);
}

// --- the state directory ----------------------------------------------------------------------

fn mode(p: &Path) -> u32 {
    fs::metadata(p).unwrap().permissions().mode() & 0o777
}

#[test]
fn the_state_is_written_atomically_and_privately() {
    let dir = TempDir::new();
    let store = dir.store();
    assert_eq!(store.load().unwrap(), State::default());
    let state = State {
        sheets: [(
            "nyra:stable".to_string(),
            Accepted {
                sequence: 7,
                payload_sha256: "ab".into(),
            },
        )]
        .into(),
        retracted: [B.to_string()].into(),
        failed: [C.to_string()].into(),
        pending: Some(A.into()),
        forgiven: Some(B.into()),
        channel: Some("beta".into()),
        following: Some("stable".into()),
        channel_changed: Some(NOW),
        network_retry: Some(NetworkRetry {
            digest: C.into(),
            failed_at: NOW,
            links: "enp1s0\n".into(),
            retried: true,
        }),
    };
    store.save(&state).unwrap();
    assert_eq!(store.load().unwrap(), state);
    assert_eq!(mode(&store.dir), 0o700);
    assert_eq!(mode(&store.dir.join("state.json")), 0o600);
    assert!(!store.dir.join("state.json.tmp").exists());
    // A temporary file left by a crash before the rename does not matter.
    fs::write(store.dir.join("state.json.tmp"), b"{garbage").unwrap();
    assert_eq!(store.load().unwrap(), state);
}

#[test]
fn an_unreadable_state_stops_the_daemon() {
    let dir = TempDir::new();
    let store = dir.store();
    fs::create_dir_all(&store.dir).unwrap();
    fs::write(store.dir.join("state.json"), b"{not json").unwrap();
    assert!(matches!(store.load(), Err(Error::Io(_))));
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert!(run_check(&mut fake, &dir).is_err());
    assert!(fake.calls.is_empty());
}

#[test]
fn an_older_daemon_reads_a_newer_state_file() {
    let dir = TempDir::new();
    let store = dir.store();
    fs::create_dir_all(&store.dir).unwrap();
    fs::write(
        store.dir.join("state.json"),
        format!(r#"{{"failed": ["{C}"], "from_the_future": 1}}"#),
    )
    .unwrap();
    assert!(store.load().unwrap().failed.contains(C));
}

#[test]
fn the_install_code_is_random_private_and_stable() {
    let dir = TempDir::new();
    let store = dir.store();
    let code = store.install_code().unwrap();
    assert_eq!(code.len(), 32);
    assert_ne!(code, vec![0u8; 32]);
    assert_eq!(mode(&store.dir.join("install-code")), 0o600);
    assert_eq!(store.install_code().unwrap(), code);
    assert_ne!(TempDir::new().store().install_code().unwrap(), code);
}

// --- configuration from the image -------------------------------------------------------------

const CONF: &str =
    "# Nyra updates\nrepository = nyra\nchannel = stable\nversion_floor = 2026.10.1\n";

#[test]
fn the_last_check_is_reported_privately() {
    let dir = TempDir::new();
    let store = dir.store();
    store.save_report(NOW, false, "no signature").unwrap();
    let path = store.dir.join("last-check.json");
    let report: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(
        report,
        json!({"time": NOW, "ok": false, "message": "no signature", "last_success": NOW})
    );
    assert_eq!(mode(&path), 0o600);
}

#[test]
fn checks_that_fail_for_two_weeks_say_so_whatever_the_cause() {
    let dir = TempDir::new();
    let store = dir.store();
    let offline = "no network connection (curl failed): the running version stays";
    assert_eq!(
        store
            .save_report(NOW, true, "UpToDate")
            .unwrap()
            .last_success,
        NOW
    );
    let report = store.save_report(NOW + DAY, false, offline).unwrap();
    assert_eq!(
        (report.last_success, report.message.as_str()),
        (NOW, offline)
    );
    assert_eq!(report.days_without_success(), None);
    let report = store
        .save_report(NOW + 14 * DAY - 1, false, offline)
        .unwrap();
    assert_eq!(report.days_without_success(), None);
    let report = store.save_report(NOW + 14 * DAY, false, offline).unwrap();
    assert_eq!(report.days_without_success(), Some(14));
    assert_eq!(
        report.message,
        format!("no successful check for 14 days: {offline}")
    );
    let written: Report =
        serde_json::from_slice(&fs::read(store.dir.join("last-check.json")).unwrap()).unwrap();
    assert_eq!(written, report);
    // A successful check ends it.
    let report = store.save_report(NOW + 15 * DAY, true, "UpToDate").unwrap();
    assert_eq!(
        (report.last_success, report.days_without_success()),
        (NOW + 15 * DAY, None)
    );
    assert_eq!(report.message, "UpToDate");
}

#[test]
fn days_without_a_successful_check_count_from_the_first_report_and_never_from_the_future() {
    // No successful check yet: from the first report.
    let dir = TempDir::new();
    let store = dir.store();
    assert_eq!(
        store.save_report(NOW, false, "x").unwrap().last_success,
        NOW
    );
    assert_eq!(
        store
            .save_report(NOW + 20 * DAY, false, "x")
            .unwrap()
            .message,
        "no successful check for 20 days: x"
    );
    // A success with the clock ahead (by at most a sheet's validity, 31 days: a later sheet has
    // expired) delays the count by that much once the clock is put right.
    let dir = TempDir::new();
    let store = dir.store();
    store.save_report(NOW + 31 * DAY, true, "UpToDate").unwrap();
    assert_eq!(
        store.save_report(NOW, false, "x").unwrap().last_success,
        NOW + 31 * DAY
    );
    assert_eq!(
        store
            .save_report(NOW + 45 * DAY, false, "x")
            .unwrap()
            .days_without_success(),
        Some(14)
    );
    // An image without a sheet key stays a warning: there is nothing to update from.
    let dir = TempDir::new();
    let store = dir.store();
    store.save_report(NOW, false, "x").unwrap();
    let report = store
        .save_report(NOW + 20 * DAY, false, NOT_CONFIGURED)
        .unwrap();
    assert_eq!(
        (report.message.as_str(), report.days_without_success()),
        (NOT_CONFIGURED, None)
    );
    // A report written by an older nyra-updated (no `last_success`): the count starts now.
    let dir = TempDir::new();
    let store = dir.store();
    fs::create_dir_all(&store.dir).unwrap();
    fs::write(
        store.dir.join("last-check.json"),
        br#"{"time": 1, "ok": true, "message": "UpToDate"}"#,
    )
    .unwrap();
    assert_eq!(
        store.save_report(NOW, false, "x").unwrap().last_success,
        NOW
    );
}

#[test]
fn a_failed_check_with_the_clock_behind_does_not_count_days_that_never_passed() {
    // A dead RTC: the clock at the build date, 200 days behind, booting offline; then corrected.
    let dir = TempDir::new();
    let store = dir.store();
    store.save_report(NOW, true, "UpToDate").unwrap();
    let report = store.save_report(NOW - 200 * DAY, false, "x").unwrap();
    assert_eq!(
        (report.last_success, report.days_without_success()),
        (NOW, None)
    );
    let report = store.save_report(NOW + DAY, false, "x").unwrap();
    assert_eq!(
        (report.last_success, report.days_without_success()),
        (NOW, None)
    );
    assert_eq!(report.message, "x");
}

#[test]
fn what_bootc_and_curl_print_is_logged_and_stored_as_one_short_line() {
    // A registry that answers with a forged journal line, a terminal escape and a flood.
    assert_eq!(
        one_line("pull failed: denied\n<0>nyra-updated check: UpToDate\r\u{1b}[2J\t."),
        "pull failed: denied <0>nyra-updated check: UpToDate  [2J ."
    );
    let long = "é".repeat(MAX_MESSAGE + 1);
    let line = one_line(&long);
    assert_eq!(line.chars().count(), MAX_MESSAGE + 1);
    assert!(line.ends_with("é…"));
    assert_eq!(one_line(&"é".repeat(MAX_MESSAGE)), "é".repeat(MAX_MESSAGE));
    // last-check.json gets the same line.
    let dir = TempDir::new();
    let report = dir
        .store()
        .save_report(NOW, false, "curl failed: 403\n<0>forged")
        .unwrap();
    assert_eq!(report.message, "curl failed: 403 <0>forged");
    let written: Report =
        serde_json::from_slice(&fs::read(dir.store().dir.join("last-check.json")).unwrap())
            .unwrap();
    assert_eq!(written, report);
}

fn pem(key: &SigningKey) -> String {
    // SubjectPublicKeyInfo for Ed25519: a fixed prefix, then the 32-byte key.
    let mut der = vec![
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ];
    der.extend_from_slice(key.verifying_key().as_bytes());
    format!(
        "-----BEGIN PUBLIC KEY-----\n{}\n-----END PUBLIC KEY-----\n",
        BASE64.encode(der)
    )
}

#[test]
fn the_config_is_read_from_the_image() {
    let cfg = Config::parse(CONF, &pem(&signer())).unwrap();
    assert_eq!(cfg.sheet_url(), SHEET_URL);
    assert_eq!(cfg.image_ref(C), format!("updates.nyraos.com/nyra@{C}"));
    assert_eq!(cfg.version_floor, "2026.10.1");
    assert_eq!(cfg.keys, vec![signer().verifying_key()]);
}

#[test]
fn an_incomplete_or_unknown_config_is_refused() {
    let key = pem(&signer());
    let without_floor = CONF.replace("version_floor = 2026.10.1\n", "");
    assert!(matches!(
        Config::parse(&without_floor, &key),
        Err(Error::Config(_))
    ));
    let bad_floor = CONF.replace("2026.10.1", "2026.10");
    assert!(Config::parse(&bad_floor, &key).is_err());
    let extra = format!("{CONF}tag = latest\n");
    assert!(matches!(Config::parse(&extra, &key), Err(Error::Config(_))));
}

#[test]
fn the_stage_timeout_can_only_be_shortened() {
    let base = "repository = nyra\nchannel = stable\nversion_floor = 2026.10.1\n";
    let key = pem(&signer());
    assert_eq!(
        Config::parse(base, &key).unwrap().stage_timeout,
        STAGE_TIMEOUT
    );
    let short = format!("{base}stage_timeout_seconds = 60\n");
    assert_eq!(
        Config::parse(&short, &key).unwrap().stage_timeout,
        Duration::from_secs(60)
    );
    for bad in ["0", "7201", "-1", "1h", ""] {
        let conf = format!("{base}stage_timeout_seconds = {bad}\n");
        assert_eq!(
            Config::parse(&conf, &key).unwrap_err(),
            Error::Config("invalid stage_timeout_seconds".into()),
            "{bad:?}"
        );
    }
}

#[test]
fn a_repeated_config_key_is_refused() {
    let conf =
        "repository = nyra\nchannel = stable\nversion_floor = 2026.10.1\nrepository = evil\n";
    assert_eq!(
        Config::parse(conf, &pem(&signer())).unwrap_err(),
        Error::Config("repository is set twice".into())
    );
}

#[test]
fn the_update_server_cannot_be_configured() {
    // docs/SIGNING.md: the signature policy covers exactly updates.nyraos.com; the host is fixed in code.
    let key = pem(&signer());
    for host in [
        "updates.nyraos.com",
        "updates.nyraos.com:443",
        "updates.nyraos.com.",
        "evil.example/updates.nyraos.com",
    ] {
        let conf = format!("host = {host}\n{CONF}");
        assert_eq!(
            Config::parse(&conf, &key).unwrap_err(),
            Error::Config("unknown key host".into()),
            "{host}"
        );
    }
}

#[test]
fn only_oci_repository_names_and_known_channels_are_accepted() {
    let key = pem(&signer());
    for repository in [
        "nyra:443",
        "nyra@sha256",
        "Nyra",
        "/nyra",
        "nyra/",
        "a//b",
        "-nyra",
        "nyra.",
        "",
        "ny ra",
    ] {
        let conf = CONF.replace("repository = nyra", &format!("repository = {repository}"));
        assert_eq!(
            Config::parse(&conf, &key).unwrap_err(),
            Error::Config("missing or invalid repository".into()),
            "{repository:?}"
        );
    }
    let nested = CONF.replace("repository = nyra", "repository = nyra/desktop-x_1.2");
    assert!(Config::parse(&nested, &key).is_ok());
    for channel in ["latest", "stable:x", "Stable", "../stable", ""] {
        let conf = CONF.replace("channel = stable", &format!("channel = {channel}"));
        assert_eq!(
            Config::parse(&conf, &key).unwrap_err(),
            Error::Config("missing or invalid channel".into()),
            "{channel:?}"
        );
    }
    for channel in CHANNELS {
        let conf = CONF.replace("channel = stable", &format!("channel = {channel}"));
        assert_eq!(Config::parse(&conf, &key).unwrap().channel, channel);
    }
}

#[test]
fn the_sheet_is_fetched_without_curlrc_over_tls_1_2_or_newer() {
    let cmd = curl(SHEET_URL);
    let args: Vec<_> = cmd.get_args().map(|a| a.to_str().unwrap()).collect();
    assert_eq!(args[0], "-q"); // must be first to skip .curlrc
    for wanted in [["--proto", "=https"], ["--max-filesize", "65536"]] {
        assert!(args.windows(2).any(|w| w == wanted), "{wanted:?}");
    }
    assert!(args.contains(&"--tlsv1.2"));
    assert!(!args.contains(&"-L") && !args.contains(&"--location"));
    assert_eq!(args.last(), Some(&SHEET_URL));
}

#[test]
fn a_discard_removes_the_staged_entries_at_once_through_esp_sync() {
    // esp-sync discard acts only when nyra-updated recorded the digest; boot-counter repeats it at
    // shutdown.
    let cmd = esp_sync_discard();
    assert_eq!(cmd.get_program(), "/usr/lib/nyra/boot/esp-sync");
    assert_eq!(cmd.get_args().collect::<Vec<_>>(), ["discard"]);
    assert_eq!(DISCARDED, "/run/nyra-updated/discarded");
}

#[test]
fn the_output_read_from_a_command_is_bounded() {
    let _spawns = no_parallel_spawns();
    let out = run(
        Command::new("sh").args(["-c", "head -c 3000000 /dev/zero"]),
        Duration::from_secs(10),
    )
    .unwrap();
    assert_eq!(out.stdout.len(), 1024 * 1024);
}

#[test]
fn the_seed1_test_key_is_refused_as_a_production_key() {
    assert_eq!(load_keys(TEST_KEY).unwrap_err(), Error::TestKey);
    assert_eq!(
        load_keys(&pem(&SigningKey::from_bytes(&[1; 32]))).unwrap_err(),
        Error::TestKey
    );
    // Also next to a real key, as during a key rotation.
    let both = format!("{}{}", pem(&signer()), TEST_KEY);
    assert_eq!(load_keys(&both).unwrap_err(), Error::TestKey);
}

#[test]
fn a_key_file_without_keys_means_updates_are_not_configured() {
    let dir = TempDir::new();
    fs::create_dir_all(&dir.0).unwrap();
    let conf = dir.0.join("updated.conf");
    let keys = dir.0.join("channel-sheet.pem");
    fs::write(
        &conf,
        "repository = nyra\nchannel = stable\nversion_floor = 2026.10.1\n",
    )
    .unwrap();

    // No key (a build of a fork, say): not configured, not an error.
    fs::write(&keys, "# no key yet\n").unwrap();
    assert!(Config::load(&conf, &keys).unwrap().is_none());
    // A key: configured.
    fs::write(&keys, pem(&signer())).unwrap();
    assert_eq!(Config::load(&conf, &keys).unwrap().unwrap().keys.len(), 1);
    // A broken key file and a missing one stay errors.
    fs::write(
        &keys,
        "-----BEGIN PUBLIC KEY-----\nnot base64\n-----END PUBLIC KEY-----\n",
    )
    .unwrap();
    assert_eq!(
        Config::load(&conf, &keys).unwrap_err(),
        Error::Sheet(nyra_channel_sheet::Error::InvalidPublicKey)
    );
    fs::remove_file(&keys).unwrap();
    assert!(matches!(Config::load(&conf, &keys), Err(Error::Io(_))));
    // An invalid configuration with no key is an error too, not "not configured".
    fs::write(&keys, "").unwrap();
    fs::write(&conf, "repository = nyra\n").unwrap();
    assert!(matches!(Config::load(&conf, &keys), Err(Error::Config(_))));
}

#[test]
fn a_key_file_without_keys_is_refused() {
    assert_eq!(
        load_keys("").unwrap_err(),
        Error::Sheet(nyra_channel_sheet::Error::NoTrustedKeys)
    );
}

// --- bootc status -----------------------------------------------------------------------------

#[test]
fn bootc_status_json_is_parsed() {
    // The shape of `bootc status --format json` (org.containers.bootc/v1, BootcHost), trimmed.
    let json = format!(
        r#"{{"apiVersion":"org.containers.bootc/v1","kind":"BootcHost","metadata":{{"name":"host"}},
        "spec":{{"bootOrder":"default","image":{{"image":"updates.nyraos.com/nyra@{B}","transport":"registry"}}}},
        "status":{{"booted":{{"cachedUpdate":null,"image":{{"architecture":"amd64",
        "image":{{"image":"updates.nyraos.com/nyra@{B}","transport":"registry"}},
        "imageDigest":"{B}","timestamp":null,"version":"2026.10.2"}},"incompatible":false,"pinned":false,
        "softRebootCapable":false,"store":null}},
        "rollback":{{"image":{{"image":{{"image":"updates.nyraos.com/nyra@{A}","transport":"registry"}},"imageDigest":"{A}","version":"2026.10.1"}}}},
        "rollbackQueued":false,"staged":{{"image":{{"image":{{"image":"localhost/mine","transport":"containers-storage"}},"imageDigest":"{C}","version":null}}}},"type":"bootcHost"}}}}"#
    );
    assert_eq!(
        parse_status(json.as_bytes()).unwrap(),
        Status {
            booted: dep(B),
            staged: Some(Deployment {
                digest: C.into(),
                version: None,
                image: None, // not the registry transport
            }),
            rollback: dep(A),
            rollback_queued: false,
        }
    );
    assert!(parse_status(b"{}").is_err());
}

#[test]
fn bootc_status_from_our_image_is_parsed() {
    // Captured on nyra-base in the VM test (tools/vm/updates.sh): bootc v1.16.13, composefs.
    // Right after the installation: no rollback, the image from local storage.
    let installed =
        parse_status(include_bytes!("../tests/data/bootc-status-installed.json")).unwrap();
    let booted = installed.booted.unwrap();
    assert_eq!(booted.version, None);
    assert_eq!(booted.image.as_deref(), Some("localhost/nyra-base:ci"));
    assert!(!config().is_official(booted.image.as_deref()));
    assert_eq!(
        (
            installed.staged,
            installed.rollback,
            installed.rollback_queued
        ),
        (None, None, false)
    );

    // v1 booted by its channel tag, v2 staged by digest, v0 (another registry) as rollback.
    let v1 = "sha256:f33c75f15a753ee24db0ee4c73d642eff7b1f7b575179c83538756389bfa23b4";
    let v2 = "sha256:98c4a7afb93599614398391da55b7f7a9b21f28de74a25ce51ae5cff4816443c";
    let v0 = "sha256:b48d7b7b895992b934aa28ddd8397951f4e801787b813621fcf233a777e6a0ad";
    let staged = parse_status(include_bytes!("../tests/data/bootc-status-staged.json")).unwrap();
    let dep = |digest: &str, version: &str, image: String| {
        Some(Deployment {
            digest: digest.into(),
            version: Some(version.into()),
            image: Some(image),
        })
    };
    assert_eq!(
        staged,
        Status {
            booted: dep(
                v1,
                "2026.10.1",
                "updates.nyraos.com/nyra-base:stable".into()
            ),
            staged: dep(
                v2,
                "2026.10.2",
                format!("updates.nyraos.com/nyra-base@{v2}")
            ),
            rollback: dep(v0, "2026.10.0", "other.test/nyra-base:v0".into()),
            rollback_queued: false,
        }
    );
    let cfg = Config {
        repository: "nyra-base".into(),
        ..config()
    };
    assert!(cfg.is_official(staged.booted.unwrap().image.as_deref()));
    assert!(!cfg.is_official(staged.rollback.unwrap().image.as_deref()));
}

#[test]
fn only_the_rollback_deployment_of_the_target_digest_is_deleted() {
    let staged = include_bytes!("../tests/data/bootc-status-staged.json");
    let v0 = "sha256:b48d7b7b895992b934aa28ddd8397951f4e801787b813621fcf233a777e6a0ad";
    let v1 = "sha256:f33c75f15a753ee24db0ee4c73d642eff7b1f7b575179c83538756389bfa23b4";
    assert_eq!(
        rollback_id(staged, v0).unwrap(),
        "1d2a78d94ae322dbce0c01a62ff58ab8534d82f687d158c852940a55287456783a0281cc968e006148265af385390675ff4953a1303cb3ad00c90c7b63806f05"
    );
    // Another image (here the booted one), or no rollback deployment at all: nothing to delete.
    assert!(matches!(rollback_id(staged, v1), Err(Error::Command(_))));
    let installed = include_bytes!("../tests/data/bootc-status-installed.json");
    assert!(matches!(rollback_id(installed, v0), Err(Error::Command(_))));
}

// --- rule 14: channels ------------------------------------------------------------------------

/// A sheet of `channel` issued at `issued_at`.
fn channel_sheet(channel: &str, sequence: u64, current: &str, issued_at: u64) -> Vec<u8> {
    let mut p = payload(sequence, current, &[]);
    p["channel"] = json!(channel);
    p["issued_at"] = json!(issued_at);
    sign(&p)
}

const BETA_URL: &str = "https://updates.nyraos.com/channels/nyra/beta";

/// A machine on C that followed `stable` until now and then chose `beta`.
fn switched_to_beta(dir: &TempDir) -> Fake {
    let mut fake = Fake::new(dir, C, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, dir), Ok(Outcome::UpToDate));
    set_channel(&dir.store(), "beta").unwrap();
    fake.calls.clear();
    fake
}

#[test]
fn the_chosen_channel_wins_over_the_image() {
    let dir = TempDir::new();
    set_channel(&dir.store(), "beta").unwrap();
    let mut fake = Fake::new(&dir, A, channel_sheet("beta", 100, C, NOW - DAY));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    assert_eq!(fake.calls[0], format!("fetch {BETA_URL}"));
    // A new image default does not change the choice.
    let beta_default = Config {
        channel: "dev".into(),
        ..config()
    };
    fake.calls.clear();
    let _ = check(&mut fake, &dir.store(), &beta_default, NOW);
    assert_eq!(fake.calls[0], format!("fetch {BETA_URL}"));
}

#[test]
fn an_unknown_channel_is_refused() {
    let dir = TempDir::new();
    set_channel(&dir.store(), "beta").unwrap();
    for name in ["nightly", "Beta", "", "beta/../stable"] {
        assert!(matches!(
            set_channel(&dir.store(), name),
            Err(Error::Config(_))
        ));
    }
    assert_eq!(dir.store().load().unwrap().channel.as_deref(), Some("beta"));
    // Nor is one written into the state by hand.
    let mut state = dir.store().load().unwrap();
    state.channel = Some("nightly".into());
    dir.store().save(&state).unwrap();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert!(matches!(run_check(&mut fake, &dir), Err(Error::Config(_))));
    assert!(fake.calls.is_empty());
}

#[test]
fn the_sheet_of_another_channel_is_refused() {
    let dir = TempDir::new();
    let mut fake = switched_to_beta(&dir);
    fake.sheet = channel_sheet("stable", 200, B, NOW);
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::Sheet(nyra_channel_sheet::Error::WrongChannel {
            expected: "nyra:beta".into(),
            found: "nyra:stable".into()
        }))
    );
    assert!(fake.staged().is_empty());
}

#[test]
fn a_newer_version_on_the_new_channel_ends_the_change() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, A, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    set_channel(&dir.store(), "beta").unwrap();
    fake.sheet = channel_sheet("beta", 100, B, NOW - DAY);
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(B))));
    let state = dir.store().load().unwrap();
    assert_eq!(state.following.as_deref(), Some("beta"));
    assert_eq!(state.channel_changed, None);
}

#[test]
fn after_a_change_of_channel_an_older_version_needs_a_sheet_issued_after_it_and_is_reached_once() {
    let dir = TempDir::new();
    let mut fake = switched_to_beta(&dir);
    let store = dir.store();
    // The change is seen at NOW. A sheet issued before it (an old or replayed one) does nothing.
    fake.sheet = channel_sheet("beta", 100, B, NOW - 1);
    assert_eq!(
        check(&mut fake, &store, &config(), NOW),
        Ok(Outcome::WaitingForSheet(image(B)))
    );
    assert!(fake.staged().is_empty());
    assert_eq!(store.load().unwrap().channel_changed, Some(NOW));
    // Issued after the change: the machine goes to the channel's version.
    fake.sheet = channel_sheet("beta", 200, B, NOW + 10);
    assert_eq!(
        check(&mut fake, &store, &config(), NOW + 60),
        Ok(Outcome::Staged(image(B)))
    );
    assert_eq!(store.load().unwrap().channel_changed, None);
    assert_eq!(store.load().unwrap().pending.as_deref(), Some(B));
    // Until the reboot, the same sheet and a later one with the same version just wait for it.
    assert_eq!(
        check(&mut fake, &store, &config(), NOW + 90),
        Ok(Outcome::WaitingForReboot(image(B)))
    );
    fake.sheet = channel_sheet("beta", 250, B, NOW + 6 * 60 * 60);
    assert_eq!(
        check(&mut fake, &store, &config(), NOW + 6 * 60 * 60 + 60),
        Ok(Outcome::WaitingForReboot(image(B)))
    );
    // Once: a later sheet with an even older version is refused as in any channel (rule 4).
    fake.sheet = channel_sheet("beta", 300, A, NOW + 6 * 60 * 60 + 10);
    assert!(matches!(
        check(&mut fake, &store, &config(), NOW + 6 * 60 * 60 + 120),
        Err(Error::Sheet(nyra_channel_sheet::Error::Downgrade { .. }))
    ));
    assert_eq!(fake.staged().len(), 1);
}

#[test]
fn after_a_change_of_channel_no_version_below_the_floor_retracted_or_failed() {
    let dir = TempDir::new();
    let mut fake = switched_to_beta(&dir);
    let store = dir.store();
    fake.sheet = channel_sheet("beta", 100, Z, NOW + 100);
    assert!(matches!(
        check(&mut fake, &store, &config(), NOW + 60),
        Err(Error::BelowFloor { .. })
    ));
    let mut state = store.load().unwrap();
    state.retracted.insert(B.into());
    state.failed.insert(A.into());
    store.save(&state).unwrap();
    fake.sheet = channel_sheet("beta", 200, B, NOW + 100);
    assert_eq!(
        check(&mut fake, &store, &config(), NOW + 60),
        Err(Error::Retracted(B.into()))
    );
    fake.sheet = channel_sheet("beta", 300, A, NOW + 100);
    assert_eq!(
        check(&mut fake, &store, &config(), NOW + 60),
        Err(Error::Failed(A.into()))
    );
    assert!(fake.staged().is_empty());
    // Nothing was done: the change still stands.
    assert_eq!(store.load().unwrap().channel_changed, Some(NOW + 60));
}

#[test]
fn a_new_image_default_is_a_change_for_a_machine_without_its_own_choice() {
    let dir = TempDir::new();
    let store = dir.store();
    let mut fake = Fake::new(&dir, C, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    let beta_default = Config {
        channel: "beta".into(),
        ..config()
    };
    fake.sheet = channel_sheet("beta", 100, B, NOW + 10);
    assert_eq!(
        check(&mut fake, &store, &beta_default, NOW + 60),
        Ok(Outcome::WaitingForSheet(image(B)))
    );
    assert_eq!(store.load().unwrap().channel_changed, Some(NOW + 60));
    fake.sheet = channel_sheet("beta", 200, B, NOW + 70);
    assert_eq!(
        check(&mut fake, &store, &beta_default, NOW + 80),
        Ok(Outcome::Staged(image(B)))
    );
}

#[test]
fn the_first_check_is_not_a_change_of_channel() {
    // A machine that never ran a check (or an older daemon's state): an older version is refused.
    let dir = TempDir::new();
    set_channel(&dir.store(), "beta").unwrap();
    let mut fake = Fake::new(&dir, C, channel_sheet("beta", 100, B, NOW));
    assert!(matches!(
        run_check(&mut fake, &dir),
        Err(Error::Sheet(nyra_channel_sheet::Error::Downgrade { .. }))
    ));
    assert_eq!(dir.store().load().unwrap().channel_changed, None);
}

#[test]
fn after_a_change_of_channel_the_local_rollback_deployment_is_staged_afresh_not_rolled_back() {
    // `bootc rollback` would boot it with the `/etc` it had then: old passwords and settings.
    let dir = TempDir::new();
    let mut fake = switched_to_beta(&dir);
    fake.status.rollback = dep(B);
    fake.sheet = channel_sheet("beta", 100, B, NOW + 100);
    let store = dir.store();
    assert_eq!(
        check(&mut fake, &store, &config(), NOW + 60),
        Ok(Outcome::Staged(image(B)))
    );
    assert_eq!(
        fake.calls,
        vec![
            format!("fetch {BETA_URL}"),
            format!("delete rollback {B}"),
            format!("stage updates.nyraos.com/nyra@{B}"),
        ]
    );
    let state = store.load().unwrap();
    assert_eq!(state.channel_changed, None);
    assert_eq!(state.pending.as_deref(), Some(B));
}

#[test]
fn a_change_of_channel_is_not_dated_before_the_newest_accepted_sheet() {
    // A clock that is behind: the sheets accepted so far say what time it is at least.
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, C, sheet(NOW + 500, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    set_channel(&dir.store(), "beta").unwrap();
    fake.sheet = channel_sheet("beta", 100, B, NOW + 100);
    assert_eq!(
        run_check(&mut fake, &dir),
        Ok(Outcome::WaitingForSheet(image(B)))
    );
    assert_eq!(dir.store().load().unwrap().channel_changed, Some(NOW + 500));
}

#[test]
fn a_sheet_issued_at_the_very_moment_of_the_change_counts() {
    let dir = TempDir::new();
    let mut fake = switched_to_beta(&dir);
    // The change is seen at NOW, and the sheet was issued at NOW.
    fake.sheet = channel_sheet("beta", 100, B, NOW);
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(B))));
    assert_eq!(dir.store().load().unwrap().channel_changed, None);
}

// --- a version failed only by the network health check (rule 15) -----------------------------

/// What the network health check leaves in the state directory: the links with an address at this
/// check, and, on the boot after a fallback it caused alone, `network-fallback`.
fn network_check_says(dir: &TempDir, links: &str, fallback: bool) {
    let state = dir.store().dir;
    fs::create_dir_all(&state).unwrap();
    fs::write(state.join("network-links"), links).unwrap();
    if fallback {
        fs::write(state.join("network-fallback"), "").unwrap();
    }
}

/// C staged on A, then C fell back three times: A runs, C is the rollback deployment.
fn fell_back_from_c(fake: &mut Fake) {
    fake.status = Status {
        booted: dep(A),
        staged: None,
        rollback: dep(C),
        ..Status::default()
    };
}

#[test]
fn a_version_failed_only_by_the_network_check_is_tried_once_more_a_day_later() {
    let dir = TempDir::new();
    let store = dir.store();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    fell_back_from_c(&mut fake);
    network_check_says(&dir, "enp1s0\n", true);
    assert_eq!(run_check(&mut fake, &dir), Err(Error::Failed(C.into())));
    let state = store.load().unwrap();
    assert!(state.failed.contains(C));
    assert_eq!(
        state.network_retry,
        Some(NetworkRetry {
            digest: C.into(),
            failed_at: NOW,
            links: "enp1s0\n".into(),
            retried: false
        })
    );
    assert!(!store.dir.join("network-fallback").exists());
    // Not before a day on the same network.
    let day = NOW + DAY_SECONDS;
    assert_eq!(
        check(&mut fake, &store, &config(), day - 1),
        Err(Error::Failed(C.into()))
    );
    // A day later: its old deployment goes (it kept the /etc of its tries), staged afresh.
    assert_eq!(
        check(&mut fake, &store, &config(), day),
        Ok(Outcome::Staged(image(C)))
    );
    assert!(fake.calls.contains(&format!("delete rollback {C}")));
    let state = store.load().unwrap();
    assert!(!state.failed.contains(C));
    assert_eq!(state.pending.as_deref(), Some(C));
    assert!(state.network_retry.as_ref().unwrap().retried);
    // It fails the network check again: final, even a day later or on another network.
    fell_back_from_c(&mut fake);
    network_check_says(&dir, "enp1s0\n", true);
    assert_eq!(
        check(&mut fake, &store, &config(), day + 60),
        Err(Error::Failed(C.into()))
    );
    network_check_says(&dir, "wlan0\n", false);
    assert_eq!(
        check(&mut fake, &store, &config(), day + 2 * DAY_SECONDS),
        Err(Error::Failed(C.into()))
    );
    assert_eq!(fake.staged().len(), 2);
}

#[test]
fn a_version_failed_only_by_the_network_check_is_tried_at_once_on_another_network() {
    let dir = TempDir::new();
    let store = dir.store();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    run_check(&mut fake, &dir).unwrap();
    fell_back_from_c(&mut fake);
    network_check_says(&dir, "enp1s0\n", true);
    assert_eq!(run_check(&mut fake, &dir), Err(Error::Failed(C.into())));
    network_check_says(&dir, "wlan0\n", false);
    assert_eq!(
        check(&mut fake, &store, &config(), NOW + 60),
        Ok(Outcome::Staged(image(C)))
    );
    // It boots healthy: nothing is left of its failure.
    fake.status = Status {
        booted: dep(C),
        staged: None,
        rollback: dep(A),
        ..Status::default()
    };
    assert_eq!(
        check(&mut fake, &store, &config(), NOW + 120),
        Ok(Outcome::UpToDate)
    );
    let state = store.load().unwrap();
    assert_eq!((state.pending, state.network_retry), (None, None));
    assert!(state.failed.is_empty());
}

#[test]
fn any_other_failure_stays_final() {
    let dir = TempDir::new();
    let store = dir.store();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    run_check(&mut fake, &dir).unwrap();
    // The network check did not say the fallback was its alone (another check failed).
    fell_back_from_c(&mut fake);
    network_check_says(&dir, "enp1s0\n", false);
    assert_eq!(run_check(&mut fake, &dir), Err(Error::Failed(C.into())));
    assert_eq!(store.load().unwrap().network_retry, None);
    network_check_says(&dir, "wlan0\n", false);
    assert_eq!(
        check(&mut fake, &store, &config(), NOW + 2 * DAY_SECONDS),
        Err(Error::Failed(C.into()))
    );
    assert_eq!(fake.staged().len(), 1);
}

#[test]
fn the_network_checks_word_counts_for_the_next_check_only() {
    // Left by a fallback no check settles (a version staged by hand): taken, and no later
    // fallback for another reason becomes a network one.
    let dir = TempDir::new();
    let store = dir.store();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    network_check_says(&dir, "enp1s0\n", true);
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::Staged(image(C))));
    assert!(!store.dir.join("network-fallback").exists());
    fell_back_from_c(&mut fake);
    assert_eq!(run_check(&mut fake, &dir), Err(Error::Failed(C.into())));
    assert_eq!(store.load().unwrap().network_retry, None);
}

// --- `nyra-updated install VERSION` (src/install.rs) ------------------------------------------

mod install_tests {
    use super::*;
    use crate::install::{check_version, install, is_version, PolicyFiles};
    use std::os::unix::fs::symlink;

    const SIGNER: &str = "signer@project.iam.gserviceaccount.com";

    #[test]
    fn only_a_release_version_passes() {
        for good in ["2026.10.600", "2026.1.1", "2027.12.999999", "2026.10.0"] {
            assert!(is_version(good), "{good}");
        }
        for bad in [
            "",
            "2026.10",
            "2026.10.600.1",
            "026.10.600",
            "20261.10.600",
            "2026.010.600",
            "2026.10.0600",
            "2026.10.6000000",
            "2026.13a.600",
            "2026.10.600\n",
            " 2026.10.600",
            "-2026.10.600",
            "2026.10.600:latest",
            "2026.10.600@sha256:aa",
            "../2026.10.600",
            "2026.10.600/x",
            "2026.10.60\u{0660}",
            "stable",
        ] {
            assert!(!is_version(bad), "{bad:?}");
            assert!(check_version(bad).is_err(), "{bad:?}");
        }
        // The refusal does not repeat the argument.
        let e = check_version("$(reboot)").unwrap_err().to_string();
        assert!(!e.contains("reboot"), "{e}");
    }

    fn installed(fake: &mut Fake, dir: &TempDir, v: &str) -> Result<String, Error> {
        install(fake, &dir.store(), &config(), NOW, v)
    }

    /// A sheet for everybody that offers `current` and `previous`; `halted`: nobody gets `current`.
    fn two_versions(current: &str, previous: &str, halted: bool, retracted: &[&str]) -> Vec<u8> {
        let mut p = payload(100, current, retracted);
        p["previous"] = json!({"digest": previous, "version": version(previous)});
        p["halted"] = json!(halted);
        sign(&p)
    }

    #[test]
    fn a_newer_version_is_staged_by_the_digest_of_the_sheet_and_remembered() {
        let dir = TempDir::new();
        let mut fake = Fake::new(&dir, A, sheet(100, B, &[]));
        installed(&mut fake, &dir, "2026.10.2").unwrap();
        // The sheet first, then one pull by digest, no reboot, nothing discarded.
        assert_eq!(
            fake.calls,
            [
                format!("fetch {SHEET_URL}"),
                format!("stage updates.nyraos.com/nyra@{B}")
            ]
        );
        // The next check learns from `pending` whether it booted or the machine fell back.
        let state = dir.store().load().unwrap();
        assert_eq!(state.pending.as_deref(), Some(B));
        assert_eq!(state.sheets.len(), 1);
    }

    #[test]
    fn the_same_or_an_older_version_is_never_staged() {
        let dir = TempDir::new();
        // B runs (2026.10.2): the same version, older ones, and a lower number that sorts higher
        // as text.
        for refused in ["2026.10.2", "2026.10.1", "2026.9.999", "2025.12.5"] {
            let mut fake = Fake::new(&dir, B, two_versions(C, B, false, &[]));
            let e = installed(&mut fake, &dir, refused).unwrap_err();
            assert!(e.to_string().contains("not newer"), "{refused}: {e}");
            assert!(fake.calls.is_empty(), "{refused}: {:?}", fake.calls);
        }
        // Numbers, not text: 2026.10.9 runs, so 2026.10.8 is not newer.
        let mut fake = Fake::new(&dir, B, two_versions(C, B, false, &[]));
        fake.status.booted.as_mut().unwrap().version = Some("2026.10.9".into());
        let e = installed(&mut fake, &dir, "2026.10.8").unwrap_err();
        assert!(e.to_string().contains("not newer"), "{e}");
        assert!(fake.calls.is_empty(), "{:?}", fake.calls);
    }

    #[test]
    fn an_unknown_running_version_or_a_floor_above_the_target_stages_nothing() {
        let dir = TempDir::new();
        let mut fake = Fake::new(&dir, A, sheet(100, B, &[]));
        fake.status.booted.as_mut().unwrap().version = None;
        assert!(installed(&mut fake, &dir, "2026.10.2").is_err());
        let mut fake = Fake::new(&dir, A, sheet(100, B, &[]));
        let floor = Config {
            version_floor: "2026.10.5".into(),
            ..config()
        };
        assert_eq!(
            install(&mut fake, &dir.store(), &floor, NOW, "2026.10.2"),
            Err(Error::BelowFloor {
                version: "2026.10.2".into(),
                floor: "2026.10.5".into()
            })
        );
        assert!(fake.calls.is_empty(), "{:?}", fake.calls);
    }

    #[test]
    fn what_bootc_staged_must_be_the_digest_of_the_sheet() {
        // The registry answered with another image than the sheet's digest: discarded.
        let dir = TempDir::new();
        let mut fake = Fake::new(&dir, A, sheet(100, B, &[]));
        fake.stage_digest = Some(C.into());
        let e = installed(&mut fake, &dir, "2026.10.2").unwrap_err();
        assert_eq!(
            e,
            Error::DigestMismatch {
                expected: B.into(),
                found: C.into()
            }
        );
        assert_eq!(fake.discarded.as_deref(), Some(C));
    }

    #[test]
    fn a_retracted_or_failed_version_is_refused_before_anything_is_pulled() {
        for retracted in [true, false] {
            let dir = TempDir::new();
            let mut state = State::default();
            if retracted {
                state.retracted.insert(B.into());
            } else {
                state.failed.insert(B.into());
            }
            dir.store().save(&state).unwrap();
            let mut fake = Fake::new(&dir, A, sheet(100, B, &[]));
            let e = installed(&mut fake, &dir, "2026.10.2").unwrap_err();
            if retracted {
                assert_eq!(e, Error::Retracted(B.into()));
            } else {
                assert_eq!(e, Error::Failed(B.into()));
            }
            assert_eq!(fake.calls, [format!("fetch {SHEET_URL}")]);
        }
    }

    #[test]
    fn only_the_current_or_the_previous_version_of_the_sheet_is_staged() {
        // A sheet that offers C and B: either, by its digest. A is below both.
        for (v, digest) in [("2026.10.3", C), ("2026.10.2", B)] {
            let dir = TempDir::new();
            let mut fake = Fake::new(&dir, Z, two_versions(C, B, false, &[]));
            installed(&mut fake, &dir, v).unwrap();
            assert_eq!(
                fake.staged(),
                [&format!("stage updates.nyraos.com/nyra@{digest}")]
            );
        }
        // Another version, even a newer one than the machine runs, is refused.
        let dir = TempDir::new();
        let mut fake = Fake::new(&dir, Z, two_versions(C, B, false, &[]));
        let e = installed(&mut fake, &dir, "2026.10.1").unwrap_err();
        assert!(
            e.to_string()
                .contains("offers only 2026.10.3 and 2026.10.2"),
            "{e}"
        );
        assert_eq!(fake.calls, [format!("fetch {SHEET_URL}")]);
        // While the channel is halted nothing is staged, not even the previous version.
        let dir = TempDir::new();
        for v in ["2026.10.3", "2026.10.2"] {
            let mut fake = Fake::new(&dir, Z, two_versions(C, B, true, &[]));
            let e = installed(&mut fake, &dir, v).unwrap_err();
            assert!(e.to_string().contains("halted"), "{v}: {e}");
            assert_eq!(fake.calls, [format!("fetch {SHEET_URL}")]);
        }
    }

    #[test]
    fn without_a_good_sheet_nothing_is_pulled_and_its_retractions_are_kept() {
        // No sheet (the server down, the network away), or one signed by another key.
        for broken in [true, false] {
            let dir = TempDir::new();
            let mut fake = Fake::new(&dir, A, sheet(100, B, &[]));
            if broken {
                fake.fetch_error = Some(Error::Command("curl failed".into()));
            } else {
                fake.sheet = b"not a sheet".to_vec();
            }
            assert!(installed(&mut fake, &dir, "2026.10.2").is_err());
            assert_eq!(fake.calls, [format!("fetch {SHEET_URL}")]);
        }
        // A version the sheet does not offer is refused, and what the sheet retracted is remembered.
        let dir = TempDir::new();
        let mut fake = Fake::new(&dir, Z, sheet(100, C, &[B]));
        assert!(installed(&mut fake, &dir, "2026.10.2").is_err());
        assert!(dir.store().load().unwrap().retracted.contains(B));
    }

    #[test]
    fn the_state_of_the_last_update_is_settled_before_a_new_one_is_staged() {
        // B was prepared, booted, and the machine fell back to A, which reported the network
        // check (`network-fallback`): as at the start of a check, B is failed, retried once, and
        // the marker is taken.
        let dir = TempDir::new();
        let store = dir.store();
        store
            .save(&State {
                pending: Some(B.into()),
                ..State::default()
            })
            .unwrap();
        fs::write(store.dir.join("network-fallback"), "").unwrap();
        let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
        fake.status.rollback = dep(B);
        installed(&mut fake, &dir, "2026.10.3").unwrap();
        let state = store.load().unwrap();
        assert!(state.failed.contains(B));
        assert_eq!(state.network_retry.map(|r| r.digest).as_deref(), Some(B));
        assert_eq!(state.pending.as_deref(), Some(C));
        assert!(!store.dir.join("network-fallback").exists());
    }

    /// A tree like an installed system's: the shipped file and the link to it in `etc`.
    fn policy_files(dir: &TempDir, policy: &str) -> PolicyFiles {
        let shipped = dir.0.join("usr/policy.json");
        let etc = dir.0.join("etc/policy.json");
        fs::create_dir_all(shipped.parent().unwrap()).unwrap();
        fs::create_dir_all(etc.parent().unwrap()).unwrap();
        fs::write(&shipped, policy).unwrap();
        symlink(&shipped, &etc).unwrap();
        PolicyFiles {
            links: vec![(etc, shipped.clone())],
            policy: shipped,
            user_policies: vec![dir.0.join("home-policy.json")],
            env_policy: false,
        }
    }

    fn policy(email: &str) -> String {
        json!({"transports": {"docker": {"updates.nyraos.com": [
            {"type": "sigstoreSigned", "fulcio": {"subjectEmail": email}}
        ]}}})
        .to_string()
    }

    #[test]
    fn only_the_shipped_policy_allows_a_pull() {
        let dir = TempDir::new();
        let files = policy_files(&dir, &policy(SIGNER));
        files.check().unwrap();
        // The /etc link points elsewhere: the test VMs' stand-in policy, or a user's.
        let other = dir.0.join("other.json");
        fs::write(&other, policy(SIGNER)).unwrap();
        fs::remove_file(&files.links[0].0).unwrap();
        symlink(&other, &files.links[0].0).unwrap();
        assert!(files.check().is_err());
        // A missing link.
        fs::remove_file(&files.links[0].0).unwrap();
        assert!(files.check().is_err());
        // A per-user policy, and CONTAINERS_POLICY_JSON.
        let dir = TempDir::new();
        let mut files = policy_files(&dir, &policy(SIGNER));
        fs::write(&files.user_policies[0], "{}").unwrap();
        assert!(files.check().is_err());
        fs::remove_file(&files.user_policies[0]).unwrap();
        files.check().unwrap();
        files.env_policy = true;
        assert!(files.check().is_err());
    }

    #[test]
    fn a_policy_without_one_real_signer_is_refused() {
        let two = json!({"transports": {"docker": {"updates.nyraos.com": [
            {"type": "sigstoreSigned", "fulcio": {"subjectEmail": "a@b.c"}},
            {"type": "sigstoreSigned", "fulcio": {"subjectEmail": "d@e.f"}}
        ]}}});
        let accepting = json!({"transports": {"docker": {"updates.nyraos.com": [
            {"type": "insecureAcceptAnything"}
        ]}}});
        let other_host = json!({"transports": {"docker": {"example.com": [
            {"type": "sigstoreSigned", "fulcio": {"subjectEmail": "a@b.c"}}
        ]}}});
        for text in [
            policy("signer-not-configured@nyra.invalid"),
            policy(""),
            two.to_string(),
            accepting.to_string(),
            other_host.to_string(),
            "{}".into(),
            "not json".into(),
        ] {
            let dir = TempDir::new();
            assert!(policy_files(&dir, &text).check().is_err(), "{text}");
        }
    }

    #[test]
    fn the_install_unit_has_time_for_a_pull_and_takes_the_instance_as_one_argument() {
        let unit =
            include_str!("../../../files/usr/lib/systemd/system/nyra-updated-install@.service");
        let limit = unit
            .lines()
            .find_map(|l| l.strip_prefix("TimeoutStartSec="))
            .and_then(|v| v.strip_suffix("min"))
            .and_then(|m| m.split_once('h'))
            .and_then(|(h, m)| Some(h.parse::<u64>().ok()? * 60 + m.parse::<u64>().ok()?))
            .map(|m| Duration::from_secs(m * 60))
            .expect("TimeoutStartSec=<h>h<m>min");
        assert!(limit > STAGE_TIMEOUT + 4 * SHORT, "{limit:?}");
        assert!(unit.contains("ExecStart=/usr/libexec/nyra-updated install %i\n"));
        assert!(!unit.contains("%I"), "the escaped instance only");
    }
}
