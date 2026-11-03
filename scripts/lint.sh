#!/usr/bin/env bash
# scripts/lint.sh — the static checks, the same on the Mac and in CI (make lint).
#
#   shell      shellcheck at warning level (bash -n / sh -n where it is missing)
#   terraform  fmt -check, and validate per root without a backend, in a
#              temporary data dir: never touches .secrets/ state or a Vault
#
# Read-only. Exit 1 when anything fails.
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
failed=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() {
  printf '  \033[31m✗\033[0m %s\n' "$*"
  failed=1
}

echo "shell"
scripts=()
while IFS= read -r f; do scripts+=("$f"); done < <(git ls-files '*.sh')
if command -v shellcheck >/dev/null 2>&1; then
  if out=$(shellcheck -S warning "${scripts[@]}" 2>&1); then
    ok "shellcheck: ${#scripts[@]} scripts, no warnings"
  else
    printf '%s\n' "$out"
    bad "shellcheck found warnings"
  fi
else
  syntax=0
  for f in "${scripts[@]}"; do
    case "$(head -1 "$f")" in
    *bash*) bash -n "$f" || syntax=1 ;;
    *) sh -n "$f" || syntax=1 ;;
    esac
  done
  [ "$syntax" -eq 0 ] && ok "syntax: ${#scripts[@]} scripts (shellcheck not installed)" || bad "syntax errors"
fi

echo "terraform"
if ! command -v terraform >/dev/null 2>&1; then
  bad "terraform not found"
else
  if terraform fmt -check -recursive terraform >/dev/null; then ok "terraform fmt"; else
    terraform fmt -check -recursive -diff terraform || true
    bad "terraform fmt: run terraform fmt -recursive terraform"
  fi
  data=$(mktemp -d)
  trap 'rm -rf "$data"' EXIT
  for root in terraform/vault-*/; do
    r=$(basename "$root")
    if (cd "$root" && TF_DATA_DIR="$data/$r" terraform init -backend=false -input=false -no-color >/dev/null &&
      TF_DATA_DIR="$data/$r" terraform validate -no-color >/dev/null); then
      ok "terraform validate $r"
    else
      bad "terraform validate $r"
    fi
  done
fi

[ "$failed" -eq 0 ] || exit 1
