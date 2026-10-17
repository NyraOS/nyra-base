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
//!   NAME from the next check on, whatever the image says (rule 14).

use nyra_updated::system::{run as run_limited, Real, SHORT};
use nyra_updated::{
    check, on_health_failure, set_channel, Config, Error, HealthAction, Lock, Outcome, Store,
    System,
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

/// Updates are not configured: the image ships no channel sheet key yet (docs/UPDATES.md).
const NOT_CONFIGURED: &str =
    "updates are not configured: no channel sheet key in /usr/lib/nyra/updates/channel-sheet.pem";

fn config() -> Result<Option<Config>, Error> {
    Config::load(Path::new(CONFIG), Path::new(KEYS))
}

/// The journal priority (sd-daemon prefix: 3 error, 4 warning, 6 info), whether the command did
/// its job (for last-check.json) and the result line.
fn run(command: &str, arg: Option<&str>, now: u64) -> Result<(u8, bool, String), Error> {
    match (command, arg) {
        ("check", None) => {
            let _lock = Lock::acquire(Path::new(LOCK))?;
            let store = Store {
                dir: STATE_DIR.into(),
            };
            // Not an error that leaves the unit failed: every machine would be degraded, which
            // hides real failures. Every sheet stays refused.
            let Some(cfg) = config()? else {
                return Ok((4, false, NOT_CONFIGURED.into()));
            };
            let mut sys = Real {
                stage_limit: cfg.stage_timeout,
            };
            let outcome = check(&mut sys, &store, &cfg, now)?;
            // An owner's own image gets no updates from us: say so, every time.
            let priority = if matches!(outcome, Outcome::ForeignImage(_)) {
                4
            } else {
                6
            };
            Ok((priority, true, format!("{outcome:?}")))
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
                        String::from_utf8_lossy(&out.stderr).trim()
                    ),
                    Err(e) => eprintln!("<4>nyra-updated: {NOTICE}: {e}"),
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
        _ => Err(Error::Config(
            "usage: nyra-updated check|health-failed|health|check-config|set-channel NAME".into(),
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
    let result = run(command, arg, now);
    if command == "check" {
        let (ok, message) = match &result {
            Ok((_, ok, m)) => (*ok, m.clone()),
            Err(e) => (false, e.to_string()),
        };
        let store = Store {
            dir: STATE_DIR.into(),
        };
        if let Err(e) = store.save_report(now, ok, &message) {
            eprintln!("<4>nyra-updated: last-check.json not written: {e}");
        }
    }
    match result {
        Ok((priority, _, message)) => {
            println!("<{priority}>nyra-updated {command}: {message}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("<3>nyra-updated {command}: {e}");
            ExitCode::FAILURE
        }
    }
}
