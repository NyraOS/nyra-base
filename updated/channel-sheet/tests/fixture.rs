// SPDX-License-Identifier: GPL-3.0-or-later
//! A sheet made by the update server's operator tools, not by this crate: the channel file edited
//! by the rollout tool, the sheet built from it with jq and signed with openssl (test key with
//! seed [1; 32]), then fetched from a local instance of the server that serves it.
//! It checks that both sides agree on the envelope, the DSSE encoding and the payload.
//!
//! State: 2026.10.2 was retracted; 2026.10.3 is rolling out at 25% over 2026.10.1.

use nyra_channel_sheet::{parse_public_keys, verify, Decision, Error, Image};

const SHEET: &[u8] = include_bytes!("data/stable.sheet.json");
const KEY: &str = include_str!("data/seed1.pub.pem");
const ISSUED: u64 = 1_791_501_020;
const EXPIRES: u64 = 1_792_105_820;

fn digest(c: char) -> String {
    format!("sha256:{}", c.to_string().repeat(64))
}

fn image(c: char, version: &str) -> Image {
    Image {
        digest: digest(c),
        version: version.into(),
    }
}

#[test]
fn the_operator_tools_produce_sheets_the_client_accepts() {
    let keys = parse_public_keys(KEY).unwrap();
    let sheet = verify(
        SHEET,
        &keys,
        "nyra",
        "stable",
        ISSUED + 1,
        Some(ISSUED - 100),
    )
    .unwrap();
    assert_eq!(sheet.sequence, ISSUED);
    assert_eq!(sheet.expires_at, EXPIRES);
    assert_eq!(sheet.current, image('c', "2026.10.3"));
    assert_eq!(sheet.previous, Some(image('a', "2026.10.1")));
    assert_eq!((sheet.percent, sheet.halted), (25, false));
    assert_eq!(sheet.retracted, vec![digest('b')]);

    assert_eq!(
        sheet.decide(&image('a', "2026.10.1"), 24),
        Ok(Decision::Update(image('c', "2026.10.3")))
    );
    assert_eq!(
        sheet.decide(&image('a', "2026.10.1"), 25),
        Ok(Decision::UpToDate)
    );
    assert_eq!(
        sheet.decide(&image('b', "2026.10.2"), 60),
        Ok(Decision::Retract(image('a', "2026.10.1")))
    );
    assert_eq!(
        sheet.decide(&image('b', "2026.10.2"), 3),
        Ok(Decision::Update(image('c', "2026.10.3")))
    );

    assert_eq!(
        verify(SHEET, &keys, "nyra", "stable", EXPIRES, None),
        Err(Error::Expired)
    );
    assert!(matches!(
        verify(SHEET, &keys, "nyra", "beta", ISSUED + 1, None),
        Err(Error::WrongChannel { .. })
    ));
}
