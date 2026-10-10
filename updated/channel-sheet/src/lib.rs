// SPDX-License-Identifier: GPL-3.0-or-later
//! The signed channel sheet of Nyra OS updates (`docs/UPDATES.md`).
//!
//! For every channel (`nyra:stable`, `nyra:beta`, `nyra:dev`) the update server publishes one small
//! JSON document, the same for everybody: the channel's current and previous version, the rollout
//! percent, whether the rollout is halted, which versions were retracted, a sequence number and an
//! expiry. It is signed with Ed25519 inside a DSSE envelope:
//!
//! ```json
//! {"payloadType": "application/vnd.nyra.channel-sheet.v1+json",
//!  "payload": "<base64 of the sheet JSON>",
//!  "signatures": [{"keyid": "", "sig": "<base64 of the 64-byte Ed25519 signature>"}]}
//! ```
//!
//! The signature covers `DSSEv1 <len(type)> <type> <len(payload)> <payload>` (DSSE PAE), so the
//! exact payload bytes are signed and a signature made for anything else cannot be reused here.
//!
//! The sheet payload:
//!
//! ```json
//! {"schema": 1, "repository": "nyra", "channel": "stable", "sequence": 1791547200,
//!  "issued_at": 1791547200, "expires_at": 1792152000,
//!  "current":  {"digest": "sha256:<hex>", "version": "2026.10.3"},
//!  "previous": {"digest": "sha256:<hex>", "version": "2026.10.2"},
//!  "percent": 25, "halted": false, "retracted": ["sha256:<hex>"]}
//! ```
//!
//! A machine verifies the sheet ([`verify`]), computes its own rollout group from its install code
//! ([`rollout_group`]; the code never leaves the machine) and asks the sheet what to do
//! ([`Sheet::decide`]). Versions are ordered by the signed `version` fields, never by tag names.
//!
//! Unknown fields are refused, so any new field comes with a new `schema`: a security field can
//! never be ignored in silence by an old client. Old clients refuse such a sheet and keep the
//! version they run; an image that understands the new schema reaches them first through a sheet
//! of the old one.

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use ed25519_dalek::{Signature, VerifyingKey};
use hmac::{Hmac, KeyInit, Mac};
use serde::Deserialize;
use sha2::Sha256;
use std::cmp::Ordering;
use std::fmt;

/// DSSE payload type of a channel sheet.
pub const PAYLOAD_TYPE: &str = "application/vnd.nyra.channel-sheet.v1+json";
/// The only payload schema this code understands.
pub const SCHEMA: u32 = 1;
/// Bigger envelopes are refused before parsing (a real sheet is well under 2 KiB).
pub const MAX_ENVELOPE_BYTES: usize = 64 * 1024;
/// Longest accepted validity (`expires_at - issued_at`). The server issues 7 days and re-signs
/// daily; this bound keeps a sheet issued by mistake with a far expiry from disabling the
/// protection against a frozen channel.
pub const MAX_VALIDITY_SECS: u64 = 31 * 24 * 60 * 60;
/// How far in the future `issued_at` may be, for machine clocks that are behind. A day, because
/// a dual-boot machine whose hardware clock runs on local time (Windows) can be off by up to 14
/// hours until the network time arrives.
pub const MAX_CLOCK_SKEW_SECS: u64 = 24 * 60 * 60;
/// Shortest accepted install code. The code is at least 128 random bits.
pub const MIN_INSTALL_CODE_BYTES: usize = 16;

/// An image on a channel: its manifest digest and its release version.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Image {
    pub digest: String,
    pub version: String,
}

/// A channel sheet. Get it from [`verify`]; nothing else checks it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sheet {
    pub schema: u32,
    pub repository: String,
    pub channel: String,
    /// Grows with every new sheet of the channel; a machine never accepts a lower one. At most
    /// `expires_at` (the server uses the Unix time of issue, +1 when needed).
    pub sequence: u64,
    /// Unix seconds.
    pub issued_at: u64,
    /// Unix seconds. From this moment the sheet is refused.
    pub expires_at: u64,
    /// The channel's newest version.
    pub current: Image,
    /// The last good version: what machines outside the rollout get. `None`: no rollout.
    pub previous: Option<Image>,
    /// Groups `0..percent` get `current`.
    pub percent: u8,
    /// Nobody new gets `current`; machines that run it keep it.
    pub halted: bool,
    /// Digests of retracted versions: machines running one may go back to an older version.
    pub retracted: Vec<String>,
}

/// What a machine should do according to a verified sheet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Keep the installed version.
    UpToDate,
    /// Prepare this newer version.
    Update(Image),
    /// The installed version was retracted: prepare this one, even though it is older.
    Retract(Image),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    TooLarge,
    /// Not a DSSE envelope, bad base64, or a payload that is not a sheet.
    Malformed(String),
    WrongPayloadType,
    /// No trusted key is installed: every sheet is refused (fail closed).
    NoTrustedKeys,
    /// No signature verifies with a trusted key.
    BadSignature,
    UnsupportedSchema(u32),
    /// The sheet is for another repository or channel.
    WrongChannel {
        expected: String,
        found: String,
    },
    /// The sheet is signed but inconsistent.
    Invalid(&'static str),
    Expired,
    /// Issued in the future: the sheet, or this machine's clock, is wrong.
    NotYetValid,
    /// Older than a sheet this machine already accepted.
    SequenceRollback {
        last: u64,
        found: u64,
    },
    /// The sheet offers a version that is not newer than the installed one, and the installed
    /// version is not retracted.
    Downgrade {
        installed: String,
        offered: String,
    },
    InvalidVersion(String),
    ShortInstallCode,
    InvalidPublicKey,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::TooLarge => write!(f, "channel sheet is larger than {MAX_ENVELOPE_BYTES} bytes"),
            Error::Malformed(why) => write!(f, "malformed channel sheet: {why}"),
            Error::WrongPayloadType => write!(f, "not a channel sheet (payload type)"),
            Error::NoTrustedKeys => write!(f, "no trusted channel sheet key is installed"),
            Error::BadSignature => write!(f, "channel sheet signature does not verify"),
            Error::UnsupportedSchema(s) => write!(f, "unsupported channel sheet schema {s}"),
            Error::WrongChannel { expected, found } => {
                write!(f, "channel sheet is for {found}, expected {expected}")
            }
            Error::Invalid(why) => write!(f, "invalid channel sheet: {why}"),
            Error::Expired => write!(f, "channel sheet has expired"),
            Error::NotYetValid => {
                write!(f, "channel sheet is issued in the future (check the clock)")
            }
            Error::SequenceRollback { last, found } => {
                write!(
                    f,
                    "channel sheet sequence {found} is older than the accepted {last}"
                )
            }
            Error::Downgrade { installed, offered } => {
                write!(
                    f,
                    "refusing {offered}: not newer than the installed {installed}"
                )
            }
            Error::InvalidVersion(v) => write!(f, "invalid version {v:?}"),
            Error::ShortInstallCode => write!(
                f,
                "install code is shorter than {MIN_INSTALL_CODE_BYTES} bytes"
            ),
            Error::InvalidPublicKey => write!(f, "not an Ed25519 public key in PEM"),
        }
    }
}

impl std::error::Error for Error {}

#[derive(Deserialize)]
struct Envelope {
    #[serde(rename = "payloadType")]
    payload_type: String,
    payload: String,
    signatures: Vec<EnvelopeSignature>,
}

#[derive(Deserialize)]
struct EnvelopeSignature {
    sig: String,
}

/// DSSE pre-authentication encoding: what the signature covers.
pub fn pae(payload_type: &str, payload: &[u8]) -> Vec<u8> {
    let mut out = format!(
        "DSSEv1 {} {} {} ",
        payload_type.len(),
        payload_type,
        payload.len()
    )
    .into_bytes();
    out.extend_from_slice(payload);
    out
}

/// Verifies a channel sheet envelope and returns the sheet.
///
/// Checks, in this order: size, envelope, payload type, signature (any trusted key), schema,
/// repository and channel, internal consistency, expiry at `now` (Unix seconds), and that the
/// sequence is not lower than `last_sequence`, the sequence of the last sheet this machine
/// accepted for this channel (`None` before the first one). The caller stores the returned
/// sheet's `sequence` once it acts on it.
///
/// Time bounds: `issued_at` at most [`MAX_CLOCK_SKEW_SECS`] after `now`, `expires_at` after
/// `now` and at most [`MAX_VALIDITY_SECS`] after `issued_at`, and `sequence` at most
/// `expires_at`. So no accepted sheet can carry a sequence beyond `now` + 32 days: even a sheet
/// signed by mistake with a huge sequence cannot freeze a machine for longer than that, because
/// every later legitimate sheet (sequence = Unix time of issue) overtakes it. A machine whose
/// clock is wrong refuses sheets (`Expired` or `NotYetValid`) and stores nothing, so it is not
/// locked out: it accepts sheets again as soon as the clock is right.
pub fn verify(
    envelope: &[u8],
    keys: &[VerifyingKey],
    repository: &str,
    channel: &str,
    now: u64,
    last_sequence: Option<u64>,
) -> Result<Sheet, Error> {
    if envelope.len() > MAX_ENVELOPE_BYTES {
        return Err(Error::TooLarge);
    }
    let env: Envelope =
        serde_json::from_slice(envelope).map_err(|e| Error::Malformed(e.to_string()))?;
    if env.payload_type != PAYLOAD_TYPE {
        return Err(Error::WrongPayloadType);
    }
    let payload = BASE64
        .decode(&env.payload)
        .map_err(|_| Error::Malformed("payload is not base64".into()))?;
    if keys.is_empty() {
        return Err(Error::NoTrustedKeys);
    }
    let message = pae(&env.payload_type, &payload);
    let signed = env.signatures.iter().any(|s| {
        let Ok(bytes) = BASE64.decode(&s.sig) else {
            return false;
        };
        let Ok(sig) = Signature::from_slice(&bytes) else {
            return false;
        };
        keys.iter().any(|k| k.verify_strict(&message, &sig).is_ok())
    });
    if !signed {
        return Err(Error::BadSignature);
    }

    // Only signed bytes are parsed from here on.
    let sheet: Sheet =
        serde_json::from_slice(&payload).map_err(|e| Error::Malformed(e.to_string()))?;
    if sheet.schema != SCHEMA {
        return Err(Error::UnsupportedSchema(sheet.schema));
    }
    if sheet.repository != repository || sheet.channel != channel {
        return Err(Error::WrongChannel {
            expected: format!("{repository}:{channel}"),
            found: format!("{}:{}", sheet.repository, sheet.channel),
        });
    }
    sheet.check()?;
    if now >= sheet.expires_at {
        return Err(Error::Expired);
    }
    if sheet.issued_at > now.saturating_add(MAX_CLOCK_SKEW_SECS) {
        return Err(Error::NotYetValid);
    }
    if let Some(last) = last_sequence {
        if sheet.sequence < last {
            return Err(Error::SequenceRollback {
                last,
                found: sheet.sequence,
            });
        }
    }
    Ok(sheet)
}

impl Sheet {
    fn check(&self) -> Result<(), Error> {
        if !is_digest(&self.current.digest) {
            return Err(Error::Invalid("current digest"));
        }
        version_key(&self.current.version)?;
        if let Some(prev) = &self.previous {
            if !is_digest(&prev.digest) {
                return Err(Error::Invalid("previous digest"));
            }
            if prev.digest == self.current.digest {
                return Err(Error::Invalid("previous is the current image"));
            }
            if compare_versions(&prev.version, &self.current.version)? != Ordering::Less {
                return Err(Error::Invalid("previous version is not older than current"));
            }
        }
        if self.percent > 100 {
            return Err(Error::Invalid("percent above 100"));
        }
        if self.previous.is_none() && (self.halted || self.percent < 100) {
            return Err(Error::Invalid("halted or partial rollout without previous"));
        }
        for d in &self.retracted {
            if !is_digest(d) {
                return Err(Error::Invalid("retracted digest"));
            }
            if *d == self.current.digest || self.previous.as_ref().is_some_and(|p| p.digest == *d) {
                return Err(Error::Invalid("a retracted version is still served"));
            }
        }
        if self.expires_at <= self.issued_at {
            return Err(Error::Invalid("expires before it is issued"));
        }
        if self.expires_at - self.issued_at > MAX_VALIDITY_SECS {
            return Err(Error::Invalid("validity is too long"));
        }
        if self.sequence > self.expires_at {
            return Err(Error::Invalid("sequence above expires_at"));
        }
        Ok(())
    }

    /// The version a machine in `group` gets if it does not already run `current`
    /// (the same rule the update server uses).
    pub fn target(&self, group: u8) -> &Image {
        match &self.previous {
            Some(prev) if self.halted || group >= self.percent => prev,
            _ => &self.current,
        }
    }

    /// What a machine in rollout `group` that runs `installed` should do.
    ///
    /// A machine running `current` keeps it, even when the rollout is halted. Otherwise it gets
    /// [`Sheet::target`], but only if that is newer than what it runs, or if what it runs was
    /// retracted. Anything else is a downgrade and is refused.
    pub fn decide(&self, installed: &Image, group: u8) -> Result<Decision, Error> {
        if installed.digest == self.current.digest {
            return Ok(Decision::UpToDate);
        }
        let target = self.target(group);
        if target.digest == installed.digest {
            return Ok(Decision::UpToDate);
        }
        if compare_versions(&target.version, &installed.version)? == Ordering::Greater {
            return Ok(Decision::Update(target.clone()));
        }
        if self.retracted.contains(&installed.digest) {
            return Ok(Decision::Retract(target.clone()));
        }
        Err(Error::Downgrade {
            installed: installed.version.clone(),
            offered: target.version.clone(),
        })
    }
}

/// The machine's rollout group, 0-99, for this sheet's rollout.
///
/// HMAC-SHA256 keyed with the install code over the repository, the channel and the version being
/// rolled out; the first 32 bits mod 100 (bias ~2e-8). Stable for the whole rollout of a version,
/// so a machine never moves in and out of it; unpredictable for anyone without the code, which
/// never leaves the machine; independent from one release to the next, so the same machines are
/// not always the first to get a new version.
pub fn rollout_group(install_code: &[u8], sheet: &Sheet) -> Result<u8, Error> {
    if install_code.len() < MIN_INSTALL_CODE_BYTES {
        return Err(Error::ShortInstallCode);
    }
    let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(install_code)
        .expect("HMAC takes keys of any length");
    mac.update(
        format!(
            "nyra-rollout-group-v1\n{}:{}\n{}",
            sheet.repository, sheet.channel, sheet.current.digest
        )
        .as_bytes(),
    );
    let out = mac.finalize().into_bytes();
    Ok((u32::from_be_bytes([out[0], out[1], out[2], out[3]]) % 100) as u8)
}

/// The trusted keys from a PEM file (one or more `PUBLIC KEY` blocks, Ed25519 only). Two blocks
/// during a key rotation: the old key and the new one.
pub fn parse_public_keys(pem: &str) -> Result<Vec<VerifyingKey>, Error> {
    // DER of an Ed25519 SubjectPublicKeyInfo: this fixed prefix, then the 32-byte key.
    const SPKI_PREFIX: [u8; 12] = [
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ];
    let mut keys = Vec::new();
    let mut rest = pem;
    while let Some(start) = rest.find("-----BEGIN PUBLIC KEY-----") {
        let body = &rest[start + "-----BEGIN PUBLIC KEY-----".len()..];
        let end = body
            .find("-----END PUBLIC KEY-----")
            .ok_or(Error::InvalidPublicKey)?;
        let b64: String = body[..end].chars().filter(|c| !c.is_whitespace()).collect();
        let der = BASE64.decode(b64).map_err(|_| Error::InvalidPublicKey)?;
        if der.len() != 44 || der[..12] != SPKI_PREFIX {
            return Err(Error::InvalidPublicKey);
        }
        let raw: [u8; 32] = der[12..].try_into().expect("32 bytes");
        keys.push(VerifyingKey::from_bytes(&raw).map_err(|_| Error::InvalidPublicKey)?);
        rest = &body[end..];
    }
    Ok(keys)
}

fn is_digest(d: &str) -> bool {
    d.strip_prefix("sha256:").is_some_and(|hex| {
        hex.len() == 64
            && hex
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// A release version (`2026.10.3`: year, month, build): exactly three dot-separated numbers
/// without leading zeros, compared number by number (`2026.10.10` > `2026.10.9`).
fn version_key(v: &str) -> Result<Vec<u32>, Error> {
    let bad = || Error::InvalidVersion(v.to_string());
    let parts: Vec<&str> = v.split('.').collect();
    if parts.len() != 3 {
        return Err(bad());
    }
    parts
        .iter()
        .map(|p| {
            let ok = !p.is_empty()
                && p.len() <= 9
                && p.bytes().all(|b| b.is_ascii_digit())
                && (p.len() == 1 || !p.starts_with('0'));
            if ok {
                Ok(p.parse().expect("checked digits"))
            } else {
                Err(bad())
            }
        })
        .collect()
}

/// Orders two release versions.
pub fn compare_versions(a: &str, b: &str) -> Result<Ordering, Error> {
    Ok(version_key(a)?.cmp(&version_key(b)?))
}

#[cfg(test)]
mod tests;
