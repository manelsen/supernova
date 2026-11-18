.PHONY: help configure up down logs rebuild test coverage check-config clean restart

COMPOSE_FILE := -f docker-compose.yml

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | awk -F: '{printf "%-12s %s\n", $$1, $$3}'

configure: ## Run the interactive setup wizard
	gleam run -m supernova/wizard_main

	docker compose $(COMPOSE_FILE) up -d

up-build: ## Start services, always rebuild first
	docker compose $(COMPOSE_FILE) up --build -d

down: ## Stop and remove services
	docker compose $(COMPOSE_FILE) down

logs: ## Tail logs from supernova container
	docker compose $(COMPOSE_FILE) logs -f

rebuild: ## Rebuild image without starting
	docker compose $(COMPOSE_FILE) build supernova

test: ## Run test suite
	gleam test

coverage: ## Run line coverage gate (minimum 75%)
	gleam test
	./scripts/coverage/line_coverage.escript --threshold 75

check-config: ## Validate supernova.yaml and report issues
	gleam run -m supernova/check_config_main -- supernova.yaml

restart: ## Restart the container
	docker compose $(COMPOSE_FILE) restart supernova

clean: ## Remove containers and volumes
	docker compose $(COMPOSE_FILE) down -v
