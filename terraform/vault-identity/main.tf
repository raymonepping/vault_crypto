terraform {
  required_version = ">= 1.5.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.13"
    }
  }
  backend "local" {
    path = "../../.secrets/terraform/vault-identity.tfstate"
  }
}

# vault-1 ENT, with its root token: exported by scripts/tf.sh.
provider "vault" {}

# Who may do what (prompt 08). People, not the application, hold authority:
#
#   console  Keycloak access token → auth/jwt role `console` → external groups
#            (one per Keycloak group) → human-* policies
#   Vault UI auth/ldap against the same directory → the same policies
#   and CLI
#
# Needs the identity stack up (make identity-up): Vault checks jwks_url when
# the jwt mount is configured.

variable "keycloak_jwks_url" {
  description = "JWKS endpoint as vault-1 reaches it (vcry-internal)"
  type        = string
  default     = "http://keycloak:8080/realms/vcry/protocol/openid-connect/certs"
}

variable "keycloak_issuer" {
  description = "Issuer in the realm's tokens (the browser-facing URL)"
  type        = string
  default     = "http://localhost:13502/realms/vcry"
}

locals {
  # Keycloak/LDAP group → Vault policy
  groups = {
    "vcry-viewers"        = "vcry-viewer"
    "vcry-pki-operators"  = "vcry-pki-operator"
    "vcry-key-custodians" = "vcry-key-custodian"
    "vcry-data-stewards"  = "vcry-data-steward"
  }
  policy_files = {
    "vcry-viewer"        = "human-viewer.hcl"
    "vcry-pki-operator"  = "human-pki-operator.hcl"
    "vcry-key-custodian" = "human-key-custodian.hcl"
    "vcry-data-steward"  = "human-data-steward.hcl"
  }
}

resource "vault_policy" "human" {
  for_each = local.policy_files
  name     = each.key
  policy   = file("${path.module}/../../vault/policies/${each.value}")
}

# ── Console: Keycloak tokens, verified by Vault itself ───────────────────────
resource "vault_jwt_auth_backend" "keycloak" {
  path         = "jwt"
  type         = "jwt"
  description  = "People signed in to the console (Keycloak realm vcry)"
  jwks_url     = var.keycloak_jwks_url
  bound_issuer = var.keycloak_issuer
}

resource "vault_jwt_auth_backend_role" "console" {
  backend         = vault_jwt_auth_backend.keycloak.path
  role_name       = "console"
  role_type       = "jwt"
  bound_audiences = ["vcry-console"]
  user_claim      = "preferred_username"
  groups_claim    = "groups"
  claim_mappings = {
    preferred_username = "username"
    email              = "email"
  }
  # Authority comes from the external groups below, not from the role.
  token_policies = ["default"]
  token_ttl      = 900
  token_max_ttl  = 3600
  token_type     = "service"
}

resource "vault_identity_group" "keycloak" {
  for_each = local.groups
  name     = "kc-${each.key}"
  type     = "external"
  policies = [vault_policy.human[each.value].name]
  metadata = { source = "keycloak realm vcry, LDAP group ${each.key}" }
}

resource "vault_identity_group_alias" "keycloak" {
  for_each       = local.groups
  name           = each.key
  mount_accessor = vault_jwt_auth_backend.keycloak.accessor
  canonical_id   = vault_identity_group.keycloak[each.key].id
}

# ── Vault UI and CLI: the same directory over LDAP ───────────────────────────
# Ephemeral read + write-only attribute: the bind password never enters
# Terraform state. Bump bindpass_wo_version after rotating it in KV.
ephemeral "vault_kv_secret_v2" "ldap_admin" {
  mount = "kv"
  name  = "vcry/identity/ldap-admin-password"
}

resource "vault_ldap_auth_backend" "ldap" {
  path                = "ldap"
  description         = "People in dc=vcry,dc=local (Vault UI, vault login -method=ldap)"
  url                 = "ldap://openldap:389"
  userdn              = "ou=people,dc=vcry,dc=local"
  userattr            = "uid"
  groupdn             = "ou=groups,dc=vcry,dc=local"
  groupfilter         = "(&(objectClass=groupOfNames)(member={{.UserDN}}))"
  groupattr           = "cn"
  binddn              = "cn=admin,dc=vcry,dc=local"
  bindpass_wo         = ephemeral.vault_kv_secret_v2.ldap_admin.data["value"]
  bindpass_wo_version = 1
  token_ttl           = 3600
  token_max_ttl       = 28800
}

resource "vault_ldap_auth_backend_group" "group" {
  for_each  = local.groups
  backend   = vault_ldap_auth_backend.ldap.path
  groupname = each.key
  policies  = [vault_policy.human[each.value].name]
}

output "policies" {
  value = { for g, p in local.groups : g => p }
}
