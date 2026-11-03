# modules/pki-chain — one two-tier CA hierarchy, generated inside Vault.
#
#   <name>-root   self-signed root, signs intermediates only
#   └─ <name>-int intermediate, issues every leaf (path length 0)
#
# The root key is generated inside the root mount and never leaves it; the
# intermediate's key is generated inside its mount and signed over the API.
# No key material passes through Terraform state. Used twice by
# terraform/vault-crypto: once classic (EC), once post-quantum (ML-DSA).

terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
  }
}

variable "name" {
  description = "Mount prefix: pki-<name>-root and pki-<name>-int"
  type        = string
}

variable "title" {
  description = "Human name of the chain, used in the CA common names"
  type        = string
}

variable "organization" {
  type    = string
  default = "Vault Crypto Lab"
}

variable "root_key" {
  description = "Root key: key_type, key_bits (EC/RSA) and parameter_set (ML-DSA)"
  type = object({
    key_type      = string
    key_bits      = optional(number, 0)
    parameter_set = optional(string)
  })
}

variable "int_key" {
  description = "Intermediate key: key_type, key_bits (EC/RSA) and parameter_set (ML-DSA)"
  type = object({
    key_type      = string
    key_bits      = optional(number, 0)
    parameter_set = optional(string)
  })
}

variable "ocsp" {
  description = "Run Vault's OCSP responder. Must be false for ML-DSA: Vault answers 500 (docs/capabilities.md)"
  type        = bool
}

variable "vault_url" {
  description = "Base URL other containers use for AIA, CRL and OCSP"
  type        = string
}

locals {
  root_path = "pki-${var.name}-root"
  int_path  = "pki-${var.name}-int"
}

# ── Root CA ──────────────────────────────────────────────────────────────────
resource "vault_mount" "root" {
  path                      = local.root_path
  type                      = "pki"
  description               = "${var.title} Root CA, signs intermediates only"
  default_lease_ttl_seconds = 31536000  # 1 year
  max_lease_ttl_seconds     = 315360000 # 10 years
}

resource "vault_pki_secret_backend_root_cert" "root" {
  backend       = vault_mount.root.path
  type          = "internal"
  common_name   = "${var.title} Root CA"
  organization  = var.organization
  issuer_name   = "${var.name}-root"
  key_name      = "${var.name}-root-key"
  key_type      = var.root_key.key_type
  key_bits      = var.root_key.key_bits
  parameter_set = var.root_key.parameter_set
  ttl           = "87600h"
}

resource "vault_pki_secret_backend_config_urls" "root" {
  backend                 = vault_mount.root.path
  issuing_certificates    = ["${var.vault_url}/v1/${local.root_path}/ca"]
  crl_distribution_points = ["${var.vault_url}/v1/${local.root_path}/crl"]
}

# ── Intermediate CA ──────────────────────────────────────────────────────────
resource "vault_mount" "int" {
  path                      = local.int_path
  type                      = "pki"
  description               = "${var.title} Intermediate CA, issues every leaf"
  default_lease_ttl_seconds = 86400     # 24 h
  max_lease_ttl_seconds     = 157680000 # 5 years
}

resource "vault_pki_secret_backend_intermediate_cert_request" "int" {
  backend       = vault_mount.int.path
  type          = "internal"
  common_name   = "${var.title} Intermediate CA"
  organization  = var.organization
  key_name      = "${var.name}-int-key"
  key_type      = var.int_key.key_type
  key_bits      = var.int_key.key_bits
  parameter_set = var.int_key.parameter_set
}

resource "vault_pki_secret_backend_root_sign_intermediate" "int" {
  backend      = vault_mount.root.path
  issuer_ref   = vault_pki_secret_backend_root_cert.root.issuer_id
  csr          = vault_pki_secret_backend_intermediate_cert_request.int.csr
  common_name  = "${var.title} Intermediate CA"
  organization = var.organization
  ttl          = "43800h"
  # The intermediate signs leaves only; it cannot mint further CAs.
  max_path_length = 0
}

resource "vault_pki_secret_backend_intermediate_set_signed" "int" {
  backend     = vault_mount.int.path
  certificate = "${vault_pki_secret_backend_root_sign_intermediate.int.certificate}\n${vault_pki_secret_backend_root_sign_intermediate.int.issuing_ca}"
}

resource "vault_pki_secret_backend_issuer" "int" {
  backend     = vault_mount.int.path
  issuer_ref  = vault_pki_secret_backend_intermediate_set_signed.int.imported_issuers[0]
  issuer_name = "${var.name}-int"
}

resource "vault_pki_secret_backend_config_issuers" "int" {
  backend                       = vault_mount.int.path
  default                       = vault_pki_secret_backend_issuer.int.issuer_id
  default_follows_latest_issuer = false
}

resource "vault_pki_secret_backend_config_urls" "int" {
  backend                 = vault_mount.int.path
  issuing_certificates    = ["${var.vault_url}/v1/${local.int_path}/ca"]
  crl_distribution_points = ["${var.vault_url}/v1/${local.int_path}/crl"]
  ocsp_servers            = var.ocsp ? ["${var.vault_url}/v1/${local.int_path}/ocsp"] : []
}

# CRL rebuilt on every revocation (auto_rebuild off). The OCSP responder only
# where the issuer's algorithm supports it.
resource "vault_pki_secret_backend_crl_config" "int" {
  backend      = vault_mount.int.path
  expiry       = "72h"
  disable      = false
  ocsp_disable = !var.ocsp
  auto_rebuild = false
}

resource "vault_generic_endpoint" "int_auto_tidy" {
  path                 = "${vault_mount.int.path}/config/auto-tidy"
  ignore_absent_fields = true
  disable_delete       = true
  data_json = jsonencode({
    enabled = true
    # Seconds, as Vault reads them back: a "1h" string shows as drift forever.
    interval_duration  = 3600
    tidy_cert_store    = true
    tidy_revoked_certs = true
    safety_buffer      = 3600
  })
  depends_on = [vault_pki_secret_backend_config_issuers.int]
}

output "root_path" {
  value = vault_mount.root.path
}

output "int_path" {
  value = vault_mount.int.path
}

output "int_issuer_id" {
  value = vault_pki_secret_backend_issuer.int.issuer_id
}

output "root_ca_pem" {
  value = vault_pki_secret_backend_root_cert.root.certificate
}
