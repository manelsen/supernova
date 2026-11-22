# Getting Started

From zero to talking with your own agent on Telegram. Running a group (several people, Discord, ceilings) is covered in [DEPLOY.md](DEPLOY.md).

## Prerequisites

- Docker Engine 28+ and Docker Compose 2.33.1+.
- An API key for one LLM provider. The pilot runs on Mistral, serving DeepSeek.
- A Telegram bot token. Open `@BotFather`, send `/newbot` and copy the token.
- Optional: gVisor (`runsc`), only if you want the agent to have its own computer.

## 1. Configure

```sh
git clone https://github.com/manelsen/supernova
cd supernova
cp supernova.yaml.example supernova.yaml
cp .env.example .env && chmod 600 .env
```

In `supernova.yaml`:

- **Providers:** keep only the provider you will use. Agents use the provider whose name sorts first, and Supernova refuses to start when that provider needs a key and has none.
- **Channels:** set `enabled: true` under `telegram`.

In `.env`, fill in your provider's key and the bot token:

```sh
SUPERNOVA_PROVIDER_MISTRAL_API_KEY=...
SUPERNOVA_TELEGRAM_TOKEN=...
```

The variable name follows the provider's key in `supernova.yaml`: `SUPERNOVA_PROVIDER_{NAME}_API_KEY`. `docker-compose.yml` passes only the Mistral, Anthropic and OpenAI keys to the container; for any other provider, add its variable there too.

## 2. Start and find your id

```sh
docker compose up -d --build
```

The instance is a **closed group**: it denies everyone until someone is on its access list. Send `/eu` to your bot. It answers even before you are authorized, and shows your id, for example `telegram:123456789`.

## 3. Make yourself admin

Add your id to `.env` and restart:

```sh
SUPERNOVA_ACCESS_ADMINS=telegram:123456789
```

```sh
docker compose up -d
```

## 4. Meet your agent

Send any message. Your agent is born: it gets a character of its own, and then asks you for a name. From then on:

- it remembers what you tell it and reflects on it;
- `/agenda` shows what you asked it to do later;
- `/uso` shows what it has spent;
- `/esquecer` erases everything you told it, and keeps who it became.

The full list of commands is in [docs/operations/INTERACTION.md](docs/operations/INTERACTION.md).

## Optional: the agent's computer

The agent can have a Linux machine of its own, with a shell and a browser it sees through screenshots. The machine runs in a separate gVisor container that holds no secrets. Setup, the firewall rules and the threat model are in [docs/operations/COMPUTADOR.md](docs/operations/COMPUTADOR.md).

## Running without Docker

You need the pinned toolchain from `.tool-versions` (Erlang 28.5.0.8, Gleam 1.19.2):

```sh
gleam deps download
set -a; . ./.env; set +a
gleam run
```

## Troubleshooting

- **The bot does not answer at all.** Check `docker compose logs supernova`. Telegram allows one polling connection per token, so make sure the bot is not running elsewhere.
- **The bot answers "Esta instância é privada."** You are not on the access list yet: see step 3.
- **The bot says "A Supernova ainda não está pronta para receber agentes novas."** `priv/constellation/constellation.json` is missing.
- **Health:** `docker exec supernova curl -sS -i http://127.0.0.1:8080/health/ready` answers 200 when every channel is ready and 503 with the reason when one is not. Only Telegram is probed continuously; for other channels, read the logs.
