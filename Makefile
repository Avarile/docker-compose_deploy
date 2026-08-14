# ─────────────────────────────────────────────────────────────────────────────
# Orchestration for the whole platform. Everything runs as ONE compose project
# ("platform") assembled from ./compose.yaml (which `include:`s each stack).
#
#   make bootstrap   one-time: create network, create data dirs, bring all up
#   make up          bring the whole platform up (-d)
#   make down        stop & remove all containers (keeps data + network)
#   make infra       bring up only the 7 shared backing services
#   make ps          status of every service
#   make logs        follow logs (all services)
#   make logs S=api  follow logs for one service
#   make pull        pull all registry images
#   make config      render+validate the fully-merged compose model
# ─────────────────────────────────────────────────────────────────────────────

DC        := docker compose
NETWORK   := backbone
INFRA     := pgvector mysql redis rabbitmq minio qdrant meilisearch

# All data subdirectories that bind mounts expect to exist.
DATA_ROOT ?= $(shell grep -E '^DATA_ROOT=' .env 2>/dev/null | cut -d= -f2)
DATA_DIRS := postgres mysql redis rabbitmq/data rabbitmq/log minio qdrant \
             meilisearch vaultwarden ghost gitea cybernetics main-website \
             twenty plane-monitor plane evershop

.DEFAULT_GOAL := help
.PHONY: help bootstrap network datadirs secrets up infra apps down restart ps logs pull config

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

secrets: ## Generate fresh .env files for a NEW deployment (skips existing; pass FORCE=1 to overwrite)
	@./scripts/generate-secrets.sh $(if $(FORCE),--force)

network: ## Create the shared external docker network (idempotent)
	@docker network inspect $(NETWORK) >/dev/null 2>&1 || docker network create $(NETWORK)

datadirs: ## Create all bind-mount data directories under DATA_ROOT
	@test -n "$(DATA_ROOT)" || { echo "DATA_ROOT is empty — did you copy .env.example to .env?"; exit 1; }
	@for d in $(DATA_DIRS); do mkdir -p "$(DATA_ROOT)/$$d"; done
	@echo "data dirs ready under $(DATA_ROOT)"

bootstrap: network datadirs ## First-time setup: network + data dirs + bring everything up
	$(DC) up -d
	@echo "Platform starting. App databases/buckets/vhosts are provisioned automatically by *-init services."

up: network datadirs ## Bring the whole platform up
	$(DC) up -d

infra: network datadirs ## Bring up only the shared backing services
	$(DC) up -d $(INFRA)

apps: up ## Alias for `up` (infra is a dependency-free subset of the same project)

down: ## Stop and remove all containers (data + network preserved)
	$(DC) down

restart: down up ## Recreate everything

ps: ## Show status of all services
	$(DC) ps

logs: ## Follow logs (all, or one service with S=<name>)
	$(DC) logs -f --tail=200 $(S)

pull: ## Pull all registry images
	$(DC) pull --ignore-buildable

config: ## Render and validate the merged compose model
	$(DC) config >/dev/null && echo "compose config OK"
