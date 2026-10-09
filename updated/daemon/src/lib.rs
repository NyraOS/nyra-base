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
//!   is still on trial, so systemd-boot's boot counting can fall back to the previous one.
//!
//! The rules, each with a unit test in `tests.rs`:
//!
//! 1. One update at a time ([`Lock`]); every bootc, systemctl and curl call has a time limit and
//!    is killed with its children when it hangs (`system::run`).
//! 2. The sheet's sequence and retracted digests are written atomically to the state directory
//!    **before** anything acts on the sheet; a lower sequence is refused, an equal one only for
//!    the identical payload.
//! 3. A retracted digest is remembered and never a target again, even if a later sheet serves it;
//!    an installed version retracted by any accepted sheet may still go back.
//! 4. No downgrade ([`nyra_channel_sheet::Sheet::decide`]), and no target below the image's
//!    version floor, including signed retractions (a leaked old key cannot send machines back to
//!    any image ever signed).
//! 5. A version the machine fell back from is marked failed and never prepared or offered again.
//! 6. A retraction to the version that is already the local rollback deployment uses
//!    `bootc rollback` (bootc would answer "No changes" to a switch).
//! 7. The image is pulled pinned by digest, and the staged digest must be the sheet's; a wrong
//!    staged deployment is discarded: it is never finalized ([`System::discard_staged`]), whatever
//!    the rollback deployment is, and nothing else is staged until the next reboot.
//! 8. A failed health check reboots fully: never a soft reboot, always after a soft reboot (which
//!    bypasses boot counting), and never on a version that is not on trial (no reboot loop).
//! 9. The first healthy boot of a new version must have been a full boot with a boot counter
//!    (`LoaderBootCountPath` set by systemd-boot): otherwise it is reported as an error, not
//!    swallowed, because the counter service can fail silently and a soft reboot skips counting.
//!    This daemon never soft-reboots (the [`System`] trait has no soft reboot at all).
//! 10. Nothing is done when the booted image is not from `updates.nyraos.com/<repository>`
//!     ([`HOST`] is fixed in code, `docs/SIGNING.md`): an owner who switched to their own image keeps it.
//!     The outcome says so ([`Outcome::ForeignImage`]), so such a machine is not silently without updates.
//! 11. A staged version that becomes unacceptable before the reboot (retracted, failed, or below the
//!     version floor) is discarded the same way as in rule 7.
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
    /// Another `nyra-updated` holds the lock.
    Busy,
    Timeout(String),
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
            Error::Busy => write!(f, "another nyra-updated is running"),
            Error::Timeout(what) => write!(f, "{what} timed out and was stopped"),
            Error::Command(e) | Error::Io(e) | Error::Config(e) => write!(f, "{e}"),
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
    pub channel: String,
    /// No target older than this, not even a signed retraction.
    pub version_floor: String,
    pub keys: Vec<VerifyingKey>,
}

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
    /// `conf`: `key = value` lines (`repository`, `channel`, `version_floor`), `#` comments.
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

    /// The booted image comes from our registry and repository (`bootc status` reference, by
    /// tag or digest). Anything else was chosen on purpose by the machine's owner.
    pub fn is_official(&self, image: Option<&str>) -> bool {
        image
            .and_then(|i| i.strip_prefix(HOST))
            .and_then(|i| i.strip_prefix('/'))
            .and_then(|i| i.strip_prefix(self.repository.as_str()))
            .is_some_and(|rest| rest.starts_with(':') || rest.starts_with('@'))
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

    /// The outcome of the last check, `last-check.json` (`time`: Unix seconds, `ok`, `message`):
    /// a broken state or an image without updates must not stay silent. The journal has the same
    /// line; Settings will read this file through the daemon.
    pub fn save_report(&self, time: u64, ok: bool, message: &str) -> Result<(), Error> {
        let report = serde_json::json!({"time": time, "ok": ok, "message": message});
        self.write_atomic("last-check.json", report.to_string().as_bytes())
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
    /// Prepares `image_ref` for the next boot, without applying it (`bootc switch`).
    fn stage(&mut self, image_ref: &str) -> Result<(), Error>;
    /// Discards a staged deployment and swaps the boot order (`bootc rollback`): the rollback
    /// deployment becomes the next boot, or, if it already was, the booted one again. Fails when
    /// there is no rollback deployment.
    fn rollback(&mut self) -> Result<(), Error>;
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
    /// The target is already staged; the user reboots when they want.
    WaitingForReboot(Image),
    Staged(Image),
    /// The target is the local rollback deployment: `bootc rollback` made it the next boot.
    RolledBack(Image),
    /// The staged deployment (this digest) must not boot and was discarded (rules 7 and 11); nothing
    /// more happens until the next reboot.
    Discarded(String),
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

/// Learns what became of the version prepared last time (rule 5).
fn settle_pending(state: &mut State, status: &Status) {
    let Some(pending) = state.pending.clone() else {
        return;
    };
    if Status::digest(&status.staged) == Some(&pending) {
        return; // still waiting for the reboot
    }
    if Status::digest(&status.rollback) == Some(&pending)
        && Status::digest(&status.booted) != Some(&pending)
    {
        // It booted and the machine came back: systemd-boot's fallback after three tries.
        state.failed.insert(pending);
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

/// The local version "Revino la versiunea anterioară" may offer: the rollback deployment, unless
/// the machine fell back from it or it was retracted.
pub fn offered_rollback<'a>(status: &'a Status, state: &State) -> Option<&'a Deployment> {
    status
        .rollback
        .as_ref()
        .filter(|d| !state.failed.contains(&d.digest) && !state.retracted.contains(&d.digest))
}

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
    settle_pending(&mut state, &status);
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

    // Rule 2: verify, then persist the sequence and the retractions before acting.
    let envelope = sys.fetch_sheet(&cfg.sheet_url())?;
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
    if let Some(staged) = &status.staged {
        let below_floor = staged.version.as_deref().is_some_and(|v| {
            compare_versions(v, &cfg.version_floor).is_ok_and(|o| o == Ordering::Less)
        });
        if state.retracted.contains(&staged.digest)
            || state.failed.contains(&staged.digest)
            || below_floor
        {
            sys.discard_staged(&staged.digest)?;
            state.pending = None;
            store.save(&state)?;
            return Ok(Outcome::Discarded(staged.digest.clone()));
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
    let target = match sheet.decide(&installed, group)? {
        Decision::UpToDate => return Ok(Outcome::UpToDate),
        Decision::Update(t) | Decision::Retract(t) => t,
    };
    check_target(&target, &state, &cfg.version_floor)?;

    if Status::digest(&status.staged) == Some(&target.digest) {
        return Ok(Outcome::WaitingForReboot(target));
    }
    if Status::digest(&status.rollback) == Some(&target.digest) {
        sys.rollback()?;
        return Ok(Outcome::RolledBack(target));
    }

    state.pending = Some(target.digest.clone());
    store.save(&state)?;
    sys.stage(&cfg.image_ref(&target.digest))?;
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HealthAction {
    /// Full reboot started: the next try, or systemd-boot's fallback.
    Reboot,
    /// The running version is not on trial: a reboot would boot it again (a loop). It stays up,
    /// unhealthy, for the user and the repair tools.
    Stay,
}

/// A health check failed on this boot (rule 8).
pub fn on_health_failure(sys: &mut impl System) -> Result<HealthAction, Error> {
    let info = sys.boot_info()?;
    if info.soft_rebooted || info.on_trial {
        sys.reboot()?;
        return Ok(HealthAction::Reboot);
    }
    Ok(HealthAction::Stay)
}

#[cfg(test)]
mod tests;
