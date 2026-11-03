terraform {
  required_version = ">= 1.5.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.13"
    }
  }
  backend "local" {
    path = "../../.secrets/terraform/vault-seal.tfstate"
  }
}

# vault-s, with its root token (lab): exported by scripts/tf.sh.
provider "vault" {}

variable "network_cidr" {
  description = "Subnet of vcry-internal; seal-plane identities may only log in from it"
  type        = string
}

# Bootstrap owns the transit mount, autounseal key, autounseal policy and the
# fallback token. They are NOT managed here so `terraform destroy` can never
# take the seal away from vault-1.

resource "vault_auth_backend" "approle" {
  type        = "approle"
  path        = "approle"
  description = "Seal-plane machine identities (rotator, seal agent)"
  tune {
    default_lease_ttl = "1h"
    max_lease_ttl     = "2160h"
  }
}

resource "vault_approle_auth_backend_role" "seal_autounseal" {
  backend        = vault_auth_backend.approle.path
  role_name      = "seal-autounseal"
  token_policies = ["autounseal"]
  # Periodic: lives as long as something renews it.
  token_period          = 86400
  secret_id_ttl         = 7776000 # 90 days; rotated at 1/3 life
  token_bound_cidrs     = [var.network_cidr]
  secret_id_bound_cidrs = [var.network_cidr]
}

resource "vault_policy" "seal_rotator" {
  name   = "seal-rotator"
  policy = <<-EOT
    path "auth/approle/role/${vault_approle_auth_backend_role.seal_autounseal.role_name}/role-id" {
      capabilities = ["read"]
    }
    path "auth/approle/role/${vault_approle_auth_backend_role.seal_autounseal.role_name}/secret-id" {
      capabilities = ["create", "update"]
    }
    path "auth/approle/role/${vault_approle_auth_backend_role.seal_autounseal.role_name}/secret-id/lookup" {
      capabilities = ["create", "update"]
    }
    path "auth/approle/role/${vault_approle_auth_backend_role.seal_autounseal.role_name}/secret-id-accessor/destroy" {
      capabilities = ["create", "update"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "seal_rotator" {
  backend               = vault_auth_backend.approle.path
  role_name             = "seal-rotator"
  token_policies        = [vault_policy.seal_rotator.name]
  token_ttl             = 300
  token_max_ttl         = 600
  secret_id_ttl         = 0
  token_bound_cidrs     = [var.network_cidr]
  secret_id_bound_cidrs = [var.network_cidr]
}
