# The rooms

Sign in first (top right). Each room shows "your authority": what Vault will
let you do there, from `sys/capabilities-self`. A lock marks an action Vault
will refuse; the button still works, so you see Vault's own refusal. For the
whole demo sign in as `olga` (`make identity-copy-password U=olga`); to show a
refusal, sign in as `vera` and press "Issue a leaf".

| Room | Read | Act |
| --- | --- | --- |
| Quantum PKI | everyone | issue: PKI operators (`piet`, `olga`) |
| Crypto agility | everyone (verify too) | sign, change algorithm, encrypt, rewrap, decrypt: key custodians (`kees`, `olga`) |
| FF1 | everyone | encode, decode, rewrap: data stewards (`dana`, `olga`) |
| Lifecycle | everyone | revoke: PKI operators |

What each room demonstrates, the exact Vault calls behind it (all proven by
`make probe`, see [capabilities.md](capabilities.md)), and what to say while
showing it. Start from `make demo-reset` for a clean run.

## Overview

The four cards read `/api/capabilities`: the licensed features from
`sys/license/status` and one read per room that proves its configuration
exists. A room that is not licensed says so and names the feature; it is never
faked.

## Quantum PKI

**Feature:** ML-DSA (FIPS 204) keys in the PKI secrets engine: roots,
intermediates, roles and leaves (`key_type=ml-dsa`, `parameter_set=ml-dsa-44|65|87`).

| Chain | Root | Intermediate | Leaf role `service` |
| --- | --- | --- | --- |
| classic | `pki-classic-root`, EC P-384 | `pki-classic-int`, EC P-256 | EC P-256, 1 h |
| post-quantum | `pki-pqc-root`, ML-DSA-87 | `pki-pqc-int`, ML-DSA-65 | ML-DSA-44, 1 h |

Calls: `POST <int>/issue/service`, `GET <root>/issuer/default`, `POST
<int>/ocsp`, `GET <int>/crl/pem`.

**Say:**

1. "Same Vault, same roles, same lifetimes. Only the algorithm differs." Issue
   a leaf on both sides.
2. The hero shows the cost, measured on the DER Vault just returned: the leaf
   about 6.7 times larger (5.1 KB vs 0.75 KB), the signature 46 times (3309 B
   vs about 71 B), the public key 15 times (1334 B vs 91 B).
3. "Both verify twice": Node 24 (`crypto.X509Certificate`, OpenSSL 3.5.9
   inside) and the `openssl verify` CLI. Older OpenSSL cannot parse these
   certificates at all.
4. Ask the OCSP responder on both. Classic: `good`, signature verified. ML-DSA:
   no answer. Vault 2.2.1 does not support OCSP for ML-DSA issuers (with the
   responder on it returns 500 `internalerror`), so Terraform turns it off and
   revocation goes through the CRL, which Vault signs with ML-DSA-65.
5. "Revoke this leaf" (PKI operators): Vault rebuilds the CRL at once. "Check
   the CRL" now finds the leaf on it, in a list signed with ML-DSA-65; on the
   classic chain OCSP answers `revoked` as well.
6. "This page itself is served with ECDSA": browsers do not accept ML-DSA
   certificates yet. Post-quantum PKI is for paths you control end to end.

### Moving the ML-DSA CA key (Vault Enterprise)

`make pki-move` (an operator; the console cannot: export needs `sudo`):

1. `POST pki-pqc-next/export key_type=ml-kem-1024`: the target makes a wrapping
   key pair and hands out only the public half.
2. `POST pki-pqc-int/keys/<key>/export public_key=…`: the source wraps its
   issuing key to it. The source issuer now carries a permanent warning,
   "private key exported on … with sha256:…".
3. `POST pki-pqc-next/keys/import wrapped_key=… export_key_hmac=…`, then
   `issuers/import/cert` with the intermediate's certificate. Vault maps the
   certificate to the moved key.
4. A role on `pki-pqc-next` issues a leaf with the moved key; it verifies under
   the same root.

**Say:** "A post-quantum key, moved under post-quantum wrapping. It never exists
in plaintext outside Vault, and the source remembers that it left."

`make demo-reset` empties `pki-pqc-next`. The export warnings on the source
issuer stay: Vault records them for good.

## Crypto agility

**Feature:** `POST transit/keys/:name/algorithm` rotates a key to a new version
with a different algorithm. The key name, and therefore every caller's
configuration, stays the same.

Calls: `transit/keys/<key>/algorithm`, `transit/sign|verify/orders-signing`,
`transit/encrypt|rewrap|decrypt/ledger-data`, `GET transit/keys/<key>`.

**Say:**

1. Point at the pinned path in the hero: the application is configured with
   `transit/sign/orders-signing` and nothing else.
2. Sign a message (v1, `ecdsa-p256`, 105 characters).
3. Rotate to `ml-dsa-65`, sign again (v2, about 4400 characters). Rotate to
   the hybrid (ML-DSA-65 plus ECDSA P-256), sign again.
4. "Verify every signature now": all valid under the newest version. Old
   versions keep verifying until you raise `min_decryption_version`.
5. Try `aes256-gcm96`: Vault answers `incompatible algorithm aes256-gcm96 for
   key type ecdsa-p256`. Old and new types must have the same key usages.
6. Ledger: encrypt, rotate `aes128-gcm96` to `aes256-gcm96` or
   `chacha20-poly1305`, rewrap all in one batch call (no plaintext in the
   answer), decrypt: equal.

**Note what Vault reports:** `type` stays the original; `latest_version_type`
is the new one. Per version, a signing key shows a name and public key (the page
derives the algorithm from them); an encryption key shows only a creation time.
The page labels which is which.

## FF1

**Feature:** every new FPE transformation in Transform is FF1 (NIST SP
800-38G); FF3-1 is deprecated. `POST transform/rewrap/:role` decodes under one
transformation and encodes under another inside Vault.

| Transformation | Template |
| --- | --- |
| `ccn-legacy`, `ccn-2026` | `builtin/creditcardnumber` |
| `iban-ff1` | `nl-iban`: `NL\d{2}[A-Z]{4}(\d{10})`, only the account number |
| `bsn-ff1` | `nl-bsn`: nine digits |

Calls: `transform/encode|decode|rewrap/payments` with `batch_input`.

**Say:**

1. Encode all: every value keeps its shape.
2. The checksum column fails on purpose: FPE does not recompute Luhn, mod-97
   or the elfproef. A system that validates checksums on write must know that.
3. Decode all: every value equals the fixture.
4. Rewrap the cards `ccn-legacy` to `ccn-2026` in one call, then decode again.

**Note:** on 2.2.1 a request for an FF3-1 transformation is accepted and
silently made FF1 (the probe recorded it), so the rewrap demo moves values
between two FF1 transformations with different keys. It is the same call that
migrates FF3-1 data written by an older Vault.

The fixtures are synthetic: the card networks' published test numbers, IBANs
with bank code `TEST`, and BSNs from the government's 99999 test block.

## Lifecycle

One inventory over `pki-classic-int`, `pki-pqc-int` and `pki-pqc-next`:
algorithm, issuer, expiry, revocation. Revoke asks first, calls `POST
<mount>/revoke`, and the CRL card shows the new entry and its signature
algorithm. Each row links to the certificate in Vault's own UI, where 2.2 shows
certificate status and actions.

**Say:** "Two worlds, one process. Revoking an ML-DSA certificate is the same
call; only the CRL's signature changed."
