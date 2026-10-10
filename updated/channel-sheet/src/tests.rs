// SPDX-License-Identifier: GPL-3.0-or-later
use super::*;
use ed25519_dalek::{Signer, SigningKey};
use serde_json::{json, Value};

const NOW: u64 = 1_791_547_200; // 2026-10-09T12:00:00Z
const DAY: u64 = 24 * 60 * 60;
const OLD: &str = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
const NEW: &str = "sha256:2222222222222222222222222222222222222222222222222222222222222222";
const BAD: &str = "sha256:3333333333333333333333333333333333333333333333333333333333333333";
const CODE: &[u8] = b"0123456789abcdef0123456789abcdef";

fn key(seed: u8) -> SigningKey {
    SigningKey::from_bytes(&[seed; 32])
}

fn trusted() -> Vec<VerifyingKey> {
    vec![key(1).verifying_key()]
}

/// A valid sheet of nyra:stable: 2026.10.3 rolling out at 25% over 2026.10.2.
fn payload() -> Value {
    json!({
        "schema": 1, "repository": "nyra", "channel": "stable", "sequence": 100,
        "issued_at": NOW - DAY, "expires_at": NOW + 6 * DAY,
        "current": {"digest": NEW, "version": "2026.10.3"},
        "previous": {"digest": OLD, "version": "2026.10.2"},
        "percent": 25, "halted": false, "retracted": []
    })
}

fn envelope_with(
    payload_type: &str,
    payload: &[u8],
    signed: &[u8],
    signer: &SigningKey,
) -> Vec<u8> {
    let sig = signer.sign(signed);
    serde_json::to_vec(&json!({
        "payloadType": payload_type,
        "payload": BASE64.encode(payload),
        "signatures": [{"keyid": "", "sig": BASE64.encode(sig.to_bytes())}]
    }))
    .unwrap()
}

fn sign(p: &Value) -> Vec<u8> {
    let bytes = serde_json::to_vec(p).unwrap();
    envelope_with(PAYLOAD_TYPE, &bytes, &pae(PAYLOAD_TYPE, &bytes), &key(1))
}

fn check(p: &Value) -> Result<Sheet, Error> {
    verify(&sign(p), &trusted(), "nyra", "stable", NOW, Some(100))
}

fn with(mut p: Value, field: &str, v: Value) -> Value {
    p[field] = v;
    p
}

fn image(digest: &str, version: &str) -> Image {
    Image {
        digest: digest.into(),
        version: version.into(),
    }
}

// --- signature and envelope -------------------------------------------------------------------

#[test]
fn a_valid_sheet_verifies() {
    let sheet = check(&payload()).unwrap();
    assert_eq!(sheet.current, image(NEW, "2026.10.3"));
    assert_eq!(sheet.previous, Some(image(OLD, "2026.10.2")));
    assert_eq!(
        (sheet.sequence, sheet.percent, sheet.halted),
        (100, 25, false)
    );
}

#[test]
fn a_tampered_payload_is_refused() {
    // A fake version: the payload says 2099.1.1, the signature is over the real one.
    let real = serde_json::to_vec(&payload()).unwrap();
    let fake = serde_json::to_vec(&with(
        payload(),
        "current",
        json!({"digest": BAD, "version": "2099.1.1"}),
    ))
    .unwrap();
    let env = envelope_with(PAYLOAD_TYPE, &fake, &pae(PAYLOAD_TYPE, &real), &key(1));
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", NOW, None),
        Err(Error::BadSignature)
    );
}

#[test]
fn a_tampered_signature_is_refused() {
    let mut env: Value = serde_json::from_slice(&sign(&payload())).unwrap();
    let mut sig = BASE64
        .decode(env["signatures"][0]["sig"].as_str().unwrap())
        .unwrap();
    sig[10] ^= 1;
    env["signatures"][0]["sig"] = json!(BASE64.encode(sig));
    let env = serde_json::to_vec(&env).unwrap();
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", NOW, None),
        Err(Error::BadSignature)
    );
}

#[test]
fn a_sheet_signed_by_another_key_is_refused() {
    let bytes = serde_json::to_vec(&payload()).unwrap();
    let env = envelope_with(PAYLOAD_TYPE, &bytes, &pae(PAYLOAD_TYPE, &bytes), &key(2));
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", NOW, None),
        Err(Error::BadSignature)
    );
}

#[test]
fn any_trusted_key_verifies_during_a_rotation() {
    let bytes = serde_json::to_vec(&payload()).unwrap();
    let env = envelope_with(PAYLOAD_TYPE, &bytes, &pae(PAYLOAD_TYPE, &bytes), &key(2));
    let keys = vec![key(1).verifying_key(), key(2).verifying_key()];
    assert!(verify(&env, &keys, "nyra", "stable", NOW, None).is_ok());
}

#[test]
fn an_unsigned_sheet_is_refused() {
    let bytes = serde_json::to_vec(&payload()).unwrap();
    let env = serde_json::to_vec(
        &json!({"payloadType": PAYLOAD_TYPE, "payload": BASE64.encode(&bytes), "signatures": []}),
    )
    .unwrap();
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", NOW, None),
        Err(Error::BadSignature)
    );
}

#[test]
fn without_trusted_keys_every_sheet_is_refused() {
    assert_eq!(
        verify(&sign(&payload()), &[], "nyra", "stable", NOW, None),
        Err(Error::NoTrustedKeys)
    );
}

#[test]
fn a_signature_over_the_bare_payload_is_refused() {
    // Signed without the DSSE encoding: a signature made for another purpose cannot be reused.
    let bytes = serde_json::to_vec(&payload()).unwrap();
    let env = envelope_with(PAYLOAD_TYPE, &bytes, &bytes, &key(1));
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", NOW, None),
        Err(Error::BadSignature)
    );
}

#[test]
fn another_payload_type_is_refused() {
    let bytes = serde_json::to_vec(&payload()).unwrap();
    let other = "application/vnd.in-toto+json";
    let env = envelope_with(other, &bytes, &pae(other, &bytes), &key(1));
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", NOW, None),
        Err(Error::WrongPayloadType)
    );
}

#[test]
fn garbage_and_oversized_envelopes_are_refused() {
    assert!(matches!(
        verify(b"not json", &trusted(), "nyra", "stable", NOW, None),
        Err(Error::Malformed(_))
    ));
    let env = br#"{"payloadType":"application/vnd.nyra.channel-sheet.v1+json","payload":"%%%","signatures":[]}"#;
    assert!(matches!(
        verify(env, &trusted(), "nyra", "stable", NOW, None),
        Err(Error::Malformed(_))
    ));
    let big = vec![b' '; MAX_ENVELOPE_BYTES + 1];
    assert_eq!(
        verify(&big, &trusted(), "nyra", "stable", NOW, None),
        Err(Error::TooLarge)
    );
}

#[test]
fn a_signed_payload_that_is_not_a_sheet_is_refused() {
    let mut p = payload();
    p.as_object_mut().unwrap().remove("sequence");
    assert!(matches!(check(&p), Err(Error::Malformed(_))));
    assert!(matches!(
        check(&with(payload(), "percent", json!(300))),
        Err(Error::Malformed(_))
    ));
}

#[test]
fn unknown_fields_and_another_schema_are_refused() {
    let p = with(payload(), "note", json!("added later"));
    assert!(matches!(check(&p), Err(Error::Malformed(_))));
    let p = with(
        payload(),
        "current",
        json!({"digest": NEW, "version": "2026.10.3", "x": 1}),
    );
    assert!(matches!(check(&p), Err(Error::Malformed(_))));
    assert_eq!(
        check(&with(payload(), "schema", json!(2))),
        Err(Error::UnsupportedSchema(2))
    );
}

// --- channel binding --------------------------------------------------------------------------

#[test]
fn a_sheet_of_another_channel_is_refused() {
    // The dev channel's sheet served as stable (a channel moved in KV).
    let dev = sign(&with(payload(), "channel", json!("dev")));
    assert_eq!(
        verify(&dev, &trusted(), "nyra", "stable", NOW, None),
        Err(Error::WrongChannel {
            expected: "nyra:stable".into(),
            found: "nyra:dev".into()
        })
    );
    let other_repo = sign(&with(payload(), "repository", json!("nyra-base")));
    assert!(matches!(
        verify(&other_repo, &trusted(), "nyra", "stable", NOW, None),
        Err(Error::WrongChannel { .. })
    ));
}

// --- freshness and sequence -------------------------------------------------------------------

#[test]
fn an_expired_sheet_is_refused() {
    let p = payload();
    let expires = p["expires_at"].as_u64().unwrap();
    let env = sign(&p);
    assert!(verify(&env, &trusted(), "nyra", "stable", expires - 1, None).is_ok());
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", expires, None),
        Err(Error::Expired)
    );
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", expires + 30 * DAY, None),
        Err(Error::Expired)
    );
}

#[test]
fn a_sheet_valid_for_too_long_is_refused() {
    let p = with(
        payload(),
        "expires_at",
        json!(NOW - DAY + MAX_VALIDITY_SECS + 1),
    );
    assert_eq!(check(&p), Err(Error::Invalid("validity is too long")));
    let p = with(
        payload(),
        "expires_at",
        json!(NOW - DAY + MAX_VALIDITY_SECS),
    );
    assert!(check(&p).is_ok());
}

#[test]
fn a_sheet_that_expires_before_it_is_issued_is_refused() {
    let p = with(payload(), "issued_at", json!(NOW + 7 * DAY));
    assert_eq!(
        check(&p),
        Err(Error::Invalid("expires before it is issued"))
    );
}

#[test]
fn the_sequence_never_goes_backwards() {
    let env = sign(&payload()); // sequence 100
    assert!(verify(&env, &trusted(), "nyra", "stable", NOW, None).is_ok());
    assert!(verify(&env, &trusted(), "nyra", "stable", NOW, Some(99)).is_ok());
    assert!(
        verify(&env, &trusted(), "nyra", "stable", NOW, Some(100)).is_ok(),
        "the same sheet again"
    );
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", NOW, Some(101)),
        Err(Error::SequenceRollback {
            last: 101,
            found: 100
        })
    );
}

#[test]
fn a_sheet_issued_in_the_future_is_refused() {
    let at = |issued: u64| {
        let p = with(payload(), "issued_at", json!(issued));
        with(p, "expires_at", json!(issued + 7 * DAY))
    };
    assert!(check(&at(NOW + MAX_CLOCK_SKEW_SECS)).is_ok());
    assert_eq!(
        check(&at(NOW + MAX_CLOCK_SKEW_SECS + 1)),
        Err(Error::NotYetValid)
    );
    // Far future, to get around the 31-day validity cap: refused.
    assert_eq!(check(&at(NOW + 10 * 365 * DAY)), Err(Error::NotYetValid));
    let p = with(payload(), "issued_at", json!(u64::MAX - 100));
    let p = with(p, "expires_at", json!(u64::MAX));
    assert_eq!(check(&p), Err(Error::NotYetValid));
}

#[test]
fn the_sequence_cannot_go_beyond_the_expiry() {
    let expires = payload()["expires_at"].as_u64().unwrap();
    assert!(check(&with(payload(), "sequence", json!(expires))).is_ok());
    for seq in [expires + 1, u64::MAX] {
        let p = with(payload(), "sequence", json!(seq));
        assert_eq!(check(&p), Err(Error::Invalid("sequence above expires_at")));
    }
}

#[test]
fn a_bad_sheet_freezes_a_machine_for_32_days_at_most() {
    // The worst sheet a machine can accept: issued as late as the clock tolerance allows,
    // valid as long as allowed, with the highest sequence allowed.
    let issued = NOW + MAX_CLOCK_SKEW_SECS;
    let worst = json!({
        "schema": 1, "repository": "nyra", "channel": "stable",
        "sequence": issued + MAX_VALIDITY_SECS, "issued_at": issued, "expires_at": issued + MAX_VALIDITY_SECS,
        "current": {"digest": NEW, "version": "2026.10.3"}, "previous": null,
        "percent": 100, "halted": false, "retracted": []
    });
    let last = check(&worst).unwrap().sequence;
    // A legitimate sheet issued once that one has expired (sequence = Unix time) is accepted.
    let later = issued + MAX_VALIDITY_SECS;
    let p = with(payload(), "sequence", json!(later));
    let p = with(
        with(p, "issued_at", json!(later)),
        "expires_at",
        json!(later + 7 * DAY),
    );
    assert!(verify(&sign(&p), &trusted(), "nyra", "stable", later, Some(last)).is_ok());
}

#[test]
fn a_wrong_clock_refuses_sheets_without_locking_the_machine_out() {
    let env = sign(&payload()); // issued NOW - 1 day, expires NOW + 6 days
                                // Clock 3 days behind: not yet valid. Clock 30 days ahead: expired.
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", NOW - 3 * DAY, Some(90)),
        Err(Error::NotYetValid)
    );
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", NOW + 30 * DAY, Some(90)),
        Err(Error::Expired)
    );
    // Nothing was stored: with the clock fixed, the same sheet is accepted.
    assert!(verify(&env, &trusted(), "nyra", "stable", NOW, Some(90)).is_ok());
}

// --- consistency ------------------------------------------------------------------------------

#[test]
fn inconsistent_sheets_are_refused() {
    let cases = [
        (
            with(
                payload(),
                "current",
                json!({"digest": "sha256:abc", "version": "2026.10.3"}),
            ),
            "current digest",
        ),
        (
            with(
                payload(),
                "previous",
                json!({"digest": "md5:1", "version": "2026.10.2"}),
            ),
            "previous digest",
        ),
        (
            with(
                payload(),
                "previous",
                json!({"digest": NEW, "version": "2026.10.2"}),
            ),
            "previous is the current image",
        ),
        (
            with(
                payload(),
                "previous",
                json!({"digest": OLD, "version": "2026.10.3"}),
            ),
            "previous version is not older than current",
        ),
        (
            with(
                payload(),
                "previous",
                json!({"digest": OLD, "version": "2026.11.1"}),
            ),
            "previous version is not older than current",
        ),
        (with(payload(), "percent", json!(101)), "percent above 100"),
        (
            with(
                with(payload(), "previous", json!(null)),
                "percent",
                json!(25),
            ),
            "halted or partial rollout without previous",
        ),
        (
            with(
                with(
                    with(payload(), "previous", json!(null)),
                    "percent",
                    json!(100),
                ),
                "halted",
                json!(true),
            ),
            "halted or partial rollout without previous",
        ),
        (
            with(payload(), "retracted", json!(["nope"])),
            "retracted digest",
        ),
        (
            with(payload(), "retracted", json!([NEW])),
            "a retracted version is still served",
        ),
        (
            with(payload(), "retracted", json!([OLD])),
            "a retracted version is still served",
        ),
    ];
    for (p, why) in cases {
        assert_eq!(check(&p), Err(Error::Invalid(why)), "{why}");
    }
    let p = with(
        payload(),
        "current",
        json!({"digest": NEW, "version": "2026.10"}),
    );
    assert_eq!(check(&p), Err(Error::InvalidVersion("2026.10".into())));
}

#[test]
fn versions_are_compared_as_numbers() {
    use Ordering::*;
    assert_eq!(compare_versions("2026.10.10", "2026.10.9"), Ok(Greater));
    assert_eq!(compare_versions("2026.9.1", "2026.10.1"), Ok(Less));
    assert_eq!(compare_versions("2027.1.1", "2026.12.40"), Ok(Greater));
    assert_eq!(compare_versions("2026.10.3", "2026.10.3"), Ok(Equal));
    for bad in [
        "",
        "2026",
        "2026.10",
        "2026.10.3.1",
        "2026.010.3",
        "2026.10.x",
        "2026..3",
        "v2026.10.3",
        "2026.10.-3",
        "2026.10.9999999999",
    ] {
        assert_eq!(
            compare_versions(bad, "2026.10.3"),
            Err(Error::InvalidVersion(bad.into())),
            "{bad:?}"
        );
    }
}

// --- decision ---------------------------------------------------------------------------------

fn sheet(p: Value) -> Sheet {
    check(&p).unwrap()
}

#[test]
fn the_rollout_percent_decides_who_gets_the_new_version() {
    let s = sheet(payload()); // 25%
    let on_old = image(OLD, "2026.10.2");
    assert_eq!(
        s.decide(&on_old, 24),
        Ok(Decision::Update(image(NEW, "2026.10.3")))
    );
    assert_eq!(s.decide(&on_old, 25), Ok(Decision::UpToDate));
    assert_eq!(s.decide(&on_old, 99), Ok(Decision::UpToDate));

    let zero = sheet(with(payload(), "percent", json!(0)));
    assert_eq!(zero.decide(&on_old, 0), Ok(Decision::UpToDate));
    let full = sheet(with(payload(), "percent", json!(100)));
    assert_eq!(
        full.decide(&on_old, 99),
        Ok(Decision::Update(image(NEW, "2026.10.3")))
    );
}

#[test]
fn a_machine_outside_the_rollout_on_an_older_version_gets_previous() {
    let s = sheet(payload());
    let older = image(BAD, "2026.9.7");
    assert_eq!(
        s.decide(&older, 80),
        Ok(Decision::Update(image(OLD, "2026.10.2")))
    );
}

#[test]
fn a_halted_rollout_keeps_machines_that_took_it_and_sends_nobody_new() {
    let s = sheet(with(payload(), "halted", json!(true)));
    assert_eq!(
        s.decide(&image(NEW, "2026.10.3"), 80),
        Ok(Decision::UpToDate)
    );
    assert_eq!(
        s.decide(&image(OLD, "2026.10.2"), 0),
        Ok(Decision::UpToDate)
    );
    let older = image(BAD, "2026.9.7");
    assert_eq!(
        s.decide(&older, 0),
        Ok(Decision::Update(image(OLD, "2026.10.2")))
    );
}

#[test]
fn a_machine_on_the_new_version_is_never_moved_back_without_a_retract() {
    // Percent lowered after the machine took the new version.
    let s = sheet(with(payload(), "percent", json!(5)));
    assert_eq!(
        s.decide(&image(NEW, "2026.10.3"), 50),
        Ok(Decision::UpToDate)
    );
}

#[test]
fn a_downgrade_is_refused() {
    // The channel points to an older version than the installed one, without a retract
    // (a channel moved back in KV, or a user who came from beta).
    let s = sheet(json!({
        "schema": 1, "repository": "nyra", "channel": "stable", "sequence": 100,
        "issued_at": NOW, "expires_at": NOW + DAY,
        "current": {"digest": OLD, "version": "2026.10.2"}, "previous": null,
        "percent": 100, "halted": false, "retracted": []
    }));
    assert_eq!(
        s.decide(&image(NEW, "2026.10.3"), 0),
        Err(Error::Downgrade {
            installed: "2026.10.3".into(),
            offered: "2026.10.2".into()
        })
    );
    // Same version number, different build: refused too.
    assert!(matches!(
        s.decide(&image(BAD, "2026.10.2"), 0),
        Err(Error::Downgrade { .. })
    ));
}

#[test]
fn a_retracted_version_goes_back_to_the_previous_one() {
    // 2026.10.3 was retracted: the channel is back on 2026.10.2.
    let s = sheet(json!({
        "schema": 1, "repository": "nyra", "channel": "stable", "sequence": 101,
        "issued_at": NOW, "expires_at": NOW + DAY,
        "current": {"digest": OLD, "version": "2026.10.2"}, "previous": null,
        "percent": 100, "halted": false, "retracted": [NEW]
    }));
    for group in [0, 50, 99] {
        assert_eq!(
            s.decide(&image(NEW, "2026.10.3"), group),
            Ok(Decision::Retract(image(OLD, "2026.10.2")))
        );
    }
    // Only machines running the retracted version may go back: a newer build is not touched.
    let newer = image(BAD, "2026.10.4");
    assert!(matches!(s.decide(&newer, 0), Err(Error::Downgrade { .. })));
}

#[test]
fn a_retracted_version_during_a_new_rollout_still_goes_back() {
    // 2026.10.3 retracted, then 2026.10.4 rolling out at 10% over 2026.10.2.
    let s = sheet(json!({
        "schema": 1, "repository": "nyra", "channel": "stable", "sequence": 102,
        "issued_at": NOW, "expires_at": NOW + DAY,
        "current": {"digest": BAD, "version": "2026.10.4"},
        "previous": {"digest": OLD, "version": "2026.10.2"},
        "percent": 10, "halted": false, "retracted": [NEW]
    }));
    let bad = image(NEW, "2026.10.3");
    assert_eq!(
        s.decide(&bad, 5),
        Ok(Decision::Update(image(BAD, "2026.10.4")))
    );
    assert_eq!(
        s.decide(&bad, 50),
        Ok(Decision::Retract(image(OLD, "2026.10.2")))
    );
}

#[test]
fn going_back_two_versions_retracts_both() {
    // rollout.sh: revert (2026.10.3 retracted), start 2026.10.4, then set 2026.10.2, which
    // keeps the retract list and retracts 2026.10.4 too.
    let s = sheet(json!({
        "schema": 1, "repository": "nyra", "channel": "stable", "sequence": 103,
        "issued_at": NOW, "expires_at": NOW + DAY,
        "current": {"digest": OLD, "version": "2026.10.2"}, "previous": null,
        "percent": 100, "halted": false, "retracted": [NEW, BAD]
    }));
    let back = Decision::Retract(image(OLD, "2026.10.2"));
    assert_eq!(s.decide(&image(NEW, "2026.10.3"), 40), Ok(back.clone()));
    assert_eq!(s.decide(&image(BAD, "2026.10.4"), 40), Ok(back));
    // Without the retract list, both would be stuck: a plain downgrade.
    let mut stuck = s.clone();
    stuck.retracted.clear();
    assert!(matches!(
        stuck.decide(&image(NEW, "2026.10.3"), 40),
        Err(Error::Downgrade { .. })
    ));
}

#[test]
fn an_invalid_installed_version_is_an_error() {
    let s = sheet(payload());
    assert_eq!(
        s.decide(&image(BAD, "dev"), 0),
        Err(Error::InvalidVersion("dev".into()))
    );
}

// --- rollout group ----------------------------------------------------------------------------

#[test]
fn the_rollout_group_matches_hmac_sha256_computed_by_openssl() {
    // printf 'nyra-rollout-group-v1\nnyra:stable\nsha256:22…22' |
    //   openssl dgst -sha256 -mac HMAC -macopt "key:$CODE"     (CODE as above)
    // starts with ee3770fd; 0xee3770fd mod 100 = 13.
    assert_eq!(rollout_group(CODE, &sheet(payload())), Ok(13));
}

#[test]
fn the_rollout_group_is_stable_for_a_rollout_and_changes_between_releases() {
    let s = sheet(payload());
    let g = rollout_group(CODE, &s).unwrap();
    // The same rollout at another percent or halted: same group.
    assert_eq!(
        rollout_group(CODE, &sheet(with(payload(), "percent", json!(60)))),
        Ok(g)
    );
    assert_eq!(
        rollout_group(CODE, &sheet(with(payload(), "halted", json!(true)))),
        Ok(g)
    );
    // Another release, another channel: independent groups (for this code, all different).
    let next = with(
        payload(),
        "current",
        json!({"digest": BAD, "version": "2026.10.4"}),
    );
    assert_ne!(rollout_group(CODE, &sheet(next)), Ok(g));
    let beta = with(payload(), "channel", json!("beta"));
    let beta = verify(&sign(&beta), &trusted(), "nyra", "beta", NOW, None).unwrap();
    assert_ne!(rollout_group(CODE, &beta), Ok(g));
}

#[test]
fn rollout_groups_are_spread_evenly() {
    let s = sheet(payload());
    let mut counts = [0u32; 100];
    for i in 0..20_000u32 {
        let code = format!("install-code-{i:08}-padding");
        counts[rollout_group(code.as_bytes(), &s).unwrap() as usize] += 1;
    }
    // 200 expected per group; 5 standard deviations is about ±70.
    assert!(
        counts.iter().all(|&c| (130..=270).contains(&c)),
        "{counts:?}"
    );
}

#[test]
fn a_short_install_code_is_refused() {
    assert_eq!(
        rollout_group(b"too-short", &sheet(payload())),
        Err(Error::ShortInstallCode)
    );
}

// --- keys -------------------------------------------------------------------------------------

#[test]
fn public_keys_are_read_from_pem() {
    // `openssl pkey -pubout` output for the key with seed [1; 32].
    let pem = include_str!("../tests/data/seed1.pub.pem");
    assert_eq!(parse_public_keys(pem), Ok(vec![key(1).verifying_key()]));
    let two = format!("{pem}\n{pem}");
    assert_eq!(parse_public_keys(&two).unwrap().len(), 2);
    assert_eq!(parse_public_keys(""), Ok(vec![]));
}

#[test]
fn other_public_keys_are_refused() {
    // An ECDSA P-256 key.
    let p256 = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEl+MC9TbpH3okZV6+PbXogwlg8IC6\nFuXZdPJ7f+BL7KVfbszRNqPM0DspKLTv7riIM5ezD/9KkEJk94MHJUV9xA==\n-----END PUBLIC KEY-----\n";
    assert_eq!(parse_public_keys(p256), Err(Error::InvalidPublicKey));
    assert_eq!(
        parse_public_keys("-----BEGIN PUBLIC KEY-----\nAAAA\n"),
        Err(Error::InvalidPublicKey)
    );
}

// --- known answers and strict verification (kept across crate upgrades) -----------------------

fn unhex(h: &str) -> Vec<u8> {
    (0..h.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&h[i..i + 2], 16).unwrap())
        .collect()
}

/// Ed25519 (RFC 8032) is deterministic: this is openssl's signature of `payload()`'s PAE with the
/// seed-1 key, and the rollout groups are Python's `hmac` over the same message.
const SIG_SEED1: &str = "3fe6e4d07ee339d8428b498c7b52a702d4e811d574a319f8cd8ce0a29cc7372c\
                         2f6ea0ce3d47020b5f7b8550309f840973a200b9315f71c369fbfef1e79e5908";

#[test]
fn signatures_and_rollout_groups_match_independent_implementations() {
    let bytes = serde_json::to_vec(&payload()).unwrap();
    let sig = key(1).sign(&pae(PAYLOAD_TYPE, &bytes));
    let expected = unhex(&SIG_SEED1.replace(' ', ""));
    assert_eq!(sig.to_bytes().to_vec(), expected);
    assert!(check(&payload()).is_ok());
    assert_eq!(rollout_group(CODE, &sheet(payload())), Ok(13));
    let groups: Vec<u8> = (0..8u8)
        .map(|s| rollout_group(&[s; 16], &sheet(payload())).unwrap())
        .collect();
    assert_eq!(groups, [75, 66, 99, 52, 30, 96, 82, 16]);
}

#[test]
fn a_malleated_signature_is_refused() {
    // s + L (the group order) is the same signature mathematically; a verifier that accepts an s
    // that is not reduced (some other libraries, legacy compatibility modes) would take it. Ours
    // must refuse it.
    const L: [u8; 32] = [
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde,
        0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
    ];
    let bytes = serde_json::to_vec(&payload()).unwrap();
    let mut sig = unhex(&SIG_SEED1.replace(' ', ""));
    let mut carry = 0u16;
    for (b, l) in sig[32..].iter_mut().zip(L) {
        let sum = *b as u16 + l as u16 + carry;
        *b = sum as u8;
        carry = sum >> 8;
    }
    let env = serde_json::to_vec(&json!({
        "payloadType": PAYLOAD_TYPE,
        "payload": BASE64.encode(&bytes),
        "signatures": [{"keyid": "", "sig": BASE64.encode(&sig)}]
    }))
    .unwrap();
    assert_eq!(
        verify(&env, &trusted(), "nyra", "stable", NOW, None),
        Err(Error::BadSignature)
    );
}

#[test]
fn a_small_order_key_never_verifies() {
    // The identity point as public key with R = identity and s = 0 "verifies" any message for a
    // lax verifier. Such a key is refused when it is read, or every signature with it fails.
    let mut spki = vec![
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ];
    let mut identity = [0u8; 32];
    identity[0] = 1;
    spki.extend_from_slice(&identity);
    let pem = format!(
        "-----BEGIN PUBLIC KEY-----\n{}\n-----END PUBLIC KEY-----\n",
        BASE64.encode(&spki)
    );
    let mut sig = identity.to_vec();
    sig.extend_from_slice(&[0; 32]);
    let bytes = serde_json::to_vec(&payload()).unwrap();
    let env = serde_json::to_vec(&json!({
        "payloadType": PAYLOAD_TYPE,
        "payload": BASE64.encode(&bytes),
        "signatures": [{"keyid": "", "sig": BASE64.encode(&sig)}]
    }))
    .unwrap();
    match parse_public_keys(&pem) {
        Err(e) => assert_eq!(e, Error::InvalidPublicKey),
        Ok(keys) => assert_eq!(
            verify(&env, &keys, "nyra", "stable", NOW, None),
            Err(Error::BadSignature)
        ),
    }
}
