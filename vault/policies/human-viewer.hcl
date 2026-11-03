# vcry-viewer — every person who logs in (LDAP group vcry-viewers). Reads every
# room; verifies signatures. Changes nothing.

# Quantum PKI: hierarchy, roles, the CA move's evidence.
path "pki-classic-root/issuers" { capabilities = ["list"] }
path "pki-classic-root/issuer/*" { capabilities = ["read"] }
path "pki-pqc-root/issuers" { capabilities = ["list"] }
path "pki-pqc-root/issuer/*" { capabilities = ["read"] }
path "pki-classic-int/issuers" { capabilities = ["list"] }
path "pki-classic-int/issuer/*" { capabilities = ["read"] }
path "pki-pqc-int/issuers" { capabilities = ["list"] }
path "pki-pqc-int/issuer/*" { capabilities = ["read"] }
path "pki-pqc-int/key/*" { capabilities = ["read"] }
path "pki-pqc-next/issuers" { capabilities = ["list"] }
path "pki-pqc-next/issuer/*" { capabilities = ["read"] }
path "pki-pqc-next/keys" { capabilities = ["list"] }
path "pki-pqc-next/key/*" { capabilities = ["read"] }
path "pki-pqc-next/export" { capabilities = ["list"] }
path "pki-pqc-next/export/*" { capabilities = ["read"] }
path "pki-classic-int/roles/*" { capabilities = ["read"] }
path "pki-pqc-int/roles/*" { capabilities = ["read"] }

# Lifecycle: inventory and CRL configuration.
path "pki-classic-int/certs" { capabilities = ["list"] }
path "pki-pqc-int/certs" { capabilities = ["list"] }
path "pki-pqc-next/certs" { capabilities = ["list"] }
path "pki-classic-int/certs/revoked" { capabilities = ["list"] }
path "pki-pqc-int/certs/revoked" { capabilities = ["list"] }
path "pki-pqc-next/certs/revoked" { capabilities = ["list"] }
path "pki-classic-int/config/crl" { capabilities = ["read"] }
path "pki-pqc-int/config/crl" { capabilities = ["read"] }

# Crypto agility: read the two demo keys, verify signatures.
path "transit/keys/orders-signing" { capabilities = ["read"] }
path "transit/keys/ledger-data" { capabilities = ["read"] }
path "transit/verify/orders-signing" { capabilities = ["update"] }

# FF1: which algorithm each transformation uses.
path "transform/transformations/fpe/*" { capabilities = ["read"] }
