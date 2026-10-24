// SPDX-License-Identifier: GPL-3.0-or-later
//! `nyra-updated install VERSION`: an administrator stages one named release from a terminal
//! (`docs/UPDATES.md`, "Updating from a terminal as an administrator"). The command runs as root in
//! `nyra-updated-install@VERSION.service`, which polkit lets only members of `sudo` start, with
//! their own password. Nothing here trusts the argument: it is checked against a fixed shape first,
//! and the image reference is built from the image's repository and that version only.
//!
//! The guarantee is the signature policy, as for a manual `bootc switch` (`docs/UPDATES.md`,
//! "Moving a machine to updates.nyraos.com"): [`PolicyFiles::check`] refuses to start the pull
//! unless the policy is the shipped one. The version must be newer than the booted one (no
//! downgrade), and what bootc staged must be that version and not retracted or failed. When the
//! image has a sheet key, the channel sheet is fetched and verified first, as a check does, and a
//! version it retracts is refused; without a key, updates are not configured and the sheet is not
//! consulted. Staging and the copy of `/etc` are [`System::stage`], as in a check. Nothing
//! reboots.

use crate::{
    compare_versions, io, is_repository, payload_sha256, Accepted, Config, Deployment, Error,
    State, Status, Store, System, HOST, NOT_CONFIGURED,
};
use nyra_channel_sheet::verify;
use serde_json::Value;
use std::cmp::Ordering;
use std::fs;
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

/// The only reference `install` pulls: our registry, the image's repository (`nyra-base` or
/// `nyra-base-arm64`), the version as the tag.
pub fn image_ref(repository: &str, version: &str) -> String {
    format!("{HOST}/{repository}:{version}")
}

/// `repository` and `version_floor` of `updated.conf`. The sheet keys are not needed here: a
/// machine whose image has none yet can still move to a release by hand.
fn image_conf(conf: &str) -> Result<(String, String), Error> {
    let (mut repository, mut floor) = (None, None);
    for line in conf.lines().map(str::trim) {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let slot = match key.trim() {
            "repository" => &mut repository,
            "version_floor" => &mut floor,
            _ => continue,
        };
        if slot.replace(value.trim().to_string()).is_some() {
            return Err(Error::Config(format!("{} is set twice", key.trim())));
        }
    }
    match (repository, floor) {
        (Some(r), Some(f)) if is_repository(&r) && compare_versions(&f, &f).is_ok() => Ok((r, f)),
        _ => Err(Error::Config(
            "missing or invalid repository or version_floor".into(),
        )),
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

/// What bootc staged must be the version asked for (the tag decides what it pulled), and not a
/// version this machine knows to be bad (rules 3-5). Otherwise it never boots (rule 7).
fn staged_refusal(staged: &Deployment, state: &State, version: &str) -> Option<Error> {
    if state.retracted.contains(&staged.digest) {
        Some(Error::Retracted(staged.digest.clone()))
    } else if state.failed.contains(&staged.digest) {
        Some(Error::Failed(staged.digest.clone()))
    } else if staged.version.as_deref() != Some(version) {
        Some(Error::Config(format!(
            "staged {}, which is version {:?}, not {version}",
            staged.digest, staged.version
        )))
    } else {
        None
    }
}

/// Rule 2, as a check does it: fetch the channel sheet this machine follows, verify it, and keep
/// its sequence and retractions before anything acts on it. A sheet that cannot be fetched or
/// verified is a refusal: the retractions would be unknown. The sheet names retractions by digest,
/// which the tag only reveals once pulled: a retracted one is discarded when staged
/// ([`staged_refusal`]). (`verify` already refuses a sheet that serves a retracted version.)
fn check_sheet(
    sys: &mut impl System,
    state: &mut State,
    cfg: &Config,
    now: u64,
) -> Result<(), Error> {
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
    Ok(())
}

/// Stages `version` of the image's repository. `conf` is `updated.conf`. `cfg`: the same file with
/// the sheet keys, or `None` while the image has no key yet (updates are not configured): the
/// sheet is not consulted then, and the signature policy is the only guarantee. The caller has
/// checked the signature policy ([`PolicyFiles::check`]) and holds the update lock.
pub fn install(
    sys: &mut impl System,
    store: &Store,
    conf: &str,
    cfg: Option<&Config>,
    now: u64,
    version: &str,
) -> Result<String, Error> {
    check_version(version)?;
    let (repository, floor) = image_conf(conf)?;
    check_newer(&sys.status()?, version, &floor)?;
    let mut state = store.load()?;
    match cfg {
        Some(cfg) => {
            // The retractions are kept even when this refuses (rule 2).
            let checked = check_sheet(sys, &mut state, cfg, now);
            store.save(&state)?;
            checked?;
        }
        None => eprintln!("<4>nyra-updated: {NOT_CONFIGURED}; the channel sheet is not consulted"),
    }
    sys.stage(&image_ref(&repository, version))?;
    let staged = sys
        .status()?
        .staged
        .ok_or_else(|| Error::Config("bootc staged nothing".into()))?;
    if let Some(e) = staged_refusal(&staged, &state, version) {
        sys.discard_staged(&staged.digest)?;
        return Err(e);
    }
    // A later check learns from this whether the version booted or the machine fell back (rule 5).
    state.pending = Some(staged.digest.clone());
    store.save(&state)?;
    Ok(format!(
        "{version} ({}) is ready for the next boot, which stays yours to start",
        staged.digest
    ))
}
