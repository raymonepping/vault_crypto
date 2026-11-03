#!/usr/bin/env bash
# scripts/tf.sh <root> <plan|apply|destroy|output> [terraform args…]
#
# The only supported way to run Terraform here. Exports vault addresses, the
# CA and a root token. Never echoes the token.
#
# Lab shortcut: the token is the target node's root token from the init file.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

root=${1:?Usage: tf.sh <root> <plan|apply|destroy|output> [args]}
action=${2:?Usage: tf.sh <root> <plan|apply|destroy|output> [args]}
shift 2
dir="$VCRY_ROOT/terraform/$root"
[ -f "$dir/main.tf" ] || {
  echo "tf: unknown root '$root'" >&2
  exit 64
}

case "$root" in
vault-seal)
  vault_node vault-s
  vault_root seal
  ;;
*)
  vault_node vault-1
  vault_root vault
  ;;
esac
export VAULT_ADDR VAULT_CACERT VAULT_TOKEN

# Root-specific inputs.
case "$root" in
vault-seal)
  TF_VAR_network_cidr=$(podman network inspect vcry-internal --format '{{(index .Subnets 0).Subnet}}')
  export TF_VAR_network_cidr
  ;;
vault-platform)
  TF_VAR_network_cidr=$(podman network inspect vcry-internal --format '{{(index .Subnets 0).Subnet}}')
  export TF_VAR_network_cidr
  ;;
vault-crypto)
  # Both CA hierarchies are generated inside Vault; no outside key material
  # goes in. AIA/CRL/OCSP URLs use the in-network hostname.
  TF_VAR_web_cn=$(vcry_conf VCRY_WEB_CN)
  export TF_VAR_web_cn
  ;;
esac

mkdir -p "$VCRY_ROOT/.secrets/terraform"
chmod 700 "$VCRY_ROOT/.secrets/terraform"
cd "$dir"
terraform init -input=false >/dev/null

case "$action" in
plan) terraform plan -input=false -detailed-exitcode "$@" ;;
apply) terraform apply -input=false -auto-approve "$@" ;;
destroy) terraform destroy -input=false -auto-approve "$@" ;;
output) terraform output "$@" ;;
*)
  echo "tf: unknown action '$action'" >&2
  exit 64
  ;;
esac
