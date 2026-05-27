# Makefile for proxmox-dc-manager-dockerized
# Run `make help` to see available targets.

.DEFAULT_GOAL := help

.PHONY: help build refresh up down restart logs shell init-shell \
        pdm-version set-password scan scan-register \
        lint clean reset

help: ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## Build the Docker image (extractor stage downloads the ISO automatically).
	DOCKER_BUILDKIT=1 docker compose build

refresh: ## Cache-busted rebuild: re-pulls Debian Trixie security updates and re-runs dist-upgrade.
	DOCKER_BUILDKIT=1 docker compose build --pull --no-cache

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

clean: ## Remove image (keep volumes).
	docker compose down --rmi local

reset: ## DANGER: delete all volumes (factory reset).
	@echo "WARNING: this will delete pdm-config and pdm-data volumes (auth keys, remotes, ACLs)."
	@echo "Press Ctrl-C within 5 seconds to abort."
	@sleep 5
	docker compose down -v
