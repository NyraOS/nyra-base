// SPDX-License-Identifier: GPL-3.0-or-later
//! `nyra-updated available`: which release the signed channel sheet offers, for `nyra update`
//! (`docs/UPDATES.md`, "Updating from a terminal as an administrator"). It runs as the user who
//! asked, not as root, and changes nothing: no lock, nothing written under `/var/lib`.
//!
//! It fetches and verifies the sheet exactly as a check does ([`verify`]: the mandatory key, the
//! signature, the repository and channel, the validity time), and offers the sheet's `current`
//! version only while the sheet is not halted and only when it is newer than the installed one.
//! What a user can not read is not used here: the state of the daemon (the sequence of the last
//! sheet, retracted and failed versions, a channel chosen by root) and `bootc`. So the answer is
//! an offer, not a decision: `install` runs the same checks again with that state, as root, and
//! refuses what this does not know about. The installed version is the image's `os-release`.

use crate::install::is_version;
use crate::{compare_versions, verify, Config, Error};
use std::cmp::Ordering;

/// `IMAGE_VERSION` of an `os-release` file (the release version of the image), if it is one.
pub fn installed_version(os_release: &str) -> Option<String> {
    let line = os_release
        .lines()
        .find_map(|l| l.strip_prefix("IMAGE_VERSION="))?;
    let version = line.trim().trim_matches('"');
    is_version(version).then(|| version.to_string())
}

/// What an image without a sheet key (updates not configured) says: nothing can be offered.
pub const NOT_SET_UP: &str = "Updates are not set up on this system.";

const UNVERIFIED: &str = "The update information could not be verified.";

/// The newest version the channel offers when it is newer than `installed`, else `None`. The
/// errors are the sentences the user reads.
pub fn available(
    fetch_sheet: impl FnOnce(&str) -> Result<Vec<u8>, Error>,
    cfg: &Config,
    installed: &str,
    now: u64,
) -> Result<Option<String>, Error> {
    let envelope = fetch_sheet(&cfg.sheet_url()).map_err(|_| {
        Error::Config("Could not reach the update server. Check the network and try again.".into())
    })?;
    let sheet = verify(
        &envelope,
        &cfg.keys,
        &cfg.repository,
        &cfg.channel,
        now,
        None,
    )
    .map_err(|e| match e {
        nyra_channel_sheet::Error::Expired | nyra_channel_sheet::Error::NotYetValid => {
            Error::Config("The update information does not fit the date. Check the clock.".into())
        }
        _ => Error::Config(UNVERIFIED.into()),
    })?;
    if sheet.halted {
        return Err(Error::Config("Updates are paused. Try again later.".into()));
    }
    // A signed version that install would not take (1.2.3) is not offered.
    if !is_version(&sheet.current.version) {
        return Err(Error::Config(UNVERIFIED.into()));
    }
    if compare_versions(&sheet.current.version, installed)? == Ordering::Greater {
        return Ok(Some(sheet.current.version));
    }
    Ok(None)
}
