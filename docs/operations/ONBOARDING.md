# Onboarding (Supernova)

This document describes the practical first-run onboarding flow for Supernova on Linux with systemd.

## Quickstart

Run the quickstart installer:

```bash
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | sh
```

The installer handles everything:
1. Detects distro and architecture
2. Installs PostgreSQL locally (if needed)
3. Creates the `supernova` system user and group
4. Installs the systemd service unit
5. Runs the configuration wizard
6. Shows a summary and **prompts for confirmation**
7. Starts the service

After the service starts, verify:

```bash
systemctl status supernova
journalctl -u supernova -f
```

## Non-interactive mode (CI / automation)

For automated environments:

```bash
curl -fsSL https://raw.githubusercontent.com/manelsen/supernova/main/scripts/quickstart/install.sh | sh -s -- --non-interactive \
  --provider anthropic \
  --model claude-3-5-sonnet-20241022 \
  --api-key YOUR_API_KEY
```

Or set environment variables before running the installer.

See [ONBOARDING_OVERVIEW.md](ONBOARDING_OVERVIEW.md) for the full non-interactive reference.

## Troubleshooting

- `systemctl status supernova` shows failed: Check `journalctl -u supernova` for errors
- Wizard aborted: Re-run the installer; it is idempotent and resumes from where you left off
- Database connection failed: Verify PostgreSQL is running (`systemctl status postgresql`)
- No channel response: Validate bot tokens and channel enable flags in `/etc/supernova/supernova.yaml`

## Docker (development only)

For local development with Docker, see [DOCKER.md](DOCKER.md).

**Do not use Docker for production deployments.**
