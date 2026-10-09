// SPDX-License-Identifier: GPL-3.0-or-later
//! `nyra-updated` commands, all run by systemd (`docs/UPDATES.md`):
//!
//! - `check` (timer): one update check, see the library documentation for the rules;
//! - `health-failed` (`OnFailure=` of the health checks): a full reboot while on trial;
//! - `check-config` (image build): the configuration parses and holds no test key.

use nyra_updated::system::Real;
use nyra_updated::{check, on_health_failure, Config, Error, Lock, Outcome, Store, System};
use std::path::Path;
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

const CONFIG: &str = "/usr/lib/nyra/updates/updated.conf";
const KEYS: &str = "/usr/lib/nyra/updates/channel-sheet.pem";
const STATE_DIR: &str = "/var/lib/nyra-updated";
const LOCK: &str = "/run/nyra-updated.lock";

fn read(path: &str) -> Result<String, Error> {
    std::fs::read_to_string(path).map_err(|e| Error::Io(format!("{path}: {e}")))
}

fn config() -> Result<Config, Error> {
    Config::parse(&read(CONFIG)?, &read(KEYS)?)
}

/// The result line and its journal priority (sd-daemon prefix: 3 error, 4 warning, 6 info).
fn run(command: &str, now: u64) -> Result<(u8, String), Error> {
    match command {
        "check" => {
            let _lock = Lock::acquire(Path::new(LOCK))?;
            let store = Store {
                dir: STATE_DIR.into(),
            };
            let outcome = check(&mut Real, &store, &config()?, now)?;
            // An owner's own image gets no updates from us: say so, every time.
            let priority = if matches!(outcome, Outcome::ForeignImage(_)) {
                4
            } else {
                6
            };
            Ok((priority, format!("{outcome:?}")))
        }
        "health-failed" => {
            // The boot state it decided on, for the journal.
            let info = Real.boot_info()?;
            on_health_failure(&mut Real).map(|a| (6, format!("{a:?} ({info:?})")))
        }
        "check-config" => match config() {
            Ok(cfg) => Ok((
                6,
                format!("{} trusted channel sheet key(s)", cfg.keys.len()),
            )),
            // Fail closed until the real key is committed, like the signer placeholder in the
            // signature policy (docs/UPDATES.md).
            Err(Error::Sheet(nyra_channel_sheet::Error::NoTrustedKeys)) => Ok((
                4,
                "no trusted channel sheet key yet: every sheet is refused".into(),
            )),
            Err(e) => Err(e),
        },
        _ => Err(Error::Config(
            "usage: nyra-updated check|health-failed|check-config".into(),
        )),
    }
}

fn main() -> ExitCode {
    let command = std::env::args().nth(1).unwrap_or_default();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let result = run(&command, now);
    if command == "check" {
        let (ok, message) = match &result {
            Ok((_, m)) => (true, m.clone()),
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
        Ok((priority, message)) => {
            println!("<{priority}>nyra-updated {command}: {message}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("<3>nyra-updated {command}: {e}");
            ExitCode::FAILURE
        }
    }
}
