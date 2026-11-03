# Operations

## First run

```bash
make env-init && make license   # VAULT_LICENSE in .env: the string or a path
make bootstrap                  # check, certs, vaults, probe, terraform, demo state, app, verify
make e2e-install && make test-ui
```

## Daily

| Task | Command |
| --- | --- |
| Start after a reboot | `make up` (unseals vault-s for you) |
| Stop, keep everything | `make down` |
| Status | `make status`, `make vault-status`, `make agents-status` |
| Something is wrong | `make doctor` |
| Tokens look expired after sleep | `make clock-sync` |
| Clean demo | `make demo-reset` (type RESET) |
| Show the CA key move | `make pki-move`, then refresh the card in Quantum PKI |
| Sign in | `make identity-copy-password U=olga` (or vera, piet, kees, dana), then Sign in at the console |
| A persona's new password | `./scripts/identity-secrets.sh --rotate-user vera && make identity-bootstrap` |
| Check who may do what | `make identity-verify` |
| Vault CLI as a person | `eval "$(make vault-login)"; vault login -method=ldap username=piet` |
| Trust the console in the browser | `make trust-root` (sudo, macOS keychain) |
| After editing `api/` or `web/` | `make app-rebuild` (or `TARGETS=api` / `TARGETS=web` for one) |
| Measure load | see `docs/optimization.md` (`VCRY_STATS=1`, `api/scripts/bench.js`) |
| After editing `terraform/` | `make tf-all`, then `make tf-plan-all` |
| After upgrading Vault | change `config/defaults.env`, `make vault-recreate`, then `make probe` and read the diff of `docs/capabilities.md` |

## Recover

| Symptom | Fix |
| --- | --- |
| vault-1 restarts in a loop at boot | vault-s is sealed or down: `make vault-up` |
| `make doctor`: seal token REJECTED | `make vault-recreate` |
| The rotator's own credential rejected | `make agents-recover` |
| API answers 503 | `make agents-status`; the agent's token is missing |
| Rooms say "Sign in" after signing in | the Vault token could not be issued: `make identity-verify`, `make tf-identity` |
| Keycloak login page does not load | `make identity-up` (Keycloak on 13502) |
| Overlay "input/output error" on every `podman run` | the Mac disk filled up; free space, then `podman machine ssh 'sync -f ~/.local/share/containers/storage/overlay'` once (see `docs/STATE.md`) |

## Back up and start over

```bash
make backup        # Raft snapshots of both nodes + .secrets into backups/<UTC time>/
make clean-slate   # type DELETE: removes vcry- containers and volumes, moves credentials aside
make bootstrap
```

`make down` never removes volumes. Only `make clean-slate` does.
