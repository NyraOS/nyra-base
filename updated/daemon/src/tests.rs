// SPDX-License-Identifier: GPL-3.0-or-later
//! One test (at least) per rule of the crate documentation, with a fake [`System`].

use super::system::{curl, parse_status, run};
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
        version_floor: "2026.10.1".into(),
        keys: vec![signer().verifying_key()],
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
    stage_error: Option<Error>,
    /// What bootc ends up staging, if not the digest it was asked for.
    stage_digest: Option<String>,
    calls: Vec<String>,
    store_dir: PathBuf,
    /// The state on disk at the moment `stage` was called.
    state_at_stage: Option<State>,
    /// The rollback deployment is the next boot.
    rollback_queued: bool,
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
            stage_error: None,
            stage_digest: None,
            calls: Vec::new(),
            store_dir: dir.store().dir,
            state_at_stage: None,
            rollback_queued: false,
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
        Ok(self.sheet.clone())
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
            digest,
            version: None,
        });
        Ok(())
    }
    /// Like `bootc rollback`: discards a staged deployment and swaps the boot order.
    fn rollback(&mut self) -> Result<(), Error> {
        self.calls.push("rollback".into());
        self.status.staged = None;
        self.rollback_queued = !self.rollback_queued;
        Ok(())
    }
    fn reboot(&mut self) -> Result<(), Error> {
        self.calls.push("reboot".into());
        Ok(())
    }
}

fn run_check(fake: &mut Fake, dir: &TempDir) -> Result<Outcome, Error> {
    check(fake, &dir.store(), &config(), NOW)
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

#[test]
fn a_staged_digest_other_than_the_sheet_is_an_error() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, A, sheet(100, C, &[]));
    fake.status.rollback = dep(Z);
    fake.stage_digest = Some(B.into());
    assert_eq!(
        run_check(&mut fake, &dir),
        Err(Error::DigestMismatch {
            expected: C.into(),
            found: B.into()
        })
    );
    // The wrong deployment is discarded and the booted version stays the next boot.
    assert_eq!(fake.status.staged, None);
    assert!(!fake.rollback_queued);
    assert_eq!(fake.calls.iter().filter(|c| *c == "rollback").count(), 2);
}

// --- rule 10: only our own images -------------------------------------------------------------

#[test]
fn nothing_happens_on_an_image_the_owner_chose() {
    for image in [
        Some("quay.io/someone/nyra:stable"),
        Some("updates.nyraos.com/nyra-fork:stable"),
        Some("updates.nyraos.com:443/nyra@sha256:x"),
        Some("updates.nyraos.com./nyra:stable"),
        Some("updates.nyraos.com/other/nyra:stable"),
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
        Err(Error::BelowFloor {
            version: "2026.9.1".into(),
            floor: "2026.10.1".into()
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
    };
    assert_eq!(run_check(&mut fake, &dir), Err(Error::Failed(C.into())));
    let state = dir.store().load().unwrap();
    assert!(state.failed.contains(C));
    assert_eq!(state.pending, None);
    assert_eq!(fake.staged().len(), 1);
    assert_eq!(offered_rollback(&fake.status, &state), None);
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
    };
    assert_eq!(run_check(&mut fake, &dir), Ok(Outcome::UpToDate));
    let state = dir.store().load().unwrap();
    assert_eq!(state.pending, None);
    assert!(state.failed.is_empty());
    assert_eq!(offered_rollback(&fake.status, &state), dep(A).as_ref());
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
    };
    assert_eq!(offered_rollback(&status, &state), None);
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
    assert_eq!(run_check(&mut fake, &dir), Err(Error::Failed(A.into())));
    assert!(!fake.calls.contains(&"rollback".to_string()));
}

// --- rule 8: health check failures ------------------------------------------------------------

#[test]
fn a_failed_health_check_on_trial_reboots_fully() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, C, Vec::new());
    fake.boot.on_trial = true;
    assert_eq!(on_health_failure(&mut fake), Ok(HealthAction::Reboot));
    assert_eq!(fake.calls, vec!["reboot"]);
}

#[test]
fn a_failed_health_check_after_a_soft_reboot_reboots_fully() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, C, Vec::new());
    fake.boot.soft_rebooted = true;
    assert_eq!(on_health_failure(&mut fake), Ok(HealthAction::Reboot));
    assert_eq!(fake.calls, vec!["reboot"]);
}

#[test]
fn a_failed_health_check_off_trial_does_not_loop_reboots() {
    let dir = TempDir::new();
    let mut fake = Fake::new(&dir, C, Vec::new());
    assert_eq!(on_health_failure(&mut fake), Ok(HealthAction::Stay));
    assert!(fake.calls.is_empty());
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
        }
    );
    assert!(parse_status(b"{}").is_err());
}
