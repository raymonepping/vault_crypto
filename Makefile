SHELL := /bin/sh

.DEFAULT_GOAL := help

# First run:  make env-init && make license && make bootstrap
# Daily:      make up / make down   (make up unseals vault-s for you)

# Compose stacks, one project each (vcry-<stack>). See docs/architecture.md.
STACKS  := seal vault identity app publicca
NETWORK := vcry-internal

.PHONY: help check clock-sync status ps volumes network ports-check compose-config env-init license license-status \
	gen-certs certs-reissue certs-status \
	vault-bootstrap unseal seal-up seal-down seal-token-status vault-up vault-down vault-status vault-recreate vault-login \
	license-features probe tf-seal tf-platform tf-crypto tf-identity tf-all tf-plan-all tf-destroy demo-seed demo-reset pki-move pki-move-status publicca-up publicca-down publicca-probe \
	rotator-bootstrap agents-status agents-recover rotate-now rotation-test \
	identity-up identity-down identity-bootstrap identity-verify identity-copy-password app-build app-up app-down app-rebuild open web-cert trust-root untrust-root \
	test-unit api-test e2e-install test-ui test-ui-headed test-ui-report screenshots \
	up down bootstrap verify doctor backup clean-slate \
	$(addsuffix -logs,$(STACKS))

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*## "; printf "vault_crypto — Vault Enterprise 2.2 crypto agility on Podman + Make + Terraform\n"} \
	  /^# ── / {gsub(/─/, ""); gsub(/^# +| +$$/, ""); printf "\n%s\n", $$0} \
	  /^[a-zA-Z0-9_-]+:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nStacks (each has <stack>-logs):\n  %s\n' "$(STACKS)"

# ── Podman ────────────────────────────────────────────────────────────────────

check: ## Verify Podman machine, compose provider, VM clock, memory and host tools
	@./scripts/podman-check.sh

status: ## Show this project's containers and network
	@podman ps -a --filter name=^vcry- --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
	@podman network exists $(NETWORK) && echo '$(NETWORK): present' || echo '$(NETWORK): not created'

ps: ## List this project's containers
	@podman ps -a --filter name=^vcry-

volumes: ## List this project's named volumes and whether a container uses them
	@for v in $$(podman volume ls -q --filter name=^vcry-); do \
		used=$$(podman ps -a --filter volume=$$v --format '{{.Names}}' | tr '\n' ' '); \
		data=$$(podman volume inspect $$v --format '{{index .Labels "io.vcry.data"}}'); \
		printf '  %-40s %-11s %s\n' "$$v" "$${data:+persistent}" "$${used:-(unattached)}"; \
	done

network: ## (changes state) Create the vcry-internal network if absent
	@./scripts/network.sh
	@echo "$(NETWORK): ready"

ports-check: ## Report host ports this stack wants that something else already holds
	@./scripts/ports-check.sh

compose-config: ## Validate every compose.yaml
	@for stack in $(STACKS); do \
		./scripts/compose.sh "$$stack" config --quiet || exit $$?; \
		echo "compose/$$stack/compose.yaml: ok"; \
	done

clock-sync: ## (changes state) Step the Podman VM's clock to the host's (after the Mac slept)
	@./scripts/clock-sync.sh

env-init: ## (changes state) Create .env from .env.example; never overwrites
	@./scripts/env-init.sh

license: ## (changes state) Install the Vault Enterprise licence: make license [LICENSE_FILE=path] [FORCE=1]
	@./scripts/license.sh

license-status: ## Is the Vault Enterprise licence file present? (never prints it)
	@./scripts/license.sh --status

license-features: ## Which licensed features each demo room needs, and whether vault-1 has them (names only)
	@./scripts/license-features.sh

define STACK_LOGS
$(1)-logs: ## Follow $(1) logs
	@./scripts/compose.sh "$(1)" logs -f
endef
$(foreach stack,$(STACKS),$(eval $(call STACK_LOGS,$(stack))))

# ── TLS ───────────────────────────────────────────────────────────────────────

gen-certs: ## (changes state) Create the lab CA and the Vault listener certificate; idempotent
	@./scripts/gen-certs.sh

certs-reissue: ## (changes state) Re-sign the listener certificate and SIGHUP running nodes
	@./scripts/gen-certs.sh --reissue

certs-status: ## Show issuer, expiry and SANs of the listener certificate
	@./scripts/gen-certs.sh --status

# ── Vault ─────────────────────────────────────────────────────────────────────

vault-bootstrap: ## (changes state) Initialize vault-s and vault-1 on fresh volumes; idempotent
	@./scripts/vault-bootstrap.sh

unseal: ## (changes state) Unseal vault-s (idempotent); vault-1 then unseals itself via Transit
	@./scripts/vault-unseal.sh

seal-up: ## (changes state) Start vault-s, unseal it, then the seal rotator and seal agent
	@./scripts/seal-up.sh

seal-down: ## (changes state) Stop the seal stack; running nodes keep serving but cannot restart unsealed
	@./scripts/compose.sh seal stop

seal-token-status: ## Is the seal token vault-1 holds still accepted by vault-s?
	@./scripts/seal-token-status.sh

vault-up: ## (changes state) Cold start: vault-s, unseal, seal agent, then vault-1 (auto-unseal)
	@./scripts/vault-up.sh

vault-down: ## (changes state) Stop vault-1 then the seal stack (containers and volumes are kept)
	@./scripts/compose.sh vault stop 2>/dev/null || true
	@./scripts/compose.sh seal stop 2>/dev/null || true

vault-status: ## Show both Vault nodes: container, init, seal, HA role, Raft index, version
	@./scripts/vault-status.sh

vault-recreate: ## (changes state) Recreate vault-1 on the seal agent's current token (keeps its data)
	@./scripts/vault-recreate.sh

vault-login: ## Print the export line that points your shell's vault CLI at a node: make vault-login NODE=vault-s|vault-1
	@./scripts/vault-login.sh $(or $(NODE),vault-1)

# ── Terraform ─────────────────────────────────────────────────────────────────

probe: ## (changes state, scratch mounts only) Prove every 2.2 API call the rooms use; writes docs/capabilities.md
	@./scripts/probe-2.2.sh

tf-seal: ## (changes state) Apply terraform/vault-seal (vault-s: AppRoles for the seal rotator and seal agent)
	@./scripts/tf.sh vault-seal apply

tf-platform: ## (changes state) Apply terraform/vault-platform (vault-1: AppRoles + policies for the API, tls-agent, rotator)
	@./scripts/tf.sh vault-platform apply

tf-crypto: ## (changes state) Apply terraform/vault-crypto (vault-1: classic + ML-DSA PKI chains, transit, transform)
	@./scripts/tf.sh vault-crypto apply

tf-identity: ## (changes state) Apply terraform/vault-identity (jwt + ldap auth, human policies, groups; needs make identity-up)
	@./scripts/tf.sh vault-identity apply

tf-all: ## (changes state) Every Terraform root in order
	@$(MAKE) --no-print-directory tf-seal
	@$(MAKE) --no-print-directory tf-platform
	@$(MAKE) --no-print-directory tf-crypto
	@$(MAKE) --no-print-directory tf-identity

tf-plan-all: ## Plan every root; fails if any has pending changes
	@for r in vault-seal vault-platform vault-crypto vault-identity; do \
		out=$$(mktemp); code=0; ./scripts/tf.sh $$r plan >$$out 2>&1 || code=$$?; \
		case $$code in \
		0) echo "$$r: No changes." ;; \
		2) echo "$$r: CHANGES PENDING" >&2; grep -E '^  [#~+-]|Plan:' $$out >&2; rm -f $$out; exit 2 ;; \
		*) cat $$out >&2; rm -f $$out; exit $$code ;; \
		esac; rm -f $$out; \
	done

tf-destroy: ## (changes state) Destroy every root in reverse order; type DESTROY to confirm
	@printf 'This removes both PKI hierarchies (all CA keys), transit, transform, AppRoles and policies. Type DESTROY: '; \
		read answer; [ "$$answer" = DESTROY ] || { echo "Aborted."; exit 1; }
	@./scripts/tf.sh vault-identity destroy
	@./scripts/tf.sh vault-crypto destroy
	@./scripts/tf.sh vault-platform destroy
	@./scripts/tf.sh vault-seal destroy

demo-seed: ## (changes state) Create the demo keys, transformations and fixtures (runtime state, not Terraform); create-only
	@./scripts/demo-seed.sh

pki-move: ## (changes state) Operator: move the ML-DSA issuing key to pki-pqc-next, wrapped under ML-KEM-1024
	@./scripts/pki-move.sh

pki-move-status: ## Where the ML-DSA issuing key lives, and the export warning on the source issuer
	@./scripts/pki-move.sh --status

demo-reset: ## (changes state) Put every room back to its starting state (recreates demo keys; type RESET to confirm)
	@./scripts/demo-seed.sh --reset

# ── Identity ──────────────────────────────────────────────────────────────────

rotator-bootstrap: ## (changes state) Deliver the rotators' own credentials (the only ones handed over); idempotent
	@./scripts/rotator-bootstrap.sh

agents-status: ## Every machine identity: rotator, credential, secret-id expiry, agent health, token TTL
	@./scripts/agents-status.sh

agents-recover: ## (changes state) Re-deliver a rotator credential that cannot log in; restart rejected agents
	@./scripts/agents-recover.sh

rotate-now: ## (changes state) Force a secret-id rotation now: make rotate-now PLANE=seal|app ROLE=cryptolab-api|web-tls|seal-autounseal
	@./scripts/rotate-now.sh "$(or $(PLANE),app)" "$(or $(ROLE),cryptolab-api)"

rotation-test: ## (changes state) Self-healing tests: breaks credentials on purpose, every case must heal
	@./scripts/test-rotation.sh

# ── Identity ── people: LDAP + Keycloak (prompt 08) ──────────────────────────

identity-up: ## (changes state) Start OpenLDAP + Keycloak (secrets from Vault KV, created once)
	@./scripts/identity-up.sh

identity-down: ## (changes state) Stop the identity stack; directory and realm are kept
	@./scripts/compose.sh identity stop

identity-bootstrap: ## (changes state) Load the directory, set passwords from Vault, configure realm vcry; idempotent
	@./scripts/compose.sh identity --profile init up ldap-bootstrap keycloak-bootstrap
	@./scripts/compose.sh identity --profile init rm -f ldap-bootstrap keycloak-bootstrap >/dev/null

identity-verify: ## Every persona: Keycloak groups, Vault policies (jwt and LDAP), allowed and refused actions
	@./scripts/identity-verify.sh

identity-copy-password: ## Put a persona's password on the clipboard (never printed): make identity-copy-password U=vera|piet|kees|dana|olga
	@./scripts/identity-secrets.sh --copy "$(or $(U),olga)"

# ── App ───────────────────────────────────────────────────────────────────────

app-build: ## (changes state) Build the api and web images: make app-build [TARGETS="api web"]
	@./scripts/app-build.sh $(TARGETS)

app-up: ## (changes state) Start the rotator, both agents, api and web (builds if missing)
	@./scripts/app-up.sh

app-down: ## (changes state) Stop the app stack
	@./scripts/compose.sh app stop

app-rebuild: ## (changes state) Rebuild images and recreate those services: make app-rebuild [TARGETS="api web"]
	@./scripts/app-build.sh $(TARGETS)
	@./scripts/compose.sh app up -d --force-recreate $(or $(TARGETS),api web)

open: ## Print the UI, API and Vault addresses
	@bash -c '. ./scripts/common.sh && \
		echo "vault_crypto UI:  https://localhost:$$(vcry_conf VCRY_PORT_WEB)/" && \
		echo "cryptolab API:    http://127.0.0.1:$$(vcry_conf VCRY_PORT_API)/api/health" && \
		echo "Vault ENT UI:     https://localhost:$$(vcry_conf VCRY_PORT_VAULT_1)/ui" && \
		echo "Vault seal:       https://localhost:$$(vcry_conf VCRY_PORT_VAULT_S)"'

web-cert: ## The certificate the web UI presents right now: serial, expiry, chain to pki-classic-root
	@./scripts/web-cert.sh

trust-root: ## (changes state, sudo) Trust Vault's pki-classic-root in the macOS System keychain so browsers accept the UI
	@./scripts/trust-root.sh add

untrust-root: ## (changes state, sudo) Remove pki-classic-root from the macOS System keychain
	@./scripts/trust-root.sh remove

# ── Optional: public CA ───────────────────────────────────────────────────────

publicca-up: ## (changes state) Optional: start Pebble + challtestsrv, a local stand-in for a public ACME CA
	@./scripts/compose.sh publicca up -d

publicca-down: ## (changes state) Stop and remove the Pebble stand-in (it keeps no state)
	@./scripts/compose.sh publicca down

publicca-probe: ## (changes state, scratch mount only) Vault's PKI External CA engine against Pebble; writes docs/publicca-probe.md
	@./scripts/publicca-probe.sh

# ── Lifecycle ─────────────────────────────────────────────────────────────────

up: ## (changes state) Start everything from a stopped machine: vault (with unseal), identity, app
	@$(MAKE) --no-print-directory vault-up
	@$(MAKE) --no-print-directory identity-up
	@$(MAKE) --no-print-directory app-up

down: ## (changes state) Stop app, identity and vault; containers and volumes are kept
	@./scripts/compose.sh app stop 2>/dev/null || true
	@./scripts/compose.sh identity stop 2>/dev/null || true
	@$(MAKE) --no-print-directory vault-down

bootstrap: ## (changes state) First run, from zero to verified. Idempotent
	@./scripts/bootstrap.sh

# ── Tests ─────────────────────────────────────────────────────────────────────

verify: ## End-to-end checks: podman, vault, crypto config, identities, api, web TLS, the four rooms
	@./scripts/verify.sh

test-unit: ## API and console unit tests (node --test; no stack needed)
	@cd api && npm test
	@cd web && npm test

api-test: ## Call every API route against the live stack and check status and shape
	@./scripts/api-test.sh

# Playwright against the live stack; nothing is mocked. The browser trusts
# exactly the pki-classic-int intermediate (SPKI pin), so web certificate
# rotation during a run is fine.
E2E := cd e2e && npx playwright test

e2e-install: ## (changes state) Install Playwright and Chromium for the UI suite
	@cd e2e && npm ci --no-audit --no-fund && npx playwright install chromium

test-ui: ## Playwright: every UI journey, headless (needs make up)
	@$(E2E) --grep-invert "@shots"

test-ui-headed: ## Playwright: every UI journey in a visible browser
	@$(E2E) --grep-invert "@shots" --headed

test-ui-report: ## Open the last Playwright HTML report
	@cd e2e && npx playwright show-report

screenshots: ## Playwright: refresh docs/screenshots (desktop + phone)
	@$(E2E) --grep @shots

# ── Maintenance ───────────────────────────────────────────────────────────────

doctor: ## Explain what is wrong and which command fixes it (read-only)
	@./scripts/doctor.sh

backup: ## (changes state) Raft snapshots of both nodes and .secrets into backups/<timestamp>/
	@./scripts/backup.sh

clean-slate: ## (changes state) DESTRUCTIVE: remove containers and volumes, move credentials aside (backup first; type DELETE)
	@./scripts/clean-slate.sh
