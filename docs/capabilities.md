# Vault 2.2 capabilities, as vault-1 answered

Written by `make probe` (`scripts/probe-2.2.sh`) on 2026-11-03T07:57Z against
vault-1 **2.2.1+ent**, on scratch mounts `probe-*` that the probe removed
afterwards. Every row is a real call. Key material, tokens and full
certificates are never recorded. The demo rooms use only calls listed here.

| Area | Call | Outcome | What Vault said |
| --- | --- | --- | --- |
| PKI | `POST root/generate/internal key_type=ml-dsa parameter_set=ml-dsa-44` | ok (200) | self-signed root, 4009 bytes DER |
| PKI | `POST root/generate/internal key_type=ml-dsa parameter_set=ml-dsa-65` | ok (200) | self-signed root, 5538 bytes DER |
| PKI | `POST root/generate/internal key_type=ml-dsa parameter_set=ml-dsa-87` | ok (200) | self-signed root, 7496 bytes DER |
| PKI | `POST root/generate/internal (ml-dsa-87, the PQC root)` | ok (200) | issuer 824cf0c5… |
| PKI | `POST intermediate/generate/internal key_type=ml-dsa parameter_set=ml-dsa-65` | ok (200) | CSR 7306 bytes PEM |
| PKI | `POST root/sign-intermediate (ML-DSA-87 signs ML-DSA-65)` | ok (200) | signed |
| PKI | `POST intermediate/set-signed` | ok (200) | imported issuers: 2 |
| PKI | `POST roles/leaf key_type=ml-dsa parameter_set=ml-dsa-44` | ok (200) | role written |
| PKI | `POST issue/leaf` | ok (200) | private_key_type=ml-dsa, private_key_parameter_set=ml-dsa-44 |
| PKI | leaf / intermediate / root size | measured | 4941 / 6859 / 7500 bytes DER |
| PKI | openssl verify (alpine 3.24.1) | measured | OpenSSL 3.5.9: /pq/leaf.pem: OK |
| PKI | Node crypto.X509Certificate | measured | node 24.22.2 (OpenSSL 3.5.9): key ml-dsa-44, sig ML-DSA-65 2.16.840.1.101.3.4.3.18, leaf.verify(int)=true, int.verify(root)=true |
| PKI | `GET crl/pem` | ok (200) | CRL signed with ML-DSA-65 |
| PKI | `POST ocsp (ML-DSA issuer)` | refused, as expected (500) | Responder Error: internalerror (2) (docs: ML-DSA CAs are not supported for OCSP) |
| PKI | `POST revoke` | ok (200) | revocation_time 1793692631 |
| PKI (Ent) | `POST export key_type=ml-kem-1024 (on the target mount)` | ok (200) | public key PEM type: BEGIN MLKEM PUBLIC KEY, export_key_hmac sha256:9beb6557… |
| PKI (Ent) | `POST keys/:key_ref/export public_key=<target's ML-KEM key>` | ok (200) | wrapped_key 3168 chars; needs sudo on this path |
| PKI (Ent) | `POST keys/import wrapped_key + export_key_hmac` | ok (200) | key_type=ml-dsa, parameter_set=ml-dsa-65 |
| PKI (Ent) | `GET issuer/default (source, after export)` | ok (200) | warning: private key exported on 2026-11-03T07:57:11Z wit… |
| PKI (Ent) | `POST issuers/import/cert (the intermediate's certificate)` | ok (200) | issuer mapped to the moved key: true |
| Transit | `POST keys/sig type=ecdsa-p256` | ok (200) | created |
| Transit | `POST sign/sig (after create)` | ok (200) | signature vault:v1, 105 chars |
| Transit | `POST keys/sig/algorithm type=ml-dsa parameter_set=65` | ok (200) | latest_version=2, latest_version_type=ml-dsa |
| Transit | `POST sign/sig (after → ml-dsa)` | ok (200) | signature vault:v2, 4421 chars |
| Transit | `POST keys/sig/algorithm type=hybrid (ml-dsa 65 + ecdsa-p256)` | ok (200) | latest_version=3, latest_version_type=hybrid |
| Transit | `POST sign/sig (after → hybrid)` | ok (200) | signature vault:v3, 4517 chars |
| Transit | `POST verify/sig (v1 signature, key now v3)` | ok (200) | valid=true |
| Transit | `POST verify/sig (v2 signature, key now v3)` | ok (200) | valid=true |
| Transit | `POST verify/sig (v3 signature, key now v3)` | ok (200) | valid=true |
| Transit | `GET keys/sig` | ok (200) | type=ecdsa-p256 (the original), latest_version_type=hybrid, per-version name: P-256, ml-dsa-, (empty) |
| Transit | `POST keys/sig/algorithm type=aes256-gcm96 (signing → encryption)` | refused, as expected (400) | incompatible algorithm aes256-gcm96 for key type ecdsa-p256  |
| Transit | `POST keys/slh type=slh-dsa parameter_set=slh-dsa-sha2-128s` | ok (200) | created |
| Transit | `POST sign/slh` | ok (200) | signature 10485 chars |
| Transit | `POST keys/led type=aes128-gcm96` | ok (200) | created |
| Transit | `POST encrypt/led` | ok (200) | vault:v1 |
| Transit | `POST keys/led/algorithm type=aes256-gcm96` | ok (200) | latest_version_type=aes256-gcm96 |
| Transit | `POST keys/led/algorithm type=chacha20-poly1305` | ok (200) | latest_version_type=chacha20-poly1305 |
| Transit | `POST rewrap/led batch_input=[v1 ciphertext]` | ok (200) | → vault:v3 |
| Transit | `POST decrypt/led (rewrapped)` | ok (200) | plaintext equal |
| Transit | `POST keys/led/algorithm type=ed25519 (encryption → signing)` | refused, as expected (400) | incompatible algorithm ed25519 for key type aes128-gcm96  |
| Transform | `POST template/nl-iban regex over the 10-digit account part` | ok (204) | written |
| Transform | `POST role/pay` | ok (204) | written |
| Transform | `POST transformations/fpe/ccn-old template=builtin/creditcardnumber` | ok (204) | written |
| Transform | `POST transformations/fpe/ccn-new template=builtin/creditcardnumber` | ok (204) | written |
| Transform | `GET transformations/fpe/ccn-old` | ok (200) | fpe_algorithm=ff1 |
| Transform | `POST transformations/fpe/try-ff3 fpe_algorithm=ff3-1` | ok (204) | accepted; parameter ignored |
| Transform | `GET transformations/fpe/try-ff3` | ok (200) | fpe_algorithm=ff1: FF3-1 cannot be created on 2.2.1+ent |
| Transform | `POST transformations/fpe/iban template=nl-iban` | ok (204) | written |
| Transform | `POST encode/pay batch_input (card, IBAN)` | ok (200) | 4111-1111-1111-1111 → 6462-0532-8112-0727, NL91ABNA0417164300 → NL91ABNA0764441313 |
| Transform | `POST decode/pay` | ok (200) | → 4111-1111-1111-1111 |
| Transform | `POST rewrap/pay batch_input (ccn-old → ccn-new)` | ok (200) | 6462-0532-8112-0727 → 4944-2460-2336-3109, no plaintext in the response |
| Transform | `POST decode/pay (rewrapped value, ccn-new)` | ok (200) | → 4111-1111-1111-1111 |
| Transform | `POST decode/pay (rewrapped value, old transformation)` | ok (200) | → 7118-6660-0640-8252 (a different number: FPE has no integrity check) |

Mismatches against the expected outcome: **0**.
