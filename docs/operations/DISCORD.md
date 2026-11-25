# Discord

The agent talks on Discord through the **Gateway** (a WebSocket Supernova
opens to Discord) and the **REST API**. Nothing has to be exposed on the
host: Supernova only makes outbound connections.

```
Discord ◀── WebSocket (gateway.discord.gg) ── Supernova
        ◀── HTTPS (discord.com/api/v10) ────┘
```

## What to know first

- **Private chats and servers.** A private chat with an authorized person
  always works. A server works only when it is in `access.allowed_chats` as
  `discord:guild:<server id>`; every channel and thread of it is then a chat
  of its own. In an unauthorized server the bot stays silent.
- **The Message Content Intent is required.** Without it, Discord closes the
  connection with code 4014. Supernova then stops reconnecting, marks the
  channel failed in `/health/ready` with "intents não autorizadas (4014):
  ligue a Message Content Intent no Developer Portal", and the "channel
  down" alert fires.
- **Above 100 servers** Discord asks for the bot to be verified before it
  keeps that intent. The pilot is far from it.
- **Slash commands** are registered globally at every connection, from the
  same list as `/help` and the Telegram menu (member commands only; an admin
  types `/acesso`, `/teto` and `/auditoria` as plain text). While an argument
  is typed, Discord shows suggestions filtered by the person's role.
- **Voice is not supported yet.** `/voz` keeps the preference, and replies
  stay in text (it needs an Opus encoder in the image).

## Setup

1. **Create the application.** In the
   [Developer Portal](https://discord.com/developers/applications):
   *New Application* → *Bot*. Under *Privileged Gateway Intents*, turn on
   **Message Content Intent**. Copy the bot token (*Reset Token*). The
   *Application ID* is on *General Information*.

2. **Invite the bot** to your server with the `bot` and
   `applications.commands` scopes and these permissions: View Channels,
   Send Messages, Send Messages in Threads, Read Message History, Attach
   Files. The invite URL:

   ```
   https://discord.com/oauth2/authorize?client_id=<APPLICATION_ID>&scope=bot+applications.commands&permissions=274878008320
   ```

3. **Configure.** In `.env` (never paste the token anywhere else):

   ```
   SUPERNOVA_DISCORD_TOKEN=<bot token>
   SUPERNOVA_DISCORD_APP_ID=<application id>
   SUPERNOVA_DISCORD_ENABLED=true
   ```

   `SUPERNOVA_DISCORD_APP_ID` is optional: without it, the bot's own id is
   used, which is the application id for any recent bot. `discord.guild_id`
   in `supernova.yaml` is optional too: if set, old copies of the commands in
   that server are removed at every connection (a command registered both
   globally and in a server shows twice).

4. **Restart:** `docker compose up -d`. `GET /health/ready` lists `discord`
   as ready once the gateway is connected.

5. **Authorize people and the server.** A person's principal is
   `discord:<user id>` (turn on *Developer Mode* in Discord to copy ids, or
   ask them to send `/eu`). As an admin:

   ```
   /acesso adicionar discord:<user id>
   /acesso chat adicionar discord:guild:<server id>
   ```

6. **Talk.** Send the bot a private message. The agent is born on the first
   message, as on Telegram. A person who already has an agent on another
   channel brings it with `/vincular` (see the identity section of the
   README).

## What happens when

| Situation | What Supernova does |
|---|---|
| Network drop, missed heartbeat, Discord asks to reconnect | Resumes the session; nothing is lost |
| Session expired (4007, 4009) or invalid | Identifies again, after a short wait |
| Bad token (4004) or intents not allowed (4010–4014) | Stops, marks the channel failed with the reason, alert fires |
| Rate limited (429) | Waits what Discord says, rounded up to a whole second |
| A button is pressed | Discord is answered at once; the reply edits the message with the buttons |
| A slash command is sent | It is shown in the channel, and the agent replies below it |
| An attachment arrives | Downloaded from Discord's CDN only, checked by its bytes, read like on Telegram (PRD-A); nothing is downloaded for someone without access |

## Tests and fixtures

Tests never reach Discord: they run against a local gateway and API
(`test/discord_fake.gleam`). The payloads come from real captures,
anonymized (`test/fixtures/discord/`, February 2026). To record new ones,
with a test bot in a test server:

```
python3 -I dev/discord/gravar.py --env /path/.env --segundos 180 --canal <test channel id>
```

It writes to `test/fixtures/discord/gravadas/` for review before they
replace the old ones.
