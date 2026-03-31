# `supernova` CLI onboarding

## Quickstart

The recommended way to install Supernova on Linux with systemd:

```bash
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | sh
```

This installer:
1. Detects distro and architecture
2. Installs PostgreSQL locally (if needed)
3. Creates the `supernova` system user and group
4. Installs the systemd service unit
5. Runs the configuration wizard
6. Prompts for confirmation before starting the service

After confirmation, the service is running.

## Non-interactive installation (CI / automation)

For automated environments, pass arguments to the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | sh -s -- \
  --non-interactive \
  --provider anthropic \
  --model claude-3-5-sonnet-20241022 \
  --channels discord,telegram \
  --api-key YOUR_API_KEY
```

Or via environment variables:

```bash
export SUPERNOVA_NON_INTERACTIVE=1
export SUPERNOVA_PROVIDER=anthropic
export SUPERNOVA_MODEL=claude-3-5-sonnet-20241022
export SUPERNOVA_API_KEY=your_api_key
export SUPERNOVA_CHANNELS=discord,telegram

curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | sh
```

## Managing the service

```bash
systemctl start supernova
systemctl stop supernova
systemctl restart supernova
systemctl status supernova
journalctl -u supernova -f
```

## Files

| File | Purpose |
|------|---------|
| `/etc/supernova/supernova.yaml` | Structural configuration |
| `/etc/supernova/secrets.env` | API keys and credentials |
| `/var/lib/supernova/` | Data directory |

## Development

For local development without systemd:

```bash
gleam deps download
gleam run -m supernova/wizard_main
gleam run
```

## Docker (development only)

For local development with Docker, see [DOCKER.md](DOCKER.md).
