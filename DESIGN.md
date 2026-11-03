# DESIGN.md: vault_crypto console

The console follows **Vault daylight glass**, the house system for every Vault
project (canonical implementation: Arcanium; contract: the `vault-ui-design`
skill). Light frosted panes, black ink, one dark ink hero per page, strong
status colours that hold WCAG AA. This file states only what vault_crypto adds
or decides on top of it.

## Stack

- React 19 + Vite 8 + Tailwind v4 (`web/`), served by nginx over TLS 1.3 with
  the certificate tls-agent renders from `pki-classic-int/issue/web`.
- `web/src/styles/vault-glass.css` and `shell.css` are copied unchanged from
  the skill (`:deep()` removed from `shell.css`, which is Vue-only). Everything
  this lab adds is in `web/src/styles/app.css`.
- Fonts: Hanken Grotesk Variable and JetBrains Mono Variable via
  `@fontsource-variable`, bundled, no external requests.
- Icons: `lucide-react`. No emoji.
- CSP `style-src 'self'`: no inline styles. Byte bars are SVG with `width`
  attributes, not CSS widths.

## State map: colour means state

| State | Use | Token | Text on its tint |
| --- | --- | --- | --- |
| classic | ECDSA, RSA, Ed25519 keys and signatures | `--lab-classic` `#3d45ad` on indigo 13% | ≈ 5.9:1 |
| post-quantum | ML-DSA, SLH-DSA, hybrid, ML-KEM | `--lab-pq` (`--vg-info` `#0b5f73`) on cyan 12% | ≈ 5.6:1 |
| symmetric | AES, ChaCha20 (quantum-resistant at 256 bits) | `--lab-sym` (`--vg-text-secondary`) on slate 12% | ≈ 9:1 |
| ok | verified, valid, equal, available | `vg-pill--healthy` | system |
| warn | OCSP off, checksum fails after FPE, exported key, expired | `vg-pill--pending` | system |
| denied | refused by Vault, revoked, not licensed | `vg-pill--rejected` | system |
| info | facts with no verdict (private key dropped) | `vg-pill--approved` | system |

Inside the hero the `--lab-*` tokens are re-scoped to light values, like the
system's own tokens. Contrast is verified by axe (`make test-ui`, 0 violations
at 1440×900 and 390×844), not assumed.

## Rules for this console

1. **Vault's answer verbatim.** Refusals show Vault's error lines in an
   `inline-notice error` as `Vault said: <code>…</code>`. Every call is kept in
   the "Vault said" drawer as raw JSON. The API drops private keys before the
   browser sees anything.
2. **Measured, never typed.** Byte counts, ratios and algorithm names come
   from the certificate or key Vault just returned. No number is hard-coded.
3. **Unknown is not empty.** A version type Vault does not report says "not
   reported by Vault"; a derived one says "derived from Vault's key read".
4. **One ink hero per page**, holding the page's question and its live
   figures. Tiles inside it use the re-scoped tokens.
5. **Machines speak mono:** paths, serials, key ids, ciphertext, HMACs.
6. Tables scroll inside their own frame (`.table-scroll`, focusable, `position:
   relative` so hidden header cells cannot widen the page). Pages never scroll
   sideways at 390 px (`shell.spec.ts` checks every page).
7. Destructive actions (revoke) confirm in a native `<dialog>`.

## Pages

| Route | Hero question | Main pane |
| --- | --- | --- |
| `#/overview` | Vault 2.2, crypto agility | four room cards with availability from `/api/capabilities` |
| `#/pki` | What does post-quantum cost a certificate? | two chain columns, byte bars, OCSP, CA key move |
| `#/agility` | Same key name, new algorithm | signing key timeline + signatures, ledger key + rewrap |
| `#/fpe` | Encrypted, and still the right shape | fixture table: encode, decode, rewrap |
| `#/lifecycle` | Every certificate, both worlds | CRL cards, filterable inventory, revoke |

## Shell

- The rail folds to a 52 px icon column (`.vg-sidebar.collapsed` from
  `shell.css`); the toggle sits in the rail's footer, the labels stay readable
  by screen readers and as tooltips, and the choice is remembered per browser
  (`localStorage`, optional).
- A floating glass footer closes every page, as in vault_reference and
  vault_pki: the signature with its shimmer, the motto "Change the algorithm,
  keep the name.", the verbs Sign · Rotate · Rewrap · Verify, and the four
  round links (GitHub, X, LinkedIn, Medium). Colours from tokens only.

## Checks

`make test-ui` (journeys + axe), `make screenshots` (desktop + phone into
`docs/screenshots/`). Review both sizes after any UI change.
