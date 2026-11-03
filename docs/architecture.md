# Architecture

```text
network vcry-internal                     every Vault listener: TLS 1.3, lab CA
 ├─ seal   vault-s     Community 2.2.1, Shamir 1/1, Transit key `autounseal`
 │          seal-rotator ── seal-agent ──► token sink (volume)
 ├─ vault  vault-1     Enterprise 2.2.1, Raft, seal "transit" through vault-s
 │          pki-classic-root → pki-classic-int     EC P-384 → EC P-256
 │          pki-pqc-root     → pki-pqc-int         ML-DSA-87 → ML-DSA-65
 │          pki-pqc-next                           target of the CA key move
 │          transit/   transform/
 ├─ identity openldap (dc=vcry,dc=local) ◄── keycloak (realm vcry, :13502)
 │           identity-secrets-init: AppRole → kv/vcry/identity → volume
 └─ app    rotator ── vault-agent ──► token sink ──► api (Node 24, :13500)
                  └── tls-agent ──► web certificate ──► web (nginx, :13501)

 person ─► web ─► api /auth/login ─► Keycloak (PKCE) ─► api /auth/callback
        api: person's access token ─► vault-1 auth/jwt/login ─► person's Vault token
```

## Containers

| Container | Image | Role |
| --- | --- | --- |
| `vcry-vault-s` | `hashicorp/vault:2.2.1` | Seal Vault. The only node a human (or `make unseal`) unseals. |
| `vcry-seal-rotator` | same | Keeps the seal agent's AppRole secret-id valid. |
| `vcry-seal-agent` | same | Vault Agent: Transit token for vault-1's seal, in a shared volume. |
| `vcry-vault-1` | `hashicorp/vault-enterprise:2.2.1-ent` | The lab. Reads the seal token once at start (agent sink first, bootstrap file second). Licence as a read-only file. |
| `vcry-rotator` | same | Keeps the `cryptolab-api` and `web-tls` secret-ids valid. |
| `vcry-vault-agent` | same | Token for the API, in a tmpfs volume the API reads per call. |
| `vcry-tls-agent` | same | Renders the console's certificate from `pki-classic-int/issue/web`. |
| `vcry-api` | `localhost/vault-crypto/api` | Node 24 + OpenSSL 3.5. The four rooms. No dependencies. |
| `vcry-web` | `localhost/vault-crypto/web` | nginx, TLS 1.3 only, React console, proxies `/api` and `/auth`. |
| `vcry-openldap` | `osixia/openldap:1.5.0` | The directory: five personas, four groups. |
| `vcry-keycloak` | `keycloak/keycloak:26.8.1` | Realm `vcry`, read-only LDAP federation, clients `vcry-console` and `vcry-cli`. |
| `vcry-identity-secrets-init` | vault-enterprise | One-shot: renders the identity secrets from Vault KV, revokes its token. |

Compose stacks `seal`, `vault`, `identity`, `app` (and the optional `publicca`), one project each (`vcry-<stack>`), run
only through `scripts/compose.sh`.

## Configuration vs runtime state

| Owner | What |
| --- | --- |
| Terraform `vault-seal` | AppRoles and policies on vault-s for the seal plane |
| Terraform `vault-platform` | AppRole mount, `cryptolab-api`, `web-tls`, `crypto-rotator` |
| Terraform `vault-identity` | `auth/jwt` (role `console`), `auth/ldap`, the four `vcry-*` human policies, external groups |
| Terraform `vault-crypto` | Both CA chains (module `pki-chain` twice), roles, `pki-pqc-next`, `transit/`, `transform/` with role, templates and the four FF1 transformations |
| `scripts/demo-seed.sh` | `transit/keys/orders-signing` and `ledger-data`: their algorithm changes during a demo, so Terraform must not own them |
| `scripts/pki-move.sh` | What gets imported into `pki-pqc-next` |
| `scripts/vault-bootstrap.sh` | Init, unseal, the seal key and fallback token, audit devices |

`make tf-plan-all` stays clean after any demo and after `make demo-reset`.

## The API

`api/server.js` (plain `node:http`) with one module per room in `api/lib/`
and `lib/session.js` for sign-in. Room calls run on the signed-in person's
Vault token (carried by `AsyncLocalStorage` into every Vault call); health and
capabilities read the agent's token file on every call, verifies vault-1's TLS against
the lab CA (`NODE_EXTRA_CA_CERTS`), and returns Vault's errors verbatim. It
keeps a little demo state in memory (signatures made, ledger ciphertexts) and
clears it when a demo key is recreated.

## Versions

Vault 2.2.1 (both editions), Terraform provider `hashicorp/vault` 5.13, Node
24.22, OpenSSL 3.5.9 (alpine 3.24), nginx 1.30, React 19, Vite 8, Playwright
1.64. Images are arm64.
