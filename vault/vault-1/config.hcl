# vault-1 — the application Vault. Runs Vault Enterprise 2.2.1. Auto-unseals
# through vault-s's Transit key. Hosts the four demo rooms: the classic and
# ML-DSA PKI chains, Transit (crypto agility) and Transform (FF1).
ui            = true
disable_mlock = true

api_addr     = "https://vault-1:8200"
cluster_addr = "https://vault-1:8201"

default_lease_ttl = "1h"
max_lease_ttl     = "24h"

# The token is not here: scripts/vault-server.sh exports VAULT_TOKEN from
# the file mounted at runtime (seal agent sink preferred, bootstrap fallback).
seal "transit" {
  address     = "https://vault-s:8200"
  key_name    = "autounseal"
  mount_path  = "transit/"
  tls_ca_cert = "/vault/config/tls/ca-chain.pem"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/vault/config/tls/vault.crt"
  tls_key_file    = "/vault/config/tls/vault.key"
  tls_min_version = "tls13"
}

storage "raft" {
  path    = "/vault/file"
  node_id = "vault-1"
}

log_level = "warn"

# AppRole user lockout, bounded. Vault's default locks a role-id for 15
# minutes after 5 failed logins. Every identity here is a machine whose
# secret-id a rotator replaces within 60s of Vault rejecting it, so the
# default would turn that gap into a 15-minute outage (vault_goldie_locks,
# 2026-10-05). Secret-ids are random UUIDs bound to the vcry-internal subnet;
# 30s still stops guessing.
user_lockout "approle" {
  lockout_threshold     = 5
  lockout_duration      = "30s"
  lockout_counter_reset = "30s"
}
