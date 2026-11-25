# Interacting with Supernova

This page describes what a person sees when they talk to their agent. Setup and access are covered in [DEPLOY.md](../../DEPLOY.md).

## Channels

Telegram and WhatsApp ([WHATSAPP.md](WHATSAPP.md)) are the supported channels: access, budget, capabilities, rate limits and the commands below all work there. Discord has the same pipeline but does not receive messages yet (its gateway connection is a stub). Slack, Matrix, Lark, Google Chat, Mattermost and WeChat Work have native adapters that only send, and they do not go through the closed group yet. Supernova warns about them at boot. The order in which they will be brought up to the same level is in [`docs/PENDENCIAS.md`](../PENDENCIAS.md), section 3.2.

## One agent per person

In closed-group mode, each authorized person has their own agent.

1. **Birth.** The first message starts it. A coherent self is sampled from the constellation (`priv/constellation/`) and written as the agent's core.
2. **Name.** The person gives the agent a name, and the agent confirms it. After that, `/start` and `/reset-identity` are refused.
3. **Memory.** Each turn goes to the agent's journal. A periodic reflection turns the journal into experiences and pressures. The pressures can, slowly, add to the core ("drift").
4. **What the agent sees.** In a group, the agent sees only its own person's messages and does not talk to the other agents.

The conversation survives a restart: each person's conversation in each chat is kept whole on disk, and the model sees its last 100 messages (`conversation.history_limit`). For anything older, the agent searches with the `buscar_conversa` tool, which reads only that person's conversations, private and in groups. A message that was waiting when Supernova stopped is answered after the restart, once ([DOCKER.md](DOCKER.md#what-a-restart-does-to-conversations)). The core, memories, files and agenda survive too.

## Commands

| Command | Who | What it does |
|---|---|---|
| `/eu` | Everyone, even unauthorized people | Shows your principal id, so an admin can authorize you. |
| `/esquecer` | Members and admins | Explains what forgetting erases. `/esquecer confirmo` erases everything the person told the agent: conversations, memories, what it learned from them, the files it kept for them, and the agenda. The agent's name and character stay. |
| `/vincular` | Members and admins, in private | Gives a code (six characters, valid for 10 minutes, used once) to bring another channel to the same agent. On the other channel, in private, send `/vincular CÓDIGO`. From then on it is the same agent, memory and agenda on both. You are told on the first channel when a channel is linked. |
| `/desvincular` | Members and admins | On a linked channel, unlinks it. On your first channel, lists the linked ones; `/desvincular <id>` unlinks one. `/esquecer` keeps the links. |
| `/agenda` | Members and admins | Lists what you asked your agent to do later. `/agenda remover <id>` removes one entry. |
| `/uso` | Members and admins | Your own spending. |
| `/model` | Members and admins | Chooses the provider and model with buttons (inline keyboard on Telegram, components on Discord). |
| `/help`, `/status` | Members and admins | Help and session status. |
| `/uso todos`, `/acesso …`, `/teto liberar <usd>`, `/auditoria [n]` | Admins | Instance spending, access, the daily ceiling and the audit log. See [DEPLOY.md](../../DEPLOY.md). |

`/help` answers with this list, by role: admins also see their commands. On Telegram, Supernova sets the same list as the bot's command menu at every boot (members' commands in every chat, the longer list in each admin's private chat, for the admins in `supernova.yaml`), replacing whatever menu was set before with the same token. The list lives in `core/closed_group/commands.gleam`.

## Tools

The agent decides when to use its tools. Admins can use every tool. For members, the defaults deny the riskier tools, and `supernova.yaml` (`capabilities`) can change that.

- **Files and the person's workspace.**
- **The agenda.** "Me lembra amanhã às 9h", or "todo dia às 3h". At that hour the agent receives an `[Agenda]` message, and whatever it answers is sent to the person.
- **The web, a browser, GitHub, git inspection.**
- **Its own computer** (`computador`), when enabled: a shell, files and a browser it sees through screenshots. It runs in a separate gVisor container that holds no secrets. See [COMPUTADOR.md](COMPUTADOR.md).

## Troubleshooting

- **No answer at all:** check `docker compose logs supernova`. `GET /health/ready` shows whether each channel is ready and, if not, why ([OBSERVABILITY.md](OBSERVABILITY.md)).
- **Unauthorized people** get the `denied_reply` configured in `access` (at most once every 24 h), or nothing. They can send `/eu` and ask an admin to run `/acesso adicionar <principal>`.
- **"O limite diário desta instância foi atingido":** an admin can raise the ceiling for the day with `/teto liberar <usd>`.
