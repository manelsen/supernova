# Onboarding Overview

Supernova has two onboarding paths for Linux with systemd. Both configure provider auth, workspace configuration, and channel setup, but differ in interaction style.

## Which path should I use?

|                | Interactive quickstart (recommended)           | Non-interactive / CI                  |
| -------------- | ---------------------------------------------- | -------------------------------------- |
| **Platforms**  | Linux with systemd                             | Linux with systemd                    |
| **Interface**  | Guided terminal wizard with confirmation       | Environment variables / CLI flags     |
| **Best for**   | First-time setup, single instance              | CI, automation, infrastructure-as-code |
| **Command**    | `curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh \| sh` | See non-interactive mode below         |

Most users should start with the **interactive quickstart** above.

## What onboarding configures

1. **Provider and auth** — API key and default model in `providers`
2. **Workspace/runtime config** — environment and logging
3. **Budgets** — recursion depth, token and tool-call limits
4. **Channels** — Telegram/Discord and optional scaffolded channels
5. **MCP servers (optional)** — `mcp_servers` auto-registered at startup

## Interactive quickstart (recommended)

Run the quickstart installer:

```bash
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | bash
```

The installer:

1. Detects your Linux distro and architecture
2. Installs PostgreSQL locally (if not present)
3. Creates a dedicated `supernova` system user and group
4. Installs the service unit via systemd
5. Runs the configuration wizard
6. Shows a summary and **prompts for confirmation** before enabling the service
7. Starts the service after confirmation

After the service is running:

```bash
systemctl status supernova
journalctl -u supernova -f
```

## Non-interactive installation (CI / automation)

For automated environments, use the non-interactive mode by passing environment variables:

```bash
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | bash -s -- \
  --non-interactive \
  --provider anthropic \
  --model claude-3-5-sonnet-20241022 \
  --channels discord,telegram \
  --db-host localhost \
  --db-port 5432 \
  --db-name supernova \
  --db-user supernova \
  --db-password SECRET \
  --api-key YOUR_API_KEY
```

Or via environment variables:

```bash
export SUPERNOVA_NON_INTERACTIVE=1
export SUPERNOVA_PROVIDER=anthropic
export SUPERNOVA_MODEL=claude-3-5-sonnet-20241022
export SUPERNOVA_API_KEY=your_api_key
export SUPERNOVA_CHANNELS=discord,telegram
export SUPERNOVA_DB_HOST=localhost
export SUPERNOVA_DB_PORT=5432
export SUPERNOVA_DB_NAME=supernova
export SUPERNOVA_DB_USER=supernova
export SUPERNOVA_DB_PASSWORD=secret

curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | bash
```

The non-interactive mode uses the same validation and config generation as the interactive wizard. It fails with a non-zero exit code if any required input is missing.

## Files generated

| File | Purpose | Permissions |
|------|---------|-------------|
| `/etc/supernova/supernova.yaml` | Structural configuration | 644 (readable) |
| `/etc/supernova/secrets.env` | API keys and credentials | 600 (owner only) |
| `/var/lib/supernova/` | Data directory | `supernova:supernova` |

## Docker (development only)

Docker is available for local development and advanced setups. See [DOCKER.md](DOCKER.md).

**Do not use Docker for production deployments** — use the systemd quickstart above.

## Notes

- The wizard generates both `supernova.yaml` and a separate secrets file
- Secrets are never printed in logs or shown in the final summary
- The service does not start until you confirm the summary
- The install is idempotent: rerunning it preserves existing data
- After installation, manage the service with `systemctl start|stop|restart supernova`
