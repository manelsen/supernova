# Onboarding (Supernova)

This document describes the practical first-run onboarding flow for Supernova.

## Step 1 — Prepare runtime

Install Gleam/Erlang and start PostgreSQL:

```bash
docker compose up -d postgres
gleam deps download
```

## Step 2 — Choose onboarding mode

### Option A: Wizard (recommended)

```bash
gleam run -m supernova/wizard_main
```

This generates `supernova.yaml` with your selected channels and provider settings.

### Option B: Manual config

```bash
cp examples/quickstart/supernova.yaml supernova.yaml
```

Edit:

- `providers.default.provider`
- `providers.default.model`
- channel tokens (`telegram.token`, `discord.token`, etc.)
- budget values under `budgets`

Prefer env vars for secrets (`SUPERNOVA_*`).

## Step 3 — Optional MCP onboarding

You can declare MCP servers directly in `supernova.yaml`:

```yaml
mcp_servers:
  filesystem:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-filesystem"]
    env:
      NODE_ENV: production
```

At startup, Supernova parses `mcp_servers` and registers each server in the MCP manager automatically.

## Step 4 — Run Supernova

```bash
gleam run
```

Expected bootstrap logs include:

- configuration loaded
- session supervisor started
- MCP manager started
- MCP servers registered (if configured)

## Step 5 — Verify channel interaction

Send a message in your configured channel (Telegram/Discord). You should see a response and session activity logs.

## Troubleshooting

- `supernova.yaml not found`: defaults are used; add config/env vars.
- `Failed to start services`: verify PostgreSQL reachability and credentials.
- No channel response: validate bot tokens and channel enable flags.

