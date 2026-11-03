terraform {
  required_version = ">= 1.5.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.13"
    }
  }
  backend "local" {
    path = "../../.secrets/terraform/vault-crypto.tfstate"
  }
}

# vault-1 ENT, with its root token: exported by scripts/tf.sh.
provider "vault" {}

# Configuration of the four demo rooms. Every call here was proven against
# 2.2.1 by `make probe` (docs/capabilities.md).
#
#   Quantum PKI   pki-classic-root (EC P-384) → pki-classic-int (EC P-256)
#                 pki-pqc-root (ML-DSA-87)    → pki-pqc-int (ML-DSA-65)
#                 pki-pqc-next                  empty: target of the CA key move
#   Agility       transit/                      the keys are runtime state (demo-seed)
#   FF1           transform/                    role, templates, FF1 transformations
#
# Not here, on purpose (decision D7): the Transit keys whose algorithm the
# demo changes, and the key/issuer the CA move imports into pki-pqc-next.
# Terraform would plan them back. scripts/demo-seed.sh owns them.

variable "vault_url" {
  description = "Base URL other containers use for AIA, CRL and OCSP"
  type        = string
  default     = "https://vault-1:8200"
}

variable "web_cn" {
  description = "Common name of the web server's certificate (config/defaults.env VCRY_WEB_CN)"
  type        = string
  default     = "crypto.localhost"
}

# ── Quantum PKI: two chains side by side ─────────────────────────────────────
module "classic" {
  source    = "../modules/pki-chain"
  name      = "classic"
  title     = "Vault Crypto Lab Classic"
  root_key  = { key_type = "ec", key_bits = 384 }
  int_key   = { key_type = "ec", key_bits = 256 }
  ocsp      = true
  vault_url = var.vault_url
}

module "pqc" {
  source = "../modules/pki-chain"
  name   = "pqc"
  title  = "Vault Crypto Lab ML-DSA"
  # FIPS 204 security categories: 87 ≈ 5 (root, long-lived), 65 ≈ 3, 44 ≈ 2.
  root_key = { key_type = "ml-dsa", parameter_set = "ml-dsa-87" }
  int_key  = { key_type = "ml-dsa", parameter_set = "ml-dsa-65" }
  # Vault 2.2.1 answers OCSP for an ML-DSA issuer with 500 internalerror, as
  # documented ("ML-DSA backed CAs are not supported"). The CRL works.
  ocsp      = false
  vault_url = var.vault_url
}

# The UI's own certificate (tls-agent). Classic: browsers do not accept
# ML-DSA certificate signatures yet.
resource "vault_pki_secret_backend_role" "web" {
  backend            = module.classic.int_path
  name               = "web"
  issuer_ref         = module.classic.int_issuer_id
  allowed_domains    = ["localhost", "vcry-web"]
  allow_subdomains   = true
  allow_bare_domains = true
  allow_localhost    = true
  allow_ip_sans      = true
  server_flag        = true
  client_flag        = false
  key_type           = "ec"
  key_bits           = 256
  ttl                = "86400"  # 24 h
  max_ttl            = "259200" # 72 h
  organization       = ["Vault Crypto Lab"]
  ou                 = ["web"]
}

# The two leaf roles the Quantum PKI room issues from: same names, same TTLs,
# only the algorithm differs, so the comparison is fair.
resource "vault_pki_secret_backend_role" "service_classic" {
  backend          = module.classic.int_path
  name             = "service"
  issuer_ref       = module.classic.int_issuer_id
  allowed_domains  = ["lab.local"]
  allow_subdomains = true
  server_flag      = true
  client_flag      = true
  key_type         = "ec"
  key_bits         = 256
  ttl              = "3600"  # 1 h
  max_ttl          = "86400" # 24 h
  organization     = ["Vault Crypto Lab"]
  ou               = ["classic"]
}

resource "vault_pki_secret_backend_role" "service_pqc" {
  backend          = module.pqc.int_path
  name             = "service"
  issuer_ref       = module.pqc.int_issuer_id
  allowed_domains  = ["lab.local"]
  allow_subdomains = true
  server_flag      = true
  client_flag      = true
  key_type         = "ml-dsa"
  parameter_set    = "ml-dsa-44"
  ttl              = "3600"  # 1 h
  max_ttl          = "86400" # 24 h
  organization     = ["Vault Crypto Lab"]
  ou               = ["post-quantum"]
}

# Target of the CA key move (Vault Enterprise: export wrapped under an
# ML-KEM-1024 export key, import with wrapped_key + export_key_hmac). The
# mount is configuration; what gets imported into it is runtime state.
resource "vault_mount" "pqc_next" {
  path                      = "pki-pqc-next"
  type                      = "pki"
  description               = "Receives the ML-DSA issuing key, wrapped, during the CA move demo"
  default_lease_ttl_seconds = 86400
  max_lease_ttl_seconds     = 157680000
}

# ── Crypto agility: the Transit mount ────────────────────────────────────────
resource "vault_mount" "transit" {
  path        = "transit"
  type        = "transit"
  description = "Crypto agility: keys that change algorithm under the same name"
}

# ── Format-preserving encryption: FF1 ────────────────────────────────────────
resource "vault_mount" "transform" {
  path        = "transform"
  type        = "transform"
  description = "FF1 format-preserving encryption (Transform, ADP)"
}

locals {
  transformations = ["ccn-legacy", "ccn-2026", "iban-ff1", "bsn-ff1"]
}

resource "vault_transform_role" "payments" {
  path            = vault_mount.transform.path
  name            = "payments"
  transformations = local.transformations
}

# A Dutch IBAN keeps NLkk and the bank code; FF1 encrypts the 10-digit
# account number. The check digits are not recomputed: the encoded value has
# the IBAN's shape, not a valid mod-97.
resource "vault_transform_template" "nl_iban" {
  path     = vault_mount.transform.path
  name     = "nl-iban"
  type     = "regex"
  pattern  = "NL\\d{2}[A-Z]{4}(\\d{10})"
  alphabet = "builtin/numeric"
}

# Burgerservicenummer: nine digits.
resource "vault_transform_template" "nl_bsn" {
  path     = vault_mount.transform.path
  name     = "nl-bsn"
  type     = "regex"
  pattern  = "(\\d{9})"
  alphabet = "builtin/numeric"
}

# On 2.2 every new FPE transformation is FF1 and FF3-1 cannot be created
# (the probe's fpe_algorithm=ff3-1 was ignored). ccn-legacy and ccn-2026 are
# two FF1 transformations with different keys: the rewrap demo moves values
# from one to the other, the same call that migrates FF3-1 data to FF1.
resource "vault_transform_transformation" "ccn_legacy" {
  path          = vault_mount.transform.path
  name          = "ccn-legacy"
  type          = "fpe"
  template      = "builtin/creditcardnumber"
  tweak_source  = "internal"
  allowed_roles = [vault_transform_role.payments.name]
}

resource "vault_transform_transformation" "ccn_2026" {
  path          = vault_mount.transform.path
  name          = "ccn-2026"
  type          = "fpe"
  template      = "builtin/creditcardnumber"
  tweak_source  = "internal"
  allowed_roles = [vault_transform_role.payments.name]
}

resource "vault_transform_transformation" "iban" {
  path          = vault_mount.transform.path
  name          = "iban-ff1"
  type          = "fpe"
  template      = vault_transform_template.nl_iban.name
  tweak_source  = "internal"
  allowed_roles = [vault_transform_role.payments.name]
}

resource "vault_transform_transformation" "bsn" {
  path          = vault_mount.transform.path
  name          = "bsn-ff1"
  type          = "fpe"
  template      = vault_transform_template.nl_bsn.name
  tweak_source  = "internal"
  allowed_roles = [vault_transform_role.payments.name]
}

output "classic_root_ca_pem" {
  value = module.classic.root_ca_pem
}

output "pqc_root_ca_pem" {
  value = module.pqc.root_ca_pem
}

output "web_cn" {
  value = var.web_cn
}
