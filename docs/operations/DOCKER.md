# Supernova with Docker (Development / Advanced)

> **Note:** Docker is not recommended for production deployments.
> For production, use the standard installation:
> ```
> curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/supernova -o supernova
> chmod +x supernova
> ./supernova install
> ```
> See [ONBOARDING_OVERVIEW.md](ONBOARDING_OVERVIEW.md) for details.


This document covers Docker usage for local development and advanced setups.

## When to use Docker

- Local development on macOS or Windows
- Quick evaluation without modifying your system
- Complex multi-service setups
- Building and testing custom images

## Prerequisites

- Docker and Docker Compose installed
- Internet access to pull images

## Quick start (development)

```sh
# Clone the repository
git clone https://github.com/manelsen/supernova
cd supernova

# Copy and edit config
cp examples/quickstart/supernova.yaml supernova.yaml

# Set environment variables
export SUPERNOVA_ANTHROPIC_API_KEY=...
export SUPERNOVA_TELEGRAM_TOKEN=...
export SUPERNOVA_DISCORD_TOKEN=...

# Start the stack
docker compose up -d
```

## Configuration

| File | Purpose |
|------|---------|
| `supernova.yaml` | Main runtime config (mounted into container) |
| `docker-compose.yml` | Service orchestration and environment |
| `.env` | Secrets (never commit this file) |

## Managing services

```sh
# View logs
docker compose logs -f supernova

# Check status
docker compose ps

# Restart the service
docker compose restart supernova

# Stop everything
docker compose down

# Stop and remove volumes (destructive)
docker compose down -v
```

## Building a custom image

```sh
docker build -t supernova:custom .
```

Then update `docker-compose.yml` to use your custom image:

```yaml
services:
  supernova:
    image: supernova:custom
```

## Production deployment

For production, use the systemd quickstart:

```bash
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | bash
```

This provides:
- Systemd service management with restart policies
- Graceful shutdown handling
- Proper separation of config and secrets
- Idempotent, auditable installation

See [ONBOARDING_OVERVIEW.md](ONBOARDING_OVERVIEW.md) for details.
