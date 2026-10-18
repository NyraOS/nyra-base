// SPDX-License-Identifier: GPL-3.0-or-later
//! ntpd-rs's daemon, as upstream's binary starts it, but an error that stops it is printed (upstream
//! exits with 1 and says nothing).
fn main() {
    if let Err(e) = ntpd::daemon_main() {
        eprintln!("ntp-daemon: {e}");
        std::process::exit(1);
    }
}
