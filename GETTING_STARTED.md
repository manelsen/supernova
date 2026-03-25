# Getting Started

This guide takes you from zero to a running Supernova agent in about 10 minutes.

## Prerequisites

- [Gleam](https://gleam.run/getting-started/) >= 1.0.0
- [Erlang/OTP](https://www.erlang.org/downloads) >= 25.0
- Docker (for PostgreSQL) — or a running PostgreSQL instance

---

## Option A: Docker (recommended)

The fastest path. Docker handles Postgres and the app.

**1. Clone and configure**

```sh
git clone <repo>
cd supernova
cp examples/quickstart/supernova.yaml supernova.yaml
```

Edit `supernova.yaml` and fill in:
- Your LLM API key (Anthropic or OpenAI)
- Your Telegram and/or Discord bot token

**2. Set secrets as environment variables**

```sh
export SUPERNOVA_ANTHROPIC_API_KEY=sk-ant-...
export SUPERNOVA_TELEGRAM_TOKEN=123456:ABC-DEF...
```

Or put them in a `.env` file (Docker Compose picks it up automatically):

```sh
SUPERNOVA_ANTHROPIC_API_KEY=sk-ant-...
SUPERNOVA_TELEGRAM_TOKEN=123456:ABC-DEF...
```

**3. Start**

```sh
docker compose up
```

Supernova starts, connects to Postgres, and begins polling your Telegram/Discord bot.

---

## Option B: Local

**1. Start Postgres**

```sh
docker compose up -d postgres
```

Or use an existing PostgreSQL instance — create a database named `supernova` and update `supernova.yaml`.

**2. Install dependencies**

```sh
gleam deps download
```

**3. Configure interactively (optional)**

The wizard guides you through creating bots and generates `supernova.yaml`:

```sh
gleam run -m supernova/wizard_main
```

Or copy and edit manually:

```sh
cp examples/quickstart/supernova.yaml supernova.yaml
# edit supernova.yaml
```

**4. Run**

```sh
gleam run
```

You should see:

```
🚀 Starting Supernova...
✓ Loaded configuration from supernova.yaml
✓ Session Supervisor started
✓ MCP Manager started
✓ All services started
✓ Supernova is running...

Press Ctrl+C to shutdown
```

---

## Getting a Telegram bot token

1. Open Telegram and search for `@BotFather`
2. Send `/newbot`
3. Follow the prompts — choose a name and username
4. Copy the token BotFather gives you
5. Set it in `supernova.yaml` under `telegram.token` or as `SUPERNOVA_TELEGRAM_TOKEN`

---

## Getting a Discord bot

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications)
2. Create a new application
3. Go to **Bot** → **Add Bot**
4. Copy the bot token
5. Under **OAuth2 → URL Generator**, select `bot` + `applications.commands`
6. Open the generated URL to invite the bot to your server
7. Set the token as `SUPERNOVA_DISCORD_TOKEN` and the application ID as `SUPERNOVA_DISCORD_APP_ID`

---

## Verifying it works

Once running, send your bot a message. Supernova logs each session start:

```
✓ Session started: telegram:chat_id
✓ LLM request: anthropic / claude-haiku-4-5
✓ Response sent
```

To see resource accounting per agent:

```sh
# (coming soon: gleam run -- doctor)
```

---

## Next steps

- Read [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md) for the full architecture overview
- Adjust `budgets` in `supernova.yaml` to control per-agent token limits
- Add MCP servers under `mcp_servers:` in `supernova.yaml` to extend tool capabilities
- Set `environment: production` and `log_level: warn` before deploying

---

## Troubleshooting

**`supernova.yaml not found`** — the file is optional; Supernova uses defaults. Check that your API key and bot token are set as environment variables.

**`Failed to start services`** — most likely Postgres is not reachable. Check that `docker compose up -d postgres` ran successfully and the host/port in config match.

**Bot does not respond** — verify the token is correct and the bot is not already running elsewhere (Telegram allows only one polling connection per token).
