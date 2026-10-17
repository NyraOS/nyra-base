// SPDX-License-Identifier: GPL-3.0-or-later
//! ntpd-rs's ntp-ctl, as upstream's binary starts it.
fn main() -> std::io::Result<std::process::ExitCode> {
    ntpd::ctl_main()
}
