# Security model

## People (prompt 08)

Every room action runs on a Vault token issued **to the person**, not to the
application. The console's backend (the API) signs people in with Keycloak
(Authorization Code + PKCE), keeps their tokens server-side, and logs them in
to Vault with their own access token at `auth/jwt/login` (role `console`).
Vault checks signature, issuer and audience itself and attaches policies from
the person's groups. The API's own AppRole can no longer do anything in a room.

| LDAP group (Keycloak `groups` claim) | Vault policy | May |
| --- | --- | --- |
| `vcry-viewers` | `vcry-viewer` | read every room: chains, roles, certificates, CRLs, the demo keys, transformations; verify signatures |
| `vcry-pki-operators` | `vcry-pki-operator` | issue from `service` on the three issuing mounts; revoke |
| `vcry-key-custodians` | `vcry-key-custodian` | change the two demo keys' algorithm; sign, encrypt, rewrap, decrypt |
| `vcry-data-stewards` | `vcry-data-steward` | FF1 encode, decode, rewrap |

| Persona (fictional) | Groups |
| --- | --- |
| `vera` | viewers |
| `piet` | viewers, PKI operators |
| `kees` | viewers, key custodians |
| `dana` | viewers, data stewards |
| `olga` | all four |

Nobody can export a CA key or a Transit key, or delete a demo key, through the
console. `make pki-move` stays an operator action.

- **Console:** Keycloak realm `vcry` federates `dc=vcry,dc=local` read-only.
  Client `vcry-console` is confidential (secret in Vault KV, read by the API
  with its own token). The browser holds only an opaque `vcry_sid` cookie
  (httpOnly, Secure, SameSite=Lax); access, refresh and Vault tokens never
  leave the API. Vault tokens live 15 minutes; Keycloak access tokens 5, renewed
  with the refresh token.
- **Vault UI and CLI:** `auth/ldap` against the same directory, groups mapped
  to the same policies (`vault login -method=ldap username=piet`).
- **External groups:** one per Keycloak group (`kc-vcry-*`) with an alias on
  the `jwt` mount; Vault resolves membership at each login.
- **`vcry-cli`** is a public Keycloak client with direct access grants, for
  scripted tests only (`identity-verify`, `api-test`, `verify`). Remove it
  outside a lab.
- **Secrets:** LDAP admin, Keycloak admin, the console's client secret and one
  password per persona live in `kv/vcry/identity/*`, generated once by
  `scripts/identity-secrets.sh`. A one-shot init container (AppRole
  `identity-secrets`, read-only on that path) renders them for OpenLDAP and
  Keycloak and revokes its token. Terraform reads the LDAP bind password
  ephemerally into a write-only attribute: it is not in Terraform state.

## Machine identities

| Identity | Vault | Credential | Can |
| --- | --- | --- | --- |
| `crypto-rotator` | vault-1 | the only app credential a human hands over (`make rotator-bootstrap`), `secret_id_ttl=0`, bound to the `vcry-internal` subnet | read role-ids, issue and destroy secret-ids for `cryptolab-api` and `web-tls` |
| `cryptolab-api` | vault-1 | secret-id from the rotator, 90 days, rotated at 1/3 life; token 15 min via vault-agent | platform facts only: `sys/license/status`, the three reads behind `/api/capabilities`, the console's client secret |
| `identity-secrets` | vault-1 | CIDR-bound secret-id in `.secrets/vault/identity/` | read `kv/vcry/identity/*` |
| `web-tls` | vault-1 | same pattern; token stays in tls-agent's tmpfs | `pki-classic-int/issue/web` only |
| `seal-rotator`, `seal-autounseal` | vault-s | same pattern on the seal plane | Transit encrypt/decrypt with `autounseal` |

All AppRoles bind tokens and secret-ids to the `vcry-internal` subnet. AppRole
lockout is bounded to 5 attempts / 30 s so a rotation gap never becomes a
15-minute outage.

## What the API may do with its own token

Policy: [vault/policies/cryptolab-api.hcl](../vault/policies/cryptolab-api.hcl).
Read the licence's features and expiry, read one path per room to show whether
it is configured, read the console's OIDC client secret. Every other call it
makes carries the signed-in person's Vault token.

## What nobody may do through the console (checked by `make verify` and `make identity-verify`)

- Act in a room with the API's own token (`make verify` asks Vault).
- Generate or change a CA (`pki-*-root/root/*`).
- **Export a CA key.** `pki-*/keys/:key/export` needs `sudo`, and whoever holds
  it can wrap the key to *any* public key they choose. The move is an operator
  action, `make pki-move`, run with the admin token; the console only shows the
  evidence Vault recorded.
- Export Transit keys, use any other Transit key, or delete the demo keys.

## Data

- The API drops the private key from every issue response before it reaches
  the browser. No key material is logged or stored.
- FF1 only accepts the fixture rows; arbitrary personal data cannot be sent
  through the console. The fixtures are synthetic (published test card numbers,
  bank code `TEST`, generated BSNs that pass the elfproef).
- The ledger plaintext you type is kept in the API's memory to compare after
  decryption; type nothing real.

## TLS

- Every Vault listener: TLS 1.3, lab CA (`make gen-certs`), verified by every
  client. No `-tls-skip-verify`, `VAULT_SKIP_VERIFY` or
  `NODE_TLS_REJECT_UNAUTHORIZED=0` anywhere.
- The console: TLS 1.3 only, certificate from `pki-classic-int` (ECDSA), CSP
  `default-src 'self'`. ML-DSA would be refused by browsers today.
- OCSP is off on `pki-pqc-int`: Vault 2.2.1 cannot answer for an ML-DSA
  issuer. Revocation is published in the CRL, signed with ML-DSA-65.

## Secrets on disk

`.secrets/` (git-ignored): init JSON with root and recovery material, the
fallback seal token, rotator credentials, Terraform state, the lab CA key, the
licence. `make backup` archives it with Raft snapshots into `backups/`. The
root token is a lab shortcut used only by host-side scripts (`tf.sh`, bootstrap,
probe, demo-seed, pki-move); no container holds it.
