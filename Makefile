COMPOSE ?= docker compose
AIROUTER_UID ?= $(shell id -u)
AIROUTER_GID ?= $(shell id -g)

export AIROUTER_UID
export AIROUTER_GID

.DEFAULT_GOAL := help

.PHONY: help config logs shell

help:
	@echo "AI router server"
	@
	@echo "  make config  Create private router config with random secrets"
	@echo "  make logs    Follow router logs"
	@echo "  make shell   Open a shell in the router container"

config:
	@install -d -m 0700 server-state
	@if [ ! -e server-state/config.lua ]; then \
		(umask 077; set -C; ./luajit docker/init-ai-router.lua > server-state/config.lua); \
	else \
		echo "server-state/config.lua already exists; preserved"; \
	fi
	@if [ ! -e server-state/network.lua ]; then \
		(umask 077; set -C; printf 'return {}\n' > server-state/network.lua); \
	fi
	@echo "Router secrets are in server-state/config.lua; not printed. Review before deployment."

logs:
	$(COMPOSE) logs --follow ai-router

shell:
	$(COMPOSE) exec ai-router /bin/sh
