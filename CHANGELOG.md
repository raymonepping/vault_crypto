# Changelog

## [Unreleased]

### Added

- People and authority (prompt 08): OpenLDAP + Keycloak, Vault `auth/jwt`
  (console) and `auth/ldap` (Vault UI, CLI), four human policies, five
  fictional personas, sign-in in the console, per-room authority from
  `sys/capabilities-self`. The API's own identity no longer acts in rooms.
- Quantum PKI: "Check the CRL" next to OCSP (`GET /api/pki/crl`), and
  "Revoke this leaf" to watch it land on the CRL (and OCSP, for classic).
- Console redirects plain HTTP on 13501 to HTTPS.
- Console: the sidebar folds to icons (remembered); the house footer
  (signature, motto, verbs, links) closes every page.

- Vault Enterprise 2.2.1 lab on Podman + Make + Terraform: `vault-s`
  (Community, Shamir) auto-unseals `vault-1` through Transit, with a seal
  rotator and seal agent.
- `make probe`: proves every Vault 2.2 call the demo uses against the live
  node and writes `docs/capabilities.md`.
- Terraform `vault-crypto`: a classic EC chain and an ML-DSA chain (module
  `pki-chain`), `pki-pqc-next`, Transit, Transform with four FF1
  transformations. Provider `hashicorp/vault` 5.13.
- `make demo-seed`, `make demo-reset`, `make pki-move` (ML-DSA CA key moved
  under ML-KEM-1024 wrapping), `make license-features`.
- cryptolab API (Node 24, no dependencies) and a React console in Vault
  daylight glass: Quantum PKI, Crypto agility, FF1, Lifecycle.
- Checks: `make verify`, `make api-test`, `make test-unit`, `make test-ui`
  (Playwright journeys and axe WCAG 2.1 AA, desktop and phone),
  `make rotation-test`, `make doctor`.
