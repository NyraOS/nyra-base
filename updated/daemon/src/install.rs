// SPDX-License-Identifier: GPL-3.0-or-later
//! `nyra-updated install VERSION`: an administrator stages one named release from a terminal
//! (`docs/UPDATES.md`, "Updating from a terminal as an administrator"). The command runs as root in
//! `nyra-updated-install@VERSION.service`, which polkit lets only members of `sudo` start, with
//! their own password. Nothing here trusts the argument: it is checked against a fixed shape first,
//! and the image reference is built from the image's repository and that version only.
//!
//! The guarantee is the signature policy, as for a manual `bootc switch` (`docs/UPDATES.md`,
//! "Moving a machine to updates.nyraos.com"): [`PolicyFiles::check`] refuses to start the pull
//! unless the policy is the shipped one. On top of it the channel sheet is mandatory, as for a
//! check: without a sheet key nothing is installed. The sheet is fetched and verified, and the
//! version must be the one it calls `current` or `previous` (not while it is halted). The image is
//! pulled by the digest of the sheet, never by tag, and what bootc staged must be that digest
//! ([`stage_target`]). The version must be newer than the booted one (no downgrade). The state a
//! check starts from is settled first ([`settle_state`]). Nothing reboots.

use crate::{
    check_target, compare_versions, io, payload_sha256, settle_state, stage_target, Accepted,
    Config, Error, State, Status, Store, System, HOST,
};
use nyra_channel_sheet::{verify, Image, Sheet};
use serde_json::Value;
use std::cmp::Ordering;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// The signer of a machine that was installed before the real address was committed.
const PLACEHOLDER_DOMAIN: &str = "@nyra.invalid";

/// Year, month and build: the number of digits each may have.
const SHAPE: [(usize, usize); 3] = [(4, 4), (1, 2), (1, 6)];

/// `2026.10.600`: three numbers of 4, 1-2 and 1-6 digits, without leading zeros. A tag, a path or
/// an option can not have this shape.
pub fn is_version(v: &str) -> bool {
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 3
        && parts.iter().zip(SHAPE).all(|(p, (min, max))| {
            (min..=max).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_digit())
        })
        && compare_versions(v, v).is_ok()
}

/// The refusal for an argument that is not a release version. It does not repeat the argument.
pub fn check_version(v: &str) -> Result<(), Error> {
    if is_version(v) {
        return Ok(());
    }
    Err(Error::Config(
        "not a release version: expected YEAR.MONTH.BUILD, for example 2026.10.600".into(),
    ))
}

/// Where an `install` leaves its result for the administrator who started it (`nyra update`), who
/// can read neither the journal nor `bootc status`. On `/run`: it is gone at the next boot, which
/// is when a staged version stops being staged.
pub const RESULT: &str = "/run/nyra-updated-install.result";

/// What `install` answers when the version is staged already (by a check, or by an earlier install).
pub const ALREADY_STAGED: &str = "already staged";

/// The one line of the result: `staged VERSION` (with `already` when nothing had to be done), or
/// `failed VERSION` and the reason.
pub fn result_line(version: &str, outcome: &Result<String, Error>) -> String {
    match outcome {
        Ok(m) if m.starts_with(ALREADY_STAGED) => format!("staged {version} already"),
        Ok(_) => format!("staged {version}"),
        Err(e) => format!("failed {version} {}", crate::one_line(&e.to_string())),
    }
}

/// Writes the result for everybody to read (mode 0644 although the unit's umask is 0077). A version
/// that is not one is not written: the line is read back by a program. Best effort, like the
/// notice of a failed health check: a result that can not be written does not change the outcome.
pub fn write_result(path: &Path, version: &str, outcome: &Result<String, Error>) {
    if !is_version(version) {
        return;
    }
    let tmp = path.with_extension("tmp");
    let line = format!("{}\n", result_line(version, outcome));
    let written = fs::write(&tmp, line)
        .and_then(|()| fs::set_permissions(&tmp, fs::Permissions::from_mode(0o644)))
        .and_then(|()| fs::rename(&tmp, path));
    if let Err(e) = written {
        eprintln!("<4>nyra-updated: {}: {e}", path.display());
    }
}

/// Where the signature policy lives and who could replace it.
pub struct PolicyFiles {
    /// Each link of `/etc` and the file of the image it must resolve to.
    pub links: Vec<(PathBuf, PathBuf)>,
    /// The shipped policy, read for the signer.
    pub policy: PathBuf,
    /// Policies a user could have: containers/image reads them before `/etc`.
    pub user_policies: Vec<PathBuf>,
    /// `CONTAINERS_POLICY_JSON` is set: it replaces every policy file.
    pub env_policy: bool,
}

impl PolicyFiles {
    pub fn system() -> PolicyFiles {
        let shipped = |name: &str| PathBuf::from("/usr/lib/nyra/containers").join(name);
        let etc = |name: &str| PathBuf::from("/etc/containers").join(name);
        let mut user_policies = vec![PathBuf::from("/root/.config/containers/policy.json")];
        for (var, tail) in [("XDG_CONFIG_HOME", ""), ("HOME", ".config")] {
            if let Some(base) = std::env::var_os(var) {
                user_policies.push(Path::new(&base).join(tail).join("containers/policy.json"));
            }
        }
        PolicyFiles {
            links: vec![
                (etc("policy.json"), shipped("policy.json")),
                (
                    etc("registries.d/nyra.yaml"),
                    shipped("registries.d/nyra.yaml"),
                ),
            ],
            policy: shipped("policy.json"),
            user_policies,
            env_policy: std::env::var_os("CONTAINERS_POLICY_JSON").is_some(),
        }
    }

    /// Refuses unless a pull from [`HOST`] is checked against the shipped policy with the real
    /// signer.
    pub fn check(&self) -> Result<(), Error> {
        if self.env_policy {
            return Err(refused("CONTAINERS_POLICY_JSON is set"));
        }
        for p in &self.user_policies {
            if p.exists() {
                return Err(refused(&format!("{} exists", p.display())));
            }
        }
        for (link, shipped) in &self.links {
            if fs::canonicalize(link).ok() != fs::canonicalize(shipped).ok() {
                return Err(refused(&format!(
                    "{} is not {}",
                    link.display(),
                    shipped.display()
                )));
            }
        }
        let json = fs::read(&self.policy).map_err(|e| io(&self.policy, e))?;
        signer(&json).map(drop)
    }
}

fn refused(why: &str) -> Error {
    Error::Config(format!(
        "refusing: the signature policy is not the image's: {why}"
    ))
}

/// The one signer the policy requires for [`HOST`]: a `sigstoreSigned` entry with an address that
/// is not the placeholder of an image built before the real one was committed.
fn signer(policy: &[u8]) -> Result<String, Error> {
    let json: Value = serde_json::from_slice(policy).map_err(|e| refused(&e.to_string()))?;
    let entries = json["transports"]["docker"][HOST]
        .as_array()
        .ok_or_else(|| refused("no entry for updates.nyraos.com"))?;
    let mut found = None;
    for entry in entries {
        let email = entry["fulcio"]["subjectEmail"].as_str();
        if entry["type"] != "sigstoreSigned" || email.is_none() || found.is_some() {
            return Err(refused("not exactly one sigstoreSigned signer"));
        }
        found = email;
    }
    match found {
        Some(e) if !e.is_empty() && !e.ends_with(PLACEHOLDER_DOMAIN) => Ok(e.to_string()),
        _ => Err(refused("no real signer: reinstall from a release")),
    }
}

/// The version must be newer than the one that runs (compared number by number) and not below the
/// image's floor.
fn check_newer(status: &Status, version: &str, floor: &str) -> Result<(), Error> {
    let booted = status.booted.as_ref().ok_or(Error::NoBootedImage)?;
    let Some(running) = booted.version.as_deref() else {
        return Err(Error::Config("the running version is unknown".into()));
    };
    match compare_versions(version, running) {
        Ok(Ordering::Greater) => {}
        Ok(_) => {
            return Err(Error::Config(format!(
                "refusing {version}: not newer than the running {running}"
            )))
        }
        Err(_) => return Err(Error::Config("the running version is not a release".into())),
    }
    if compare_versions(version, floor)? == Ordering::Less {
        return Err(Error::BelowFloor {
            version: version.into(),
            floor: floor.into(),
        });
    }
    Ok(())
}

/// Rule 2, as a check does it: fetch the channel sheet this machine follows, verify it, and keep
/// its sequence and retractions before anything acts on it. A sheet that cannot be fetched or
/// verified is a refusal: the retractions would be unknown. (`verify` already refuses a sheet that
/// serves a retracted version.)
fn check_sheet(
    sys: &mut impl System,
    state: &mut State,
    cfg: &Config,
    now: u64,
) -> Result<Sheet, Error> {
    let channel = state.channel.clone().unwrap_or_else(|| cfg.channel.clone());
    let cfg = Config {
        channel,
        ..cfg.clone()
    };
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
    Ok(sheet)
}

/// The image of the sheet that is `version`: only its `current` or its `previous` version, and
/// nothing while the rollout is halted.
fn sheet_image(sheet: &Sheet, version: &str) -> Result<Image, Error> {
    if sheet.halted {
        return Err(Error::Config(format!(
            "refusing {version}: the channel is halted"
        )));
    }
    let offered: Vec<&Image> = [Some(&sheet.current), sheet.previous.as_ref()]
        .into_iter()
        .flatten()
        .collect();
    match offered.iter().find(|i| i.version == version) {
        Some(image) => Ok((*image).clone()),
        None => Err(Error::Config(format!(
            "refusing {version}: the channel sheet offers only {}",
            offered
                .iter()
                .map(|i| i.version.as_str())
                .collect::<Vec<_>>()
                .join(" and ")
        ))),
    }
}

/// Stages `version` of the image's repository. `cfg`: the image's configuration with the sheet
/// keys (updates must be configured). The caller has checked the signature policy
/// ([`PolicyFiles::check`]) and holds the update lock.
pub fn install(
    sys: &mut impl System,
    store: &Store,
    cfg: &Config,
    now: u64,
    version: &str,
) -> Result<String, Error> {
    check_version(version)?;
    let status = sys.status()?;
    check_newer(&status, version, &cfg.version_floor)?;
    let mut state = store.load()?;
    settle_state(store, &mut state, &status, now)?;
    // The sheet's sequence and retractions are kept even when this refuses (rule 2).
    let sheet = check_sheet(sys, &mut state, cfg, now);
    store.save(&state)?;
    let target = sheet_image(&sheet?, version)?;
    // Rules 3-5 before the pull: a retracted or failed digest is never fetched.
    check_target(&target, &state, &cfg.version_floor)?;
    // As a check does: what waits for the reboot is not pulled again.
    if Status::digest(&status.staged) == Some(target.digest.as_str()) {
        return Ok(format!(
            "{ALREADY_STAGED}: {version} ({}) waits for the next boot, which stays yours to start",
            target.digest
        ));
    }
    stage_target(sys, store, cfg, &mut state, target.clone())?;
    Ok(format!(
        "{version} ({}) is ready for the next boot, which stays yours to start",
        target.digest
    ))
}
