# Onboarding Overview

Supernova runs on Linux and macOS without root access. All files are installed in your home directory.

## Quickstart

```bash
# Download the CLI
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/supernova -o supernova
chmod +x supernova

# Install
./supernova install

# Configure
./supernova configure

# Start
./supernova start
```

That's it. No sudo, no systemd, no PostgreSQL required by default.

## What onboarding configures

1. **Provider and auth** — API key and default model in `providers`
2. **Workspace/runtime config** — environment and logging
3. **Budgets** — recursion depth, token and tool-call limits
4. **Channels** — Telegram/Discord and optional scaffolded channels
5. **MCP servers (optional)** — `mcp_servers` auto-registered at startup

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

## Files installed

| Path | Purpose |
|------|---------|
| `~/.local/supernova/` | Binary, data, and logs |
| `~/.config/supernova/` | Configuration and secrets |
| `~/.config/supernova/supernova.yaml` | Main config |
| `~/.config/supernova/secrets.env` | API keys (optional) |

## Database

By default, Supernova uses SQLite for simplicity. For production with PostgreSQL:

```bash
export SUPERNOVA_DB_HOST=localhost
export SUPERNOVA_DB_PORT=5432
export SUPERNOVA_DB_NAME=supernova
export SUPERNOVA_DB_USER=your_user
export SUPERNOVA_DB_PASSWORD=your_password

./supernova restart
```

## CI / automation

For automated environments, set environment variables before running:

```bash
export SUPERNOVA_PROVIDER=anthropic
export SUPERNOVA_MODEL=claude-3-5-sonnet-20241022
export SUPERNOVA_API_KEY=your_api_key
export SUPERNOVA_CHANNELS=discord,telegram

./supernova install
./supernova configure
./supernova start
```

## Development with Docker

Docker is available for local development and advanced setups. See [DOCKER.md](DOCKER.md).

## Uninstall

```bash
./supernova uninstall
```

This removes `~/.local/supernova/` but keeps your configuration in `~/.config/supernova/`.
