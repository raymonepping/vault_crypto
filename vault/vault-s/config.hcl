# vault-s — the Transit auto-unseal provider. Shamir seal (1-of-1): it is the
# one node a human (or `make unseal`) unseals after every cold start.
# Runs Vault OSS; holds only the Transit autounseal key. No app secrets here.
ui            = false
disable_mlock = true

api_addr     = "https://vault-s:8200"
cluster_addr = "https://vault-s:8201"

default_lease_ttl = "1h"
max_lease_ttl     = "2160h"

listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/vault/config/tls/vault.crt"
  tls_key_file    = "/vault/config/tls/vault.key"
  tls_min_version = "tls13"
}

storage "raft" {
  path    = "/vault/file"
  node_id = "vault-s"
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
