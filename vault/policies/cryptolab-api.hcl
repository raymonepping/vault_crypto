# cryptolab-api — the API's own identity on vault-1 (token from vault-agent's
# sink). Since prompt 08 it holds platform facts only: every room action runs
# on a token Vault issued to the signed-in person (auth/jwt, role console).
# A compromised API without a person's session can read these facts and the
# console's client secret, nothing more.

# Overview: licensed features and expiry (not the licence itself).
path "sys/license/status" {
  capabilities = ["read"]
}

# The one read per room behind /api/capabilities ("is it configured?").
path "pki-pqc-int/issuer/default" {
  capabilities = ["read"]
}
path "transit/keys/orders-signing" {
  capabilities = ["read"]
}
path "transform/transformations/fpe/ccn-legacy" {
  capabilities = ["read"]
}

# The console's OIDC client secret (the API is the console's BFF). Only this
# one identity secret: never the LDAP or Keycloak admin passwords.
path "kv/data/vcry/identity/console-client-secret" {
  capabilities = ["read"]
}
