// SPDX-License-Identifier: GPL-3.0-or-later
//! `nyra-updated` commands, all run by systemd (`docs/UPDATES.md`):
//!
//! - `check` (timer): one update check, see the library documentation for the rules;
//! - `health-failed` (`OnFailure=` of the health checks): a full reboot while on trial; off trial,
//!   a version fallen back from is forgiven once (rule 12) and the console says how to reset the
//!   settings;
//! - `health` (`nyra-health-bootc.service`): bootc reports the booted image, so this version can
//!   still update itself;
//! - `check-config` (image build): the configuration parses and holds no test key;
//! - `set-channel NAME` (root, by hand until Settings offers it): this machine follows channel
//!   NAME from the next check on, whatever the image says (rule 14);
//! - `install VERSION` (`nyra-updated-install@VERSION.service`, started by an administrator through
//!   polkit): stages that release, never reboots, see the `install` module.

use nyra_updated::install::{check_version, install, PolicyFiles};
use nyra_updated::system::{run as run_limited, Real, SHORT};
use nyra_updated::{
    check, on_health_failure, one_line, set_channel, Config, Error, HealthAction, Lock, Store,
    System, NOT_CONFIGURED,
};
use std::path::Path;
use std::process::{Command, ExitCode};
use std::time::{SystemTime, UNIX_EPOCH};

const CONFIG: &str = "/usr/lib/nyra/updates/updated.conf";
const KEYS: &str = "/usr/lib/nyra/updates/channel-sheet.pem";
const STATE_DIR: &str = "/var/lib/nyra-updated";
const LOCK: &str = "/run/nyra-updated.lock";
/// Writes what the user sees when the system stays up after a failed health check (docs/UPDATES.md).
const NOTICE: &str = "/usr/lib/nyra/health/notice";

fn config() -> Result<Option<Config>, Error> {
    Config::load(Path::new(CONFIG), Path::new(KEYS))
}

/// One `install`: the argument first, then the configuration, the signature policy and the lock.
/// Updates must be configured, as for a check: without a sheet key nothing is installed.
fn install_once(version: &str, now: u64) -> Result<String, Error> {
    check_version(version)?;
    let cfg = config()?.ok_or_else(|| Error::Config(NOT_CONFIGURED.into()))?;
    PolicyFiles::system().check()?;
    let _lock = Lock::acquire(Path::new(LOCK))?;
    let store = Store {
        dir: STATE_DIR.into(),
    };
    let mut sys = Real {
        stage_limit: cfg.stage_timeout,
    };
    install(&mut sys, &store, &cfg, now, version)
}

/// One update check, with the lock held (`run`).
fn check_once(store: &Store, now: u64) -> Result<(u8, bool, String), Error> {
    // Not an error that leaves the unit failed: every machine would be degraded, which hides real
    // failures. Every sheet stays refused.
    let Some(cfg) = config()? else {
        return Ok((4, false, NOT_CONFIGURED.into()));
    };
    let mut sys = Real {
        stage_limit: cfg.stage_timeout,
    };
    match check(&mut sys, store, &cfg, now) {
        // A machine without a network is not failing: a warning, like the above.
        Err(e @ Error::Offline(_)) => Ok((4, false, e.to_string())),
        Ok(outcome) => {
            let (priority, message) = outcome.report();
            Ok((priority, true, message))
        }
        Err(e) => Err(e),
    }
}

/// The journal priority (sd-daemon prefix: 3 error, 4 warning, 6 info), whether the command did
/// its job (for last-check.json) and the result line.
fn run(command: &str, arg: Option<&str>, now: u64) -> Result<(u8, bool, String), Error> {
    match (command, arg) {
        ("check", None) => {
            // The report is written under the lock too, so two checks never write it at once. A
            // check that finds another one running (Busy) writes nothing.
            let _lock = Lock::acquire(Path::new(LOCK))?;
            let store = Store {
                dir: STATE_DIR.into(),
            };
            let result = check_once(&store, now);
            let (ok, message) = match &result {
                Ok((_, ok, m)) => (*ok, m.clone()),
                Err(e) => (false, e.to_string()),
            };
            match store.save_report(now, ok, &message) {
                // Updates stopped for two weeks, whatever the cause (no network included): an
                // error, so the unit fails and the machine is `degraded`.
                Ok(report) if report.days_without_success().is_some() => {
                    Err(Error::NoSuccessfulCheck(report.message))
                }
                Ok(_) => result,
                Err(e) => {
                    eprintln!("<4>nyra-updated: last-check.json not written: {e}");
                    result
                }
            }
        }
        ("health-failed", None) => {
            // Every call has its limit (SHORT); the unit's TimeoutStartSec= is above their sum.
            let store = Store {
                dir: STATE_DIR.into(),
            };
            let action = on_health_failure(&mut Real::default(), &store, Path::new(LOCK));
            // The system stays up unhealthy (an error too): the user is told how to repair it.
            if !matches!(action, Ok(HealthAction::Reboot)) {
                match run_limited(&mut Command::new(NOTICE), SHORT) {
                    Ok(out) if out.status.success() => {}
                    Ok(out) => eprintln!(
                        "<4>nyra-updated: {NOTICE} failed ({}): {}",
                        out.status,
                        one_line(String::from_utf8_lossy(&out.stderr).trim())
                    ),
                    Err(e) => eprintln!("<4>nyra-updated: {NOTICE}: {}", one_line(&e.to_string())),
                }
            }
            action.map(|a| (6, true, format!("{a:?}")))
        }
        ("health", None) => {
            let booted = Real::default()
                .status()?
                .booted
                .ok_or(Error::NoBootedImage)?;
            Ok((
                6,
                true,
                format!("bootc reports the booted image {}", booted.digest),
            ))
        }
        ("check-config", None) => match config()? {
            Some(cfg) => Ok((
                6,
                true,
                format!("{} trusted channel sheet key(s)", cfg.keys.len()),
            )),
            None => Ok((4, true, NOT_CONFIGURED.into())),
        },
        ("set-channel", Some(channel)) => {
            let _lock = Lock::acquire(Path::new(LOCK))?;
            let store = Store {
                dir: STATE_DIR.into(),
            };
            set_channel(&store, channel)?;
            Ok((6, true, format!("this machine follows channel {channel}")))
        }
        ("install", Some(version)) => install_once(version, now).map(|m| (6, true, m)),
        _ => Err(Error::Config(
            "usage: nyra-updated check|health-failed|health|check-config|set-channel NAME|install VERSION"
                .into(),
        )),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (command, arg) = match args.as_slice() {
        [c] => (c.as_str(), None),
        [c, a] => (c.as_str(), Some(a.as_str())),
        _ => ("", None), // the usage
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Every line is one_line: error messages carry what bootc and curl print.
    match run(command, arg, now) {
        Ok((priority, _, message)) => {
            println!("<{priority}>nyra-updated {command}: {}", one_line(&message));
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("<3>nyra-updated {command}: {}", one_line(&e.to_string()));
            ExitCode::FAILURE
        }
    }
}
