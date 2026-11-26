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

### What a restart does to conversations

A restart, a `docker compose up -d --build` or a `docker compose down` stops Supernova in order:

1. The channels stop fetching new messages. Messages people send meanwhile wait at Telegram and arrive after the restart.
2. Turns in progress get up to 40 s to finish (`stop_grace_period` is 60 s).
3. Every message is written to `/data/inbox.jsonl` before its turn starts and marked done when it ends. A message whose turn did not finish is answered after the restart, once. If it fails again, or if it is more than a day old, it is dropped and the log says so.
4. Telegram sends the last batch again after a restart, and the inbox recognises it, so nobody gets the same answer twice.

A turn cut short can be answered again from the start, so an action it took midway (a reminder scheduled, a file written) may happen twice.

This depends on the inbox working. If it could not be opened at boot, or stops answering, messages still reach their turn, but without a record on disk, so a restart can lose those that were waiting. The log says so: `Warning: durable inbox not opened` at boot, `warn: inbox did not answer; message not kept` per message.

`/esquecer confirmo` also erases the person's waiting messages from the inbox and rewrites the file at once, without the text of any finished turn.

The conversation itself survives the restart: see `/data/agents/<person>/conversations/` in [OBSERVABILITY.md](OBSERVABILITY.md).

## Tool isolation

Inside the container, `tools.sandbox` stays `none`: `safe_shell`,
`git_inspect` and `process` run without Bubblewrap and rely on argument
validation and the workspace policy. `bwrap` only works in a container with
both seccomp and AppArmor unconfined (`--security-opt seccomp=unconfined
--security-opt apparmor=unconfined`), which removes two protections from the
process that holds every key and token. That trade was rejected (PRD-F, D7).
Do not add those options to `docker-compose.yml`. Commands that need real
isolation belong to the per-person computer, which runs under gVisor
([COMPUTADOR.md](COMPUTADOR.md)).

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
