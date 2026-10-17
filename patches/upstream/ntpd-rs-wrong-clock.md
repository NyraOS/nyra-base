# ntpd-rs: correct a clock that is far off through NTS

Status: applied in nyra-base's ntpd-rs build (`Containerfile`, stage `ntpd`), not sent upstream (we
keep our changes as our own patches; this one is public domain, see README.md). The change itself is
[`ntpd-rs-wrong-clock.patch`](ntpd-rs-wrong-clock.patch).

Upstream: pendulum-project/ntpd-rs, made against v1.9.0 (`46ec9bb4d5b6cb24f814f5543d85b9138afb4cba`).
It changes only the `ntp-proto` crate. The image build applies it to that crate as it comes from
crates.io, checked against `ntpd-rs/Cargo.lock` (`git apply -p2` in the crate's directory); the
`ntpd-rs` workflow applies it to the upstream source and runs `ntp-proto`'s tests.

## What

ntpd-rs checks the certificate of an NTS key exchange server (NTS-KE, RFC 8915) like any TLS client:
the chain to a trusted CA, the server name and the validity dates, the dates against the system
clock. A machine whose clock is outside the certificate's validity therefore never gets the time:
every key exchange fails (`InvalidCertificate(ExpiredContext …)` with the clock in 2035), and NTS is
the only way it gets the time. That happens with an empty RTC battery (the clock starts before the
certificate was issued) or a firmware clock years ahead. chrony has `nocerttimecheck` for this;
ntpd-rs has no such setting.

## The change

Until the first clock update since boot (`ntp-proto/src/bootstrap.rs`):

1. **The certificate is checked at the time the server gives.** A key exchange uses a second TLS
   configuration whose verifier still checks the handshake signature (the server holds the key of
   the certificate it presents) but leaves the certificate itself for later. The key exchange keeps
   the chain the server presented and its name; every time that source then gives (local clock plus
   the measured offset) counts only if the same verifier accepts the chain for that name *at that
   time*. A time at which the certificate was expired or not yet valid, a chain to no trusted CA,
   or a certificate for another name: the measurement is dropped.
2. **A floor.** No time counts below the image's build time (the modification time of
   `/usr/lib/clock-epoch`, systemd's convention) or the last clock update, whichever is later. Every
   clock update writes `/var/lib/ntpd-rs/last-clock-update`: its modification time is the time of
   the update, its content the boot ID. After the first update the floor is dropped: right after an
   update, a source as good as the others can be a few milliseconds behind it.
3. **Several servers.** This needs no code: ntpd-rs moves the clock only when at least
   `minimum-agreeing-sources` sources (default 3) agree and they are more than half of the usable
   ones. nyra-base configures four NTS servers of four operators. A unit test pins that behaviour.

After the first clock update, key exchanges check the certificate at the handshake again, as
upstream. "Since boot": a daemon restarted in the same boot finds this boot's ID in
`last-clock-update` and starts in the strict mode. Sources whose key exchange happened before the
first update keep the check at the times they give, which are then the local time.

Tests (in the patch): a certificate expired at the time the server gives is refused, and one not yet
valid; a certificate for another name is refused at any time; after the first clock update a key
exchange with a wrong name fails at the handshake and records no later check, and a restart in the
same boot stays strict; a time below the floor is refused; one source alone, two, or two of four
that agree are not enough, three that agree are.

## Limits

- Until the first update, an attacker on the path who holds the private key of an *expired*
  certificate for the server's name (from a trusted CA) can complete the key exchange and offer a
  time at which that certificate was valid, if it is not below the floor; with three agreeing
  sources needed, keys for three operators are needed at the same time. `nocerttimecheck` in chrony
  has the same weakness without the date check at the received time.
- Before the first update, ntpd-rs completes the key exchange with a server whose certificate it has
  not checked yet, and sends that server NTS requests (nothing secret in them); none of its times is
  used until the certificate is valid at them.
- The floor trusts the build time and the saved time. A clock update that three operators agreed
  on but that was wrong would raise the floor too.
- The paths (`/usr/lib/clock-epoch`, `/var/lib/ntpd-rs/last-clock-update`) are constants.

## Effect

A clock in 2035, or one before the image's build time, is corrected at boot by NTS alone. A time
from a server whose certificate does not fit that time, or below the floor, is ignored with a
warning in the log ("Ignoring the time of the source: …").
