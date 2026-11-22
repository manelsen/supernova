# Onboarding Overview

Supernova runs on Linux and macOS via Docker. No root access required.

## Quickstart

```bash
# Download the CLI
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/supernova -o supernova
chmod +x supernova

# Install Docker image
./supernova install

# Configure (runs wizard in Docker)
./supernova configure

# Start
./supernova start
```

Requirements: Docker installed and running.

## What onboarding configures

1. **Provider and auth** — API key and default model
2. **Workspace/runtime config** — environment and logging
3. **Budgets** — recursion depth, token and tool-call limits
4. **Channels** — Telegram/Discord and optional channels
5. **MCP servers (optional)** — auto-registered at startup

## Managing the service

```bash
./supernova start       # Start the service
./supernova stop        # Stop the service
./supernova restart     # Restart the service
./supernova status      # Check if running
./supernova logs        # View recent logs
./supernova logs -f     # Follow logs (Ctrl+C to exit)
./supernova update      # Update to latest version
./supernova doctor      # Check system requirements
```

## Files

| Path | Purpose |
|------|---------|
| `~/.config/supernova/` | Configuration |
| `~/.config/supernova/supernova.yaml` | Main config |
| `~/.config/supernova/secrets.env` | API keys (optional) |
| `~/.local/supernova/` | Data and logs |

## Auto-start on login

Configure Docker Desktop/App to start on login, or use Docker Compose with a systemd service.

## Uninstall

```bash
docker stop supernova
docker rm supernova
docker rmi ghcr.io/manelsen/supernova:latest
rm -rf ~/.local/supernova ~/.config/supernova
```
