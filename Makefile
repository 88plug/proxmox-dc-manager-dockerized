# Makefile for proxmox-dc-manager-dockerized
# Run `make help` to see available targets.

.DEFAULT_GOAL := help

.PHONY: help build refresh up down restart logs shell init-shell \
        pdm-version set-password scan scan-register \
        lint verify cert-show journalctl backup restore \
        smoke-test clean reset

help: ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# IMAGE_SOURCE_URL is the OCI image.source label — should point at this repo.
# Derived once from the git remote (scp-style git@host:path and ssh:// forms
# are normalized to https). Empty when there is no remote or the form isn't
# recognized — the labels then render empty instead of pointing at a wrong
# URL. Override on the command line to force a value.
ifeq ($(origin IMAGE_SOURCE_URL), undefined)
IMAGE_SOURCE_URL := $(shell git config --get remote.origin.url 2>/dev/null \
	| sed -E 's|^git@([^:/]+):|https://\1/|; s|^ssh://git@([^:/]+)(:[0-9]+)?/|https://\1/|; s|\.git$$||' \
	| grep -E '^https?://' \
	|| true)
endif

build: ## Build the Docker image (extractor stage downloads the ISO automatically).
	DOCKER_BUILDKIT=1 docker compose build \
		--build-arg GIT_REVISION="$$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" \
		--build-arg BUILD_DATE="$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--build-arg IMAGE_SOURCE_URL="$(IMAGE_SOURCE_URL)"

refresh: ## Cache-busted rebuild: re-pulls Debian Trixie security updates and re-runs dist-upgrade.
	DOCKER_BUILDKIT=1 docker compose build --pull --no-cache \
		--build-arg GIT_REVISION="$$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" \
		--build-arg BUILD_DATE="$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--build-arg IMAGE_SOURCE_URL="$(IMAGE_SOURCE_URL)"

up: ## Start container in background.
	docker compose up -d

down: ## Stop & remove container (volumes kept).
	docker compose down

restart: ## Restart container.
	docker compose restart pdm

logs: ## Tail container logs.
	docker compose logs -f --tail=200 pdm

shell: ## Shell into running container.
	docker compose exec pdm bash

init-shell: ## Shell into a freshly-built image (debug).
	docker compose run --rm --entrypoint bash pdm

pdm-version: ## Print PDM version inside container.
	docker compose exec pdm proxmox-datacenter-manager-admin versions

set-password: ## Reset Linux root password from compose.yaml's PDM_ROOT_PASSWORD.
	docker compose exec pdm sh -c 'echo "root:$$PDM_ROOT_PASSWORD" | chpasswd'

scan: ## Scan CIDR for Proxmox VE/PBS nodes (vars: CIDR, USER, PASS, TOKEN_NAME).
	@: $${PASS:?'usage: make scan CIDR=192.168.1.0/24 USER=root@pam PASS=...'}
	docker compose exec -e SCAN_PASSWORD='$(PASS)' pdm \
		scan-proxmox \
			--cidr '$(or $(CIDR),192.168.1.0/24)' \
			--user '$(or $(USER),root@pam)' \
			--token-name '$(or $(TOKEN_NAME),pdm-scanner)' \
			$(SCAN_ARGS)

scan-register: ## Scan + auto-register every remote into the running PDM.
	@: $${PASS:?'usage: make scan-register CIDR=... USER=... PASS=...'}
	docker compose exec -e SCAN_PASSWORD='$(PASS)' pdm \
		scan-proxmox \
			--cidr '$(or $(CIDR),192.168.1.0/24)' \
			--user '$(or $(USER),root@pam)' \
			--token-name '$(or $(TOKEN_NAME),pdm-scanner)' \
			--force-token --force-replace \
			--register https://127.0.0.1:8443 \
			$(SCAN_ARGS)

lint: ## Validate compose syntax.
	docker compose config --quiet

verify: ## Run hadolint + shellcheck + compose lint (best-effort; missing tools are skipped).
	@if command -v hadolint >/dev/null; then hadolint Dockerfile; else echo "skip: hadolint not installed"; fi
	@if command -v shellcheck >/dev/null; then \
		find rootfs -type f \( -name '*.sh' -o -path '*/s6-rc.d/*/run' -o -path '*/s6-rc.d/*/up' \) -print0 \
			| xargs -0 -r shellcheck -s sh -e SC1091; \
	else echo "skip: shellcheck not installed"; fi
	@docker compose config --quiet && echo "compose: ok"

cert-show: ## Print TLS subject, SANs, and expiry from the running container.
	@docker compose exec pdm openssl x509 -noout -subject -issuer -dates -ext subjectAltName \
		-in /etc/proxmox-datacenter-manager/auth/api.pem

journalctl: ## Live-tail the in-container systemd journal (Syslog UI source).
	docker compose exec pdm journalctl -f

backup: ## Tar both named volumes to ./pdm-backup-<timestamp>.tar.gz. Uses compose's volume bindings so it's robust to COMPOSE_PROJECT_NAME.
	@ts=$$(date -u +%Y%m%dT%H%M%SZ); \
	out="pdm-backup-$$ts.tar.gz"; \
	docker compose run --rm --no-deps -v "$$PWD":/host --entrypoint sh pdm \
		-c "tar czf /host/$$out -C / etc/proxmox-datacenter-manager var/lib/proxmox-datacenter-manager" \
	&& echo "wrote $$out"

restore: ## Restore both volumes from FILE=pdm-backup-<timestamp>.tar.gz. Container MUST be stopped.
	@: $${FILE:?'usage: make restore FILE=pdm-backup-YYYYMMDDTHHMMSSZ.tar.gz'}
	@test -f "$(FILE)" || { echo "no such file: $(FILE)"; exit 1; }
	@if docker compose ps --status running --services 2>/dev/null | grep -q '^pdm$$'; then \
		echo "refusing: pdm container is running. run 'make down' first."; exit 1; fi
	docker compose run --rm --no-deps -v "$$PWD":/host:ro --entrypoint sh pdm \
		-c 'rm -rf /etc/proxmox-datacenter-manager/* /var/lib/proxmox-datacenter-manager/* && tar xzf "/host/$(FILE)" -C /'
	@echo "restored. run 'make up' to start."

smoke-test: ## End-to-end smoke test. Needs PVE_HOST, PVE_PASS env vars.
	@: $${PVE_HOST:?'usage: make smoke-test PVE_HOST=192.168.1.10 PVE_PASS=... [PVE_USER=root@pam]'}
	@: $${PVE_PASS:?'usage: make smoke-test PVE_HOST=... PVE_PASS=...'}
	scripts/smoke-test.sh

clean: ## Remove image (keep volumes).
	docker compose down --rmi local

reset: ## DANGER: delete all volumes (factory reset).
	@echo "WARNING: this will delete pdm-config and pdm-data volumes (auth keys, remotes, ACLs)."
	@echo "Press Ctrl-C within 5 seconds to abort."
	@sleep 5
	docker compose down -v
