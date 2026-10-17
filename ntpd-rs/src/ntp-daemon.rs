// SPDX-License-Identifier: GPL-3.0-or-later
//! ntpd-rs's daemon, as upstream's binary starts it.
fn main() {
    let result = ntpd::daemon_main();
    std::process::exit(if result.is_ok() { 0 } else { 1 });
}
