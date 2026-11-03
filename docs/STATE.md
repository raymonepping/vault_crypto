# Build state

What each prompt in `prompts/` did, what it deferred, and what was learned on
the way. Newest last.

## 01: Foundation (2026-11-03)

Done:

- Copied from `../vault_pki` (renamed `vpki`→`vcry`): `Makefile`, `scripts/`,
  `compose/{seal,vault,app,common}`, `terraform/{vault-seal,vault-platform}`,
  `vault/`, `e2e/` harness, `DESIGN.md`, `.gitleaks.toml`, `.github/`.
- `config/defaults.env`: Vault 2.2.1 / 2.2.1-ent, node 24, nginx 1.30.0,
  alpine 3.24.1; ports 18800/18801/13500/13501.
- Identities renamed: `cryptolab-api` (API), `web-tls` (tls-agent),
  `crypto-rotator`. The web certificate comes from `pki-classic-int/issue/web`.
- `.gitignore`: `prompts/`, `input/`, `article/`, `backups/`,
  `vault-tls/vault.key`, `!.env.example`.

Notes:

- The licence follows vault_pki, not the brief's wording: file
  `.secrets/vault/vault.hclic`, mounted read-only, named by
  `VAULT_LICENSE_PATH` (a path, not the licence). Same effect as `license_path`.
- `make check` found the Podman VM clock 250s behind the Mac, 443s by the
  time `make clock-sync` ran (drifting ~1s per second of wall time after the
  Mac slept). `make clock-sync` brought it to 0s.

Validated: `make help`, `make check` (after clock-sync), `make license`
(installed from the `.env` string, 1412 bytes), `make gen-certs`,
`make certs-status`, `make ports-check` (all four free).

## 02: vault-s and vault-1 (2026-11-03)

Done:

- `vault/vault-{s,1}/config.hcl` from vault_pki, plus bounded AppRole lockout
  (5 attempts / 30s) on both. `make vault-bootstrap` (second run: no
  changes), `make tf-seal`, seal rotator credential, `make seal-up`,
  `make vault-recreate`: vault-1 runs on the seal agent's token.
- `scripts/license-features.sh` (`make license-features`): per room, the
  licensed feature it needs. `verify.sh` rebuilt around this lab's sections
  (`podman`, `vault` so far).

Open question 1, answered: the licence (expires 2035-12-31) has
`Transform Secrets Engine` and `PKI External CA Secrets Engine` (prompt 07's
public CA integration), plus KMIP, Key Management, HSM and the rest. Every
room can be built.

Validated: `make vault-down && make vault-up`, `make vault-status`,
`make seal-token-status`, `make verify` 20/20.

Learned:

- **A full Mac disk corrupts writes in the Podman VM, then blocks every new
  container.** The Mac data volume was at 100% (2 GiB free). XFS in the VM
  logged write I/O errors at 08:20, and afterwards every `podman run` failed
  with overlay "input/output error" ("Cannot mount volatile when upperdir has
  an unseen error"). Freeing space alone did not help. One
  `sync -f` on the storage directory inside the VM reported the stored error
  and cleared it, and containers started again. The lost writes hit
  inodes of `/var/log/journal/…/system.journal` and
  **`zt-workshop_vault-data/_data/raft/raft.db`** (another project: reported,
  not touched). Freed space by `podman image prune -a` + `fstrim` (with the
  user's approval): 2 GiB → 7 GiB free.
- alpine 3.24.1 and node 24.22.2 both ship OpenSSL 3.5.9.

## 03: Prove 2.2, then Terraform (2026-11-03)

Done:

- `scripts/probe-2.2.sh` (`make probe`): 57 calls on scratch `probe-*`
  mounts, removed afterwards; `docs/capabilities.md`, 0 mismatches.
- `terraform/modules/pki-chain` (root → intermediate, URLs, CRL, OCSP switch,
  auto-tidy), used twice in `terraform/vault-crypto` (classic EC P-384/P-256,
  ML-DSA-87/65), roles `web` and `service` ×2, `pki-pqc-next`, `transit/`,
  `transform/` (role `payments`, templates `nl-iban`, `nl-bsn`, four FF1
  transformations). All roots on provider `hashicorp/vault` ~> 5.13.
- `scripts/demo-seed.sh` (`make demo-seed`, `make demo-reset`),
  `scripts/pki-move.sh` (`make pki-move`, `make pki-move-status`),
  `vault_list_json` in `common.sh`.
- Policies `cryptolab-api` and `web-tls` replace vault_pki's; rotator role
  `crypto-rotator`.

Open questions, answered:

2. FF3-1 cannot be created on 2.2.1: `fpe_algorithm=ff3-1` and
   `algorithm=ff3-1` are accepted and ignored, the transformation reads back
   `ff1`. The rewrap demo uses two FF1 transformations (`ccn-legacy` →
   `ccn-2026`). Deviation from the brief: the transformations are Terraform's
   (they never change during a demo), not demo-seed's.
3. Provider 5.13 has `parameter_set` on root, intermediate, key and role, and
   the hybrid fields on Transit keys. No `vault_generic_endpoint` needed for
   ML-DSA. (vault_pki's roots pinned 4.x; the lock files were regenerated.)
4. alpine 3.24.1's OpenSSL 3.5.9 and Node 24.22.2 (OpenSSL 3.5.9) both parse
   and verify ML-DSA chains; the host's OpenSSL 4.1 too. Node's
   `X509Certificate` reports `ml-dsa-44` and the signature OID, so the API
   verifies in-process and with the CLI.
5. CA key export: `POST <target>/export key_type=ml-kem-1024` (also rsa-*,
   ec-*, ml-kem-768), `POST <source>/keys/:key/export public_key=…` (needs
   sudo), `POST <target>/keys/import wrapped_key export_key_hmac`, then
   `issuers/import/cert` maps the certificate to the moved key.

Learned:

- **OCSP for an ML-DSA issuer:** 500 "internalerror" with the responder on;
  with `ocsp_disable=true` (what Terraform sets) 401 "unauthorized". The CRL
  works and is ML-DSA-65-signed.
- **Transit after an algorithm change:** `type` keeps the original;
  `latest_version_type` is the new one. Per version only `name` (`P-256`,
  `ml-dsa-` without the parameter set after a rotation, empty for hybrid) and
  the public key; symmetric keys show only a creation time. The API labels
  derived and observed types.
- **Every CA key export leaves a permanent warning** on the source issuer
  ("private key exported on … with sha256:…"). `demo-reset` cannot remove it.
- `vault list` on an empty path prints `[]` and exits 2.
- Sizes measured: ML-DSA-44 leaf 5.1 KB DER vs 0.75 KB ECDSA; signature 3309 B
  (ML-DSA-65 by the intermediate) vs ~71 B; public key 1334 B vs 91 B; ML-DSA-87
  root 7.5 KB; SLH-DSA-SHA2-128s Transit signature ~10.5 KB base64.

## 04: cryptolab API (2026-11-03)

Done:

- `api/` (Node 24, ESM, no dependencies): `lib/{vault,x509,openssl,formats,
  pki,agility,fpe,certs}.js`, `server.js`, `fixtures/fixtures.json` (generated
  by `scripts/gen-fixtures.js`), `Containerfile` (fails if OpenSSL < 3.5).
- `compose/app`: `api` replaces certinfo (no data volume, stateless apart
  from in-memory demo history). `scripts/api-test.sh` (`make api-test`):
  32/32. `make test-unit`: 15/15. `verify.sh` sections `crypto`, `identity`
  (asks Vault for the API token's capabilities: deny on root generation, CA
  key export, Transit export, other keys), `app`, `rooms`.

Decisions:

- **The CA move is not an API action.** Export needs sudo and wraps to any
  public key the caller supplies, so a compromised API could exfiltrate the
  CA key. `make pki-move` (operator, root token) does it; the API reads the
  evidence.
- `sys/license/status` is readable by the API (features and expiry, not the
  licence) for the overview.
- AES and ChaCha20 are family "symmetric", not "classic": with 256-bit keys
  they keep a 128-bit margin against Grover.

Learned:

- `AbortSignal.timeout` replaced by a referenced `setTimeout` +
  `AbortController` (memory: it can silently never fire).

## 05: The UI (2026-11-03)

Done:

- `web/` React 19 + Vite 8 + Tailwind 4, skill CSS (`vault-glass.css`,
  `shell.css`) unchanged plus `app.css`; five pages; "Vault said" drawer;
  nginx TLS 1.3 from vault_pki with the API proxy.
- `DESIGN.md` rewritten for this lab (family state map, AA ratios).
- `e2e/`: shell, pki, agility, fpe, lifecycle, served, a11y (axe, 5 screens ×
  desktop/phone), screenshots. `make test-ui` 24/24, 0 axe violations.

Learned:

- **A visually hidden cell in a scrolled table widened the whole page on a
  phone.** `.sr-only` is `position: absolute`; its containing block was the
  viewport, not the `overflow-x: auto` frame, so `scrollWidth` became 684 px
  at a 390 px viewport. `position: relative` on `.table-scroll` fixed it.
  Flex children also needed `min-width: 0`.
- **The phone overflow test passed while the page overflowed:** with
  `isMobile: true` the layout viewport widens to the content. The test now
  uses a plain 390 px viewport and waits for the tables.
- shell.css hides every `.vault-link span` below 1180 px, which left the
  topbar button without an accessible name; labels are now visually hidden
  instead (axe `label-content-name-mismatch` forbids an `aria-label` that
  differs from the visible text).
- macOS curl has no `--tlsv1.3`; verify uses `openssl s_client -tls1_3/-tls1_2`.
- Full-page screenshots paint sticky elements mid-page; the screenshot spec
  unsticks the topbar (bypassCSP, docs only).

## 06: Resilience and docs (2026-11-03)

Done:

- `doctor.sh` adds the rooms: licence features, demo keys, probe report;
  `test-rotation.sh` checks a real Vault call (`/api/pki/chains`) and no
  longer accepts an empty accessor as "a new token"; `bootstrap.sh` runs the
  probe and demo-seed (12 steps); `web-cert.sh`, `trust-root.sh` on
  `pki-classic-root`.
- Docs: `README.md`, `docs/{rooms,architecture,security-model,operations}.md`,
  `CHANGELOG.md`, `DESIGN.md`; `.claude/CLAUDE.md`.

Validated (after `make down && make up`): `make verify` 62/62, `make doctor`
clean, `make tf-plan-all` clean, `make test-unit` 15/15, `make test-ui` 24/24,
`make api-test` 32/32, `make rotation-test` 28/28, `make backup`.

Learned:

- **tls-agent crash-looped after its first restart** (inherited from
  vault_pki's compose): its token sink is a tmpfs, and after `restart:
  on-failure` Podman recreated it root-owned, so the agent (uid 100) failed
  "error creating file sink … permission denied" forever. nginx kept serving
  the old certificate, so nothing looked wrong until it would expire. The
  rotation test hid it: an empty accessor compared unequal to the old one and
  counted as "a new token". Fix: `/vault/secrets:U,mode=0700` (Podman rejects
  `uid=`/`gid=`), and the test requires a real accessor. vault_pki (and any
  sibling with a tmpfs token sink) likely has the same latent bug: not touched
  from here.

## 07: Optional: public CA (2026-11-03)

Part A done, Part B **not built**, as the prompt requires when the probe fails.

- `compose/publicca` (Pebble 2.10.1 + pebble-challtestsrv 2.10.1, arm64; not
  in `make up`), `scripts/publicca-probe.sh`, `make publicca-up |
  publicca-down | publicca-probe`, report in `docs/publicca-probe.md`.
- Source: developer.hashicorp.com/vault/api-docs/secret/pki-external-ca and
  docs/secrets/pki-external-ca.

What works on 2.2.1+ent: the `pki-external-ca` plugin is built in and
licensed; ACME account against `https://pebble:14000/dir` with `trusted_ca`;
role; `new-order`; challenge read (a GET with `identifier` and
`challenge_type` as query parameters: `vault read path k=v` answered "No value
found"); `fulfilled-challenge`; Pebble validates HTTP-01 and **issues** the
certificate.

What fails, reproducibly (3 orders): Vault's client then ends the order in
`error`: `failed to create order certificate at finalize URI
https://pebble:14000/finalize-order/…: Post "": unsupported protocol scheme ""`.
`fetch-cert` answers 400 "order has status error". The client posts to an empty
URL after finalize: Pebble does not send a `Location` header on the finalize
response (RFC 8555 does not require one), and Vault's client appears to rely
on it. Not tested against a real public CA (no public DNS here), so whether
Let's Encrypt behaves the same is unknown. Re-run `make publicca-probe` after a
Vault upgrade; build Part B when it passes.

Also learned: challenges appear asynchronously after `new-order`; asking too
early gives 404 on `fulfilled-challenge`. The probe waits for the token.

## 08: Vault authN and authZ, LDAP + Keycloak (2026-11-03)

Done:

- `compose/identity` (from Project Durin): `identity-secrets-init`,
  OpenLDAP 1.5.0, Keycloak 26.8.1 on 13502, one-shot `ldap-bootstrap` and
  `keycloak-bootstrap`. Directory `dc=vcry,dc=local`, four groups, five
  fictional personas. Realm `vcry`, read-only LDAP federation, `groups` claim,
  clients `vcry-console` (code + PKCE) and `vcry-cli` (lab-only tests).
- Secrets in KV v2 `kv/vcry/identity/*` (`scripts/identity-secrets.sh`,
  create-only; `--copy` to the clipboard, never printed). AppRole
  `identity-secrets` in `vault-platform`.
- Terraform root `vault-identity`: `auth/jwt` role `console`, `auth/ldap`,
  policies `vcry-viewer`, `vcry-pki-operator`, `vcry-key-custodian`,
  `vcry-data-steward` (`vault/policies/human-*.hcl`), external groups
  `kc-vcry-*`. `cryptolab-api` shrank to platform facts + the console's
  client secret.
- API: `lib/session.js` (BFF: `/auth/login|callback|logout`, `/api/me` with
  Vault's `sys/capabilities-self` answers, Bearer tokens for scripts).
  `AsyncLocalStorage` in `lib/vault.js` carries the person's Vault token into
  every room call; room modules unchanged.
- Console: Sign in / person menu, "your authority" strip per room, lock
  markers on actions Vault will refuse (buttons stay clickable).
- Tests: `scripts/identity-verify.sh` (39 checks), `api-test.sh` as olga plus
  refusals for vera, piet, kees, dana (47), `verify.sh` section
  `identity_people` and the rooms as olga (67), Playwright signs in through the
  real Keycloak form (global setup as olga; `authz.spec.ts` as vera and for
  sign-out; axe signed in and signed out), unit tests for PKCE (RFC 7636
  vector), cookies, return paths, capability map (21).

Validated after `make down && make up`: verify 67/67, doctor clean,
tf-plan-all clean (4 roots), unit 21/21, api-test 47/47, test-ui 27/27 plus 2
signed-out axe scans, identity-verify 39/39, rotation-test 28/28.

Decisions:

- Vault UI and CLI log in with LDAP, not OIDC: Keycloak's issuer is the
  browser's `http://localhost:13502`, which vault-1 cannot reach for OIDC
  discovery. The console's JWT path works because `jwks_url` is internal and
  `bound_issuer` public (Durin's pattern).
- Buttons are not disabled for missing authority: Vault refuses, and the
  console shows the refusal verbatim. The lock only predicts it.

Learned:

- The `vault_kv_secret_v2` data source is deprecated in provider 5.x; the
  ephemeral resource plus `bindpass_wo` keeps the LDAP bind password out of
  Terraform state.
- Vault returns permission errors as "1 error occurred:\n\t* permission
  denied"; the console tidies whitespace, keeps the words.
- A signed-out room showed two sign-in prompts (chains + move card); the move
  card now renders only for a signed-in person.

## 09: Optimize without changing behaviour (2026-11-03)

Prompt by Codex (who also added `.agents/`, `.codex/`, `AGENTS.md`; all
ignored or excluded from git). `AGENTS.md` said prefix `vcr-`; corrected to
`vcry-` only and filled in the real commands.

Baseline (prompt 08's checks, before any change): all green except one
api-test assertion, a test bug that predates prompt 09: it required a CRL on
`pki-pqc-next`, which has none after `make demo-reset`. Fixed the assertion.

Done: see `docs/optimization.md` (conditions, before/after, changes, tests,
deferred items). Headline: inventory peak Vault concurrency 90 → 8 (450 → 8
under 5 parallel), verify of 50 signatures 51 → 2 Vault calls (66 → 22 ms),
JS 288 → 87 KB on the wire and cached for a year.

Validated after the change: test-unit 29 + 3, identity-verify 39/39, verify
67/67, api-test 47/47, test-ui 30/30, tf-plan-all clean, doctor clean,
rotation-test 28/28, then `make down && make up`: verify 67/67, doctor clean.
The counters route is off by default (`/api/_stats` answers 404).

Learned:

- Transit `verify` accepts `batch_input` on 2.2.1 for every algorithm the demo
  uses, across versions, and echoes `reference`; an empty `batch_input` is an
  error ("missing batch input to process").
- A limiter that frees its slot in `.finally()` frees it after the awaiting
  caller resumes, so work queued right after a completion sees a busy slot.
  Release before resolving.
- nginx `add_header` in a location replaces every inherited header: the CSP
  disappears from assets unless repeated.
- `node --test test/` treats the directory as one file on Node 25; use a glob.
