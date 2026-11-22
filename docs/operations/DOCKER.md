# Supernova with Docker

Docker Compose is the supported way to run Supernova, and the pilot runs on it. The agent's computer (`computador`) also needs Docker, with gVisor (`runsc`) registered as a runtime: see [COMPUTADOR.md](COMPUTADOR.md). The first-time setup is described in [DEPLOY.md](../../DEPLOY.md). A wizard that runs it for you, adapted to Docker and gVisor, is planned ([`docs/PENDENCIAS.md`](../PENDENCIAS.md), section 2.1).

## Prerequisites

- Docker Engine 28+ and Docker Compose 2.33.1+ (`gw_priority` in `docker-compose.yml`)
- gVisor (`runsc`), only if you enable the agent's computer
- Internet access to pull images

## Quick start

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
