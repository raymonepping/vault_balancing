SHELL := /bin/sh

.DEFAULT_GOAL := help

# Terraform builds the house. Ansible decorates it. Vault keeps the keys.
# Make is the front door.
#
# First run:  make env-init && make license && make gen-certs && make lab
# Daily:      make up / make down / make show-ready
# The drill:  make drill (or one act at a time, see "Drill")

SITES    := ams fra dub
STACKS   := $(SITES) frontdoor identity app
NETWORK  := vbal-internal
TF_ROOTS := $(addprefix seal-,$(SITES)) platform

# run <script> [args]: a target whose script a later prompt adds says so.
define run
	@if [ -x ./scripts/$(firstword $(1)) ]; then ./scripts/$(1); \
	else echo "$(firstword $(1)) is not built yet (see prompts/)." >&2; exit 2; fi
endef

# need VAR: stop with a usage line when a required variable is empty.
need = @if [ -z "$($(1))" ]; then echo "Usage: make $@ $(1)=<value>" >&2; exit 64; fi

.PHONY: help check clock-sync status ps volumes network ports-check compose-config env-init license license-status license-features \
	gen-certs certs-reissue certs-status trust-root untrust-root sites-check \
	lab phases seals-up seal-init tf-seal-all seal-tokens sites-up bootstrap tf-platform replicate paths-filter frontdoor-up identity-up app-up runner-up runner-down runner-status validate \
	site-start-followers unseal vault-status vault-cli seal-token-status seal-token-rotate root-regen root-revoke \
	tf-plan-all boundary idempotency drift secret-scan layers probe \
	frontdoor-status ticker-status dr-token \
	drill site-down site-up promote repoint fence unfence demote failback report drill-runs site-destroy \
	app-build app-down app-rebuild web-up open \
	up down verify lint test-unit test-ui test-ui-drill test-ui-drill-clicks test-ui-headed test-ui-report screenshots e2e-install \
	rehearsal doctor show-ready audit-rotate backup clean-slate $(addsuffix -logs,$(STACKS))

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*## "; printf "vault_balancing: When a Site Dies, a Vault Enterprise 2.2 region failover drill (Make + Terraform + Ansible)\n"} \
	  /^# ── / {gsub(/─/, ""); gsub(/^# +| +$$/, ""); printf "\n%s\n", $$0} \
	  /^[a-zA-Z0-9_-]+:.*## / {printf "  %-24s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nStacks (each has <stack>-logs):\n  %s\n' "$(STACKS)"

# ── Podman ────────────────────────────────────────────────────────────────────

check: ## Verify Podman machine, compose provider, VM clock, memory and host tools
	@./scripts/podman-check.sh

status: ## Show this project's containers and network
	@podman ps -a --filter name=^vbal- --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
	@podman network exists $(NETWORK) && echo '$(NETWORK): present' || echo '$(NETWORK): not created'

ps: ## List this project's containers
	@podman ps -a --filter name=^vbal-

volumes: ## List this project's named volumes and whether a container uses them
	@for v in $$(podman volume ls -q --filter name=^vbal-); do \
		used=$$(podman ps -a --filter volume=$$v --format '{{.Names}}' | tr '\n' ' '); \
		data=$$(podman volume inspect $$v --format '{{index .Labels "io.vbal.data"}}'); \
		printf '  %-40s %-11s %s\n' "$$v" "$${data:+persistent}" "$${used:-(unattached)}"; \
	done

network: ## (changes state) Create the vbal-internal network if absent
	@./scripts/network.sh
	@echo "$(NETWORK): ready"

ports-check: ## Report host ports this stack wants that something else already holds
	@./scripts/ports-check.sh

compose-config: ## Validate every compose file (each site stack renders compose/site)
	@for stack in $(STACKS); do \
		./scripts/compose.sh "$$stack" config --quiet 2>/dev/null && echo "$$stack: ok" || echo "$$stack: not built yet or invalid"; \
	done

clock-sync: ## (changes state) Step the Podman VM's clock to the host's (after the Mac slept)
	@./scripts/clock-sync.sh

env-init: ## (changes state) Create .env from .env.example; never overwrites
	@./scripts/env-init.sh

license: ## (changes state) Install the Vault Enterprise licence: make license [LICENSE_FILE=path]
	@./scripts/license.sh

license-status: ## Is the Vault Enterprise licence file present? (never prints it)
	@./scripts/license.sh --status

license-features: ## Phase 7, make: the licensed features the lab needs, read from the primary (names only)
	$(call run,license-features.sh)

sites-check: ## Validate config/sites.json and the ports of every node
	@node scripts/sites.js check

define STACK_LOGS
$(1)-logs: ## Follow $(1) logs
	@./scripts/compose.sh "$(1)" logs -f
endef
$(foreach stack,$(STACKS),$(eval $(call STACK_LOGS,$(stack))))

# ── TLS ───────────────────────────────────────────────────────────────────────

gen-certs: ## (changes state) Create the lab CA and the shared listener certificate; idempotent
	@./scripts/gen-certs.sh

certs-reissue: ## (changes state) Re-sign the listener certificate and SIGHUP running nodes
	@./scripts/gen-certs.sh --reissue

certs-status: ## Show issuer, expiry and SANs of the listener certificate
	@./scripts/gen-certs.sh --status

trust-root: ## (changes state, sudo) Trust the lab CA in the macOS System keychain so browsers accept the console
	$(call run,trust-root.sh add)

untrust-root: ## (changes state, sudo) Remove the lab CA from the macOS System keychain
	$(call run,trust-root.sh remove)

# ── Lab: the phases of scripts/phases.txt ─────────────────────────────────────

lab: ## (changes state) Every phase in order, then the gates and the convergence record; idempotent
	$(call run,lab.sh)

phases: ## List the phases in run order with their tool
	@grep -vE '^(#|$$)' scripts/phases.txt

seals-up: ## (changes state) Phase 1, make: the network and the three seal Vaults
	$(call run,seals-up.sh)

seal-init: ## (changes state) Phase 2, ansible: init and unseal each seal Vault, its scoped tokens, revoke root
	$(call run,ansible.sh seal-init)

tf-seal-all: ## (changes state) Phase 3, tf: Transit key, token role and audit on every seal Vault
	@for s in $(SITES); do ./scripts/tf.sh seal-$$s apply || exit $$?; done

seal-tokens: ## (changes state) Phase 4, ansible: one seal token per node of each site
	$(call run,ansible.sh seal-tokens)

sites-up: ## (changes state) Phase 5, make: each site's seal Vault unsealed, then its nodes (secondaries: node 1 until activated)
	$(call run,sites-up.sh)

bootstrap: ## (changes state) Phase 6, ansible: init ams fully (policies, scoped tokens, revoke root); fra and dub node 1 only
	$(call run,ansible.sh bootstrap)

tf-platform: ## (changes state) Phase 8, tf: namespaces, mounts, AppRole, policies, audit, paths filter on the primary
	$(call run,tf.sh platform apply)

replicate: ## (changes state) Phase 9, ansible: primary roles, activate fra and dub, the DR operation token
	$(call run,ansible.sh replicate)

paths-filter: ## (changes state) Phase 10, make: tf platform again, now that Frankfurt's activation id exists (the paths filter)
	$(call run,tf.sh platform apply)

frontdoor-up: ## (changes state) Phase 11, make: render haproxy.cfg and start the front door
	$(call run,frontdoor-up.sh)

identity-up: ## (changes state) Phase 12, make: OpenLDAP and Keycloak (outside the sites, D15), directory and realm loaded
	$(call run,identity-up.sh)

runner-up: ## (changes state) Phase 14, make: the host-side drill runner the console's buttons use (127.0.0.1, D16)
	$(call run,runner.sh up)

runner-down: ## (changes state) Stop the drill runner (the console's buttons stop working; the terminal still does)
	$(call run,runner.sh down)

runner-status: ## Is the drill runner running?
	$(call run,runner.sh status)

app-up: ## (changes state) Phase 13, make: the ticker and its agent, the API and the situation room (builds missing images)
	$(call run,app-up.sh ticker api web)

validate: ## Phase 15, ansible: every site's role, streaming, the front door, the ticker, the DR token
	$(call run,ansible.sh validate)

# ── Gates ─────────────────────────────────────────────────────────────────────

boundary: ## Each scoped token may do its own job and nothing else (sys/capabilities-self)
	$(call run,boundary-check.sh)

idempotency: ## Every Ansible phase again: changed=0 (exceptions in scripts/idempotency-allow.txt)
	$(call run,idempotency.sh)

drift: ## Out-of-band change per root, plan sees it, apply restores it, plan empty again
	$(call run,drift.sh --prove)

secret-scan: ## Known secret values and secret-shaped patterns in state, .build/ and logs (names only)
	$(call run,secret-scan.sh)

tf-plan-all: ## Plan every Terraform root; fails if any has pending changes
	@for r in $(TF_ROOTS); do \
		case $$r in seal-*) d=seal ;; *) d=$$r ;; esac; \
		[ -f terraform/$$d/versions.tf ] || { echo "$$r: not built yet"; continue; }; \
		out=$$(mktemp); code=0; ./scripts/tf.sh $$r plan -no-color >$$out 2>&1 || code=$$?; \
		case $$code in \
		0) echo "$$r: No changes." ;; \
		2) echo "$$r: CHANGES PENDING" >&2; grep -E '^  [#~+-]|Plan:' $$out >&2; rm -f $$out; exit 2 ;; \
		*) cat $$out >&2; rm -f $$out; exit $$code ;; \
		esac; rm -f $$out; \
	done

layers: ## Write .build/layers.json: every phase with its tool and evidence, and the gates
	$(call run,layers.sh)

probe: ## (changes state, scratch clusters only) Prove every replication move; writes docs/capabilities.md
	$(call run,probe.sh)

# ── Vault ─────────────────────────────────────────────────────────────────────

site-start-followers: ## (changes state) Start nodes 2 and 3 of an activated secondary: make site-start-followers SITE=fra
	$(call need,SITE)
	$(call run,sites-up.sh --followers $(SITE))

unseal: ## (changes state) Unseal a site's seal Vault (idempotent): make unseal SITE=ams
	$(call need,SITE)
	$(call run,vault-unseal.sh $(SITE))

vault-status: ## Every Vault: site, node, container, init, seal, HA role, replication mode, version
	$(call run,vault-status.sh)

vault-cli: ## Run a vault command on the primary with the Ansible token: make vault-cli CMD="namespace list"
	$(call need,CMD)
	$(call run,vault-cli.sh $(CMD))

seal-token-status: ## Each node's seal token: accessor fingerprint, TTL, accepted by its seal Vault
	$(call run,seal-token-status.sh)

seal-token-rotate: ## (changes state) Replace one node's seal token and recreate only that node: make seal-token-rotate NODE=vault-ams-2
	$(call need,NODE)
	$(call run,seal-token-rotate.sh $(NODE))

root-regen: ## (changes state) Generate a root token from the saved key, only when you ask: make root-regen CLUSTER=seal-ams|primary
	$(call run,root-regen.sh $(or $(CLUSTER),primary))

root-revoke: ## (changes state) Revoke and delete a regenerated root token: make root-revoke CLUSTER=seal-ams|primary
	$(call run,root-regen.sh --revoke $(or $(CLUSTER),primary))

frontdoor-status: ## Each HAProxy backend server: state and the last health check code
	$(call run,frontdoor-status.sh)

ticker-status: ## The ticker: last acknowledged write, failures, latency, regional lag
	$(call run,ticker.sh status)

dr-token: ## (changes state) Mint a DR operation token on the current primary if missing or under 4h left
	$(call run,ansible.sh dr-token)

# ── Drill ─────────────────────────────────────────────────────────────────────

drill: ## (changes state) The whole night, act by act, with a pause between acts (DRILL_AUTO=1 skips them)
	$(call run,drill.sh)

site-down: ## (changes state) Act I: stop a whole site, seal Vault included: make site-down SITE=ams
	$(call need,SITE)
	$(call run,ansible.sh site-down -e site=$(SITE))

promote: ## (changes state) Act II: promote the DR secondary with the DR operation token: make promote SITE=dub
	$(call need,SITE)
	$(call run,ansible.sh promote -e site=$(SITE))

repoint: ## (changes state) Act III: point the performance secondary at the new primary: make repoint SITE=fra TO=dub
	$(call need,SITE)
	$(call need,TO)
	@./scripts/tf.sh platform apply -no-color >/dev/null && echo "repoint: paths filters declared on the active primary (tf platform, gotcha 28)"
	$(call run,ansible.sh repoint -e site=$(SITE) -e to=$(TO))
	@./scripts/tf.sh platform apply -no-color >/dev/null && echo "repoint: paths filter window moved with Frankfurt's activation id"

fence: ## (changes state) Act IV: keep a site out of the front door, durably: make fence SITE=ams
	$(call need,SITE)
	$(call run,ansible.sh fence -e site=$(SITE) -e fence=true)

unfence: ## (changes state) Let a fenced site back into the front door: make unfence SITE=ams
	$(call need,SITE)
	$(call run,ansible.sh fence -e site=$(SITE) -e fence=false)

site-up: ## (changes state) Start a stopped site; refuses an ex-primary that is not fenced: make site-up SITE=ams
	$(call need,SITE)
	$(call run,ansible.sh site-up -e site=$(SITE))

demote: ## (changes state) Act IV: demote the old primary and re-attach it as DR secondary: make demote SITE=ams TO=dub
	$(call need,SITE)
	$(call need,TO)
	$(call run,ansible.sh demote -e site=$(SITE) -e to=$(TO))

failback: ## (changes state) Act V: planned failback to the bootstrap roles, Frankfurt home, zero writes lost
	$(call run,ansible.sh failback)
	@./scripts/tf.sh platform apply -no-color >/dev/null && echo "failback: paths filters declared on the home primary (tf platform, gotcha 28)"
	$(call run,ansible.sh failback-finish)
	@./scripts/tf.sh platform apply -no-color >/dev/null && echo "failback: paths filter window moved with Frankfurt's activation id"

report: ## The epilogue: RTO, RPO and every step with Vault's answer, from the open drill
	$(call run,report.sh)

drill-runs: ## (changes state) Act I and II N times with failback between: make drill-runs N=10
	$(call run,drill-runs.sh $(or $(N),10))

site-destroy: ## (changes state) DESTRUCTIVE: remove a site's containers and volumes (type the site name)
	$(call need,SITE)
	$(call run,site-destroy.sh $(SITE))

# ── App ───────────────────────────────────────────────────────────────────────

app-build: ## (changes state) Build the ticker, api and web images: make app-build [TARGETS="ticker api web"]
	$(call run,app-build.sh $(TARGETS))

app-down: ## (changes state) Stop the app stack
	@./scripts/compose.sh app stop

app-rebuild: ## (changes state) Rebuild images and recreate those services: make app-rebuild [TARGETS="ticker api web"]
	$(call run,app-build.sh $(TARGETS))
	@./scripts/compose.sh app up -d --force-recreate $(TARGETS)

web-up: ## (changes state) Build if needed and start the api and the situation room
	$(call run,app-up.sh api web)

open: ## Print the console, API, front door and Vault addresses
	@bash -c '. ./scripts/common.sh && \
		echo "Situation room:  https://localhost:$$(vbal_conf VBAL_PORT_WEB)/" && \
		echo "API:             https://127.0.0.1:$$(vbal_conf VBAL_PORT_API)/healthz" && \
		echo "Front door:      https://127.0.0.1:$$(vbal_conf VBAL_PORT_FRONTDOOR)/v1/sys/health" && \
		echo "HAProxy stats:   http://127.0.0.1:$$(vbal_conf VBAL_PORT_STATS)/stats" && \
		for s in $$VBAL_SITES; do echo "Vault UI ($$s):  https://localhost:$$(vault_port_of vault-$$s-1)/ui"; done'

# ── Lifecycle ─────────────────────────────────────────────────────────────────

up: ## (changes state) Daily start: clock-sync, each site (seal unsealed first), front door, app, DR token
	$(call run,up.sh)

down: ## (changes state) Stop the runner, app, identity, front door and every site; containers and volumes are kept
	@./scripts/runner.sh down >/dev/null 2>&1 || true
	@./scripts/compose.sh app stop 2>/dev/null || true
	@./scripts/compose.sh identity stop 2>/dev/null || true
	@./scripts/compose.sh frontdoor stop 2>/dev/null || true
	@for s in $(SITES); do ./scripts/compose.sh $$s stop 2>/dev/null || true; done

# ── Tests ─────────────────────────────────────────────────────────────────────

verify: ## End-to-end checks: podman, seals, sites, replication, front door, ticker, api, boundary
	$(call run,verify.sh)

lint: ## Static checks, as in CI: shellcheck, terraform fmt and validate, ansible syntax, node --check
	$(call run,lint.sh)

test-unit: ## Unit tests, no stack needed: sites.js, ticker, api, web
	@node --test scripts/*.test.js
	@if [ -d app/ticker/test ]; then node --test 'app/ticker/test/*.test.js'; fi
	@if [ -d api/test ]; then node --test 'api/test/*.test.js'; fi
	@if [ -f web/package.json ]; then cd web && npm test; fi

# Playwright against the live stack; only the two-primaries state is a fixture.
E2E := cd e2e && npx playwright test

e2e-install: ## (changes state) Install Playwright and Chromium for the UI suite
	@cd e2e && npm ci --no-audit --no-fund && npx playwright install chromium

test-ui: ## Playwright: every UI journey, headless (needs make up)
	@$(E2E) --grep-invert "@shots|@drill"

test-ui-drill: ## (changes state) Playwright: a whole drill (make drill) followed live in the browser
	@$(E2E) --grep "@drill the night"

test-ui-drill-clicks: ## (changes state) Playwright: an operator signs in and presses every drill step in the console
	@$(E2E) --grep @drill-clicks

test-ui-headed: ## Playwright: every UI journey in a visible browser
	@$(E2E) --grep-invert "@shots|@drill" --headed

test-ui-report: ## Open the last Playwright HTML report
	@cd e2e && npx playwright show-report

screenshots: ## Playwright: refresh docs/screenshots (desktop + phone)
	@$(E2E) --grep @shots

# ── Maintenance ───────────────────────────────────────────────────────────────

rehearsal: ## (changes state) The day before: lab idempotent, a whole drill, down/up, UI, secret scan
	$(call run,rehearsal.sh)

doctor: ## Explain what is wrong and which command fixes it (read-only)
	$(call run,doctor.sh)

show-ready: ## (changes state) Before the talk: clock-sync, up, DR token, streaming, console
	$(call run,show-ready.sh)

audit-rotate: ## (changes state) Move each Vault's audit log aside past 64 MB and make Vault reopen it (FORCE=1: every log)
	$(call run,audit-rotate.sh $(if $(FORCE),--force))

backup: ## (changes state) Raft snapshots of every live cluster and seal Vault, and .secrets, into backups/<timestamp>/
	$(call run,backup.sh)

clean-slate: ## (changes state) DESTRUCTIVE: remove vbal- containers and volumes, move credentials aside: make clean-slate CONFIRM=vbal
	$(call run,clean-slate.sh)
