# Optimization (prompt 09)

Less Vault load, fewer round trips and smaller downloads, with every crypto
demonstration and every person's authority unchanged.

## Conditions

- Source: commit `928ba49` plus the uncommitted prompts 01–09 work (the whole
  lab is still uncommitted).
- Runtime: vault-1 `2.2.1+ent`, API on `node:24-alpine` (Node 24.22.2,
  OpenSSL 3.5.9), nginx 1.30.0, Keycloak 26.8.1. Host: Apple Silicon, rootless
  Podman.
- Person: `olga` (all four groups), Bearer token from `vcry-cli`, warm (one
  call before sampling: the person's Vault login and connection reuse).
- Data: inventory of 85 certificates (49 classic, 30 ML-DSA, 6 on the moved
  mount); `orders-signing` at v1 (ECDSA) with 0, 1 or 50 stored signatures.
  Same data, person and key versions before and after.
- Method: `node api/scripts/bench.js 20` (sequential, 20 samples per
  operation; the 5-parallel row 5 samples of 5) against an API started with
  `VCRY_STATS=1`, which counts Vault requests and the peak in flight. With 20
  samples, p95 is indicative only.

## Results

| Operation | Before: median / p95 | After: median / p95 | Vault requests per call | Peak Vault requests in flight | Errors |
| --- | --- | --- | --- | --- | --- |
| `GET /api/certs` (inventory) | 49.1 / 64.7 ms | 39.2 / 58.2 ms | 99 → 99 | **90 → 8** | 0 → 0 |
| `GET /api/certs` ×5 parallel | 181 / 397 ms | 151 / 156 ms | 99 → 99 | **450 → 8** | 0 → 0 |
| `GET /api/pki/chains` | 5.5 / 6.4 ms | 3.5 / 5.5 ms | 8 → 8 | 4 → 8 | 0 → 0 |
| `GET /api/me` | 6.2 / 10.2 ms | 5.4 / 10.0 ms | 1 → 1 | 1 → 1 | 0 → 0 |
| `POST /api/agility/verify`, 0 signatures | 2.0 / 2.3 ms | 1.7 / 1.9 ms | 1 → 1 | 1 → 1 | 0 → 0 |
| `POST /api/agility/verify`, 1 signature | 3.7 / 4.3 ms | 3.2 / 4.2 ms | 2 → 2 | 1 → 1 | 0 → 0 |
| `POST /api/agility/verify`, 50 signatures | 66.0 / 79.1 ms | **22.4 / 25.2 ms** | **51 → 2** | 1 → 1 | 0 → 0 |

| Static asset (gzip requested) | Before | After |
| --- | --- | --- |
| JavaScript bundle | 288 072 B, no cache policy | 87 213 B, cached a year (`immutable`) |
| CSS | 61 271 B, no cache policy | 15 669 B, cached a year (`immutable`) |
| `index.html` | no cache policy | `no-cache` (revalidates) |
| `/api/*`, `/auth/*` | `no-store`, uncompressed | unchanged |

The inventory still makes 99 Vault requests: one per certificate. The cap
trades nothing measurable in throughput here (the parallel case got faster
because Vault was no longer flooded) and makes the load predictable.

## What changed

| Area | Change | Where |
| --- | --- | --- |
| Fan-out (P1) | One shared limit (8 at once, queue 4000, 503 when full) for every Vault fan-out: inventory certificate reads across the three mounts and all concurrent requests, the two chains, CRLs. Slots are released before the caller resumes, on success and on error. | `api/lib/limit.js`, `certs.js`, `pki.js` |
| Inventory honesty | `truncated`, `cap.perMount` and `cap.selection` ("the last serials in Vault's list order, by serial, not by date"); the Lifecycle page says so when capped. | `certs.js`, `Lifecycle.jsx` |
| Batch verify (P1) | One `transit/verify` call with `batch_input` and `reference` = signature id, proven on 2.2.1 across ECDSA, ML-DSA and hybrid versions. `valid:false`, a per-item error ("version is too new") and a 403 for the whole request stay three different answers. Empty history makes no call (Vault rejects an empty batch). | `agility.js` |
| Demo state (P1) | Monotonic ids (never reused after the 50-entry cap evicts), snapshots before awaits, results applied by `reference`/id, rewrap applied only to entries still holding the ciphertext sent and only within the same key epoch. Writes to the same demo key are serialized (rotate, sign, encrypt, rewrap); reads and other keys stay parallel. The history stays shared across people, as in prompt 08. | `agility.js` |
| OpenSSL (P1) | Every child: 10 s deadline (SIGKILL), 4 MiB output cap, at most 4 at once (queue 64). A timeout is `unavailable` / HTTP 504, never "invalid". Node and OpenSSL both still verify. Temp files are removed in `finally`. | `openssl.js`, `server.js` |
| Vault client (P1) | The deadline now covers the body, not just the headers: a stalled body is aborted (504). Raw CRL/OCSP answers are read in full inside the deadline. | `vault.js` |
| Sessions | Concurrent requests from the same credential share one refresh and one Vault login (keyed by session id or token hash, never by name). The Bearer cache is capped at 256. Lifetimes unchanged; no response caching; refusals are never cached. | `session.js` |
| Browser (P1) | Newest-answer-wins reads with abort; polls scheduled after the previous one ends (no pile-up); hidden tabs stop polling and refresh on return; a cancelled read is never shown or logged as a refusal. Sign-in and sign-out are full page loads, so another person's data and drawer entries cannot survive a switch (tested). | `latest.js`, `hooks.js`, `api.js` |
| Delivery (P2) | `/assets/` gzip + one-year immutable caching; HTML revalidates; security headers repeated where `add_header` would drop them; `/api/` and `/auth/` untouched. | `web/nginx/default.conf.template` |
| Builds (P2) | `make app-rebuild TARGETS=api` recreates only the rebuilt service. | `Makefile` |
| Measurement | Opt-in counters (`VCRY_STATS=1`, off by default) and `api/scripts/bench.js`. Counts only; no tokens, cookies or bodies. | `vault.js`, `server.js` |

## Tests added

`api/test/limits.test.js`: limit holds across overlapping callers and keeps
order; a failing job frees its slot; a full queue answers 503; same-key
serialization while other keys run; capped history ids; batch answers mapped
by reference out of order; a hung child killed at the deadline (and the next
one works); a stalled Vault body aborted at the deadline; concurrent logins for
one credential deduplicated, different credentials not. `web/test/latest.test.js`:
newer read aborts the older, out-of-order answers, unmount.
`e2e/tests/authz.spec.ts`: switching olga → vera leaves no room data and no
drawer entries. `make test-unit` runs both unit suites.

## Deliberately not done

| Item | Why |
| --- | --- |
| Caching certificate reads or parsing | 39 ms per inventory with the cap; a cache would need revocation-aware invalidation for no measured need. |
| Pagination of the inventory | Vault's LIST has no time order; the cap is reported honestly instead. |
| Fewer `/api/health` probes (container every 10 s, each console every 15 s) | Two unauthenticated `sys/health` calls, a few ms; coalescing would delay outage detection for no measured cost. |
| A larger fan-out limit | 8 already removed the flood; not tuned further without a reason. |
| Parallel Playwright workers | Journeys share the demo keys. |
| Build-time work | `make app-rebuild TARGETS=…` covers the common case; full builds were not measured, so no claims. |
| Backing up the LDAP and Keycloak volumes | Not a speed item, reported here: `make backup` snapshots Vault (which holds every identity secret in `kv/vcry/identity`) but not the `vcry-identity_*` volumes. Recovery is consistent without them: restore Vault, `make identity-up`, `make identity-bootstrap` rebuilds the directory and realm from `bootstrap.ldif` and KV. Keycloak sessions are lost, nothing else. |

## Re-measure

```bash
make bench                     # API with counters, 20 samples per read path, API back without counters
SAMPLES=50 make bench
```

`make bench` measures the read paths. For verify with stored signatures, sign
messages as olga first (the Crypto agility room), then run
`ONLY=verify SIGS=50 node api/scripts/bench.js 20` while the API runs with
`VCRY_STATS=1`. The API restarts twice: demo history and console sessions are
in memory and start empty.
