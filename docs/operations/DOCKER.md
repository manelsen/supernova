# Supernova with Docker

## Install / First Run

1. Ensure Docker and Docker Compose are installed.
2. Copy quickstart config:

```sh
cp examples/quickstart/supernova.yaml supernova.yaml
```

3. Set secrets via environment (`.env` or shell):

```sh
SUPERNOVA_ANTHROPIC_API_KEY=...
SUPERNOVA_TELEGRAM_TOKEN=...
```

4. Start stack:

```sh
docker compose up -d
```

## Configuration

- Main runtime config: `supernova.yaml`
- Compose service/env wiring: `docker-compose.yml`
- Prefer environment variables for secrets.

Useful commands:

```sh
docker compose logs -f supernova
docker compose ps
```

## Scaling

Scale stateless service replicas when your runtime path supports it:

```sh
docker compose up -d --scale supernova=3
```

Notes:

- Keep shared dependencies (DB, queue, external APIs) dimensioned for higher concurrency.
- Validate session-routing semantics when horizontally scaling channel workers.

## Interaction

- Send messages via configured channel bots (Telegram/Discord/etc.).
- Monitor logs for inbound mapping, runtime execution, and outbound delivery.

## Stop / Uninstall

Stop services:

```sh
docker compose down
```

Stop and remove volumes (destructive for local DB data):

```sh
docker compose down -v
```

Remove local images if needed:

```sh
docker image prune -f
```

