// SPDX-License-Identifier: GPL-3.0-or-later
//! `nyra-updated check` (timer) and `nyra-updated health-failed` (`OnFailure=` of the health
//! checks). See the library documentation for the rules.

use nyra_updated::system::Real;
use nyra_updated::{check, on_health_failure, Config, Error, Lock, Store};
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

fn run(command: &str) -> Result<String, Error> {
    match command {
        "check" => {
            let _lock = Lock::acquire(Path::new(LOCK))?;
            let cfg = Config::parse(&read(CONFIG)?, &read(KEYS)?)?;
            let store = Store {
                dir: STATE_DIR.into(),
            };
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            check(&mut Real, &store, &cfg, now).map(|o| format!("{o:?}"))
        }
        "health-failed" => on_health_failure(&mut Real).map(|a| format!("{a:?}")),
        _ => Err(Error::Config(
            "usage: nyra-updated check|health-failed".into(),
        )),
    }
}

fn main() -> ExitCode {
    let command = std::env::args().nth(1).unwrap_or_default();
    match run(&command) {
        Ok(result) => {
            println!("nyra-updated {command}: {result}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("nyra-updated {command}: {e}");
            ExitCode::FAILURE
        }
    }
}
