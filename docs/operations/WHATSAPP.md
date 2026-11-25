# WhatsApp

The agent talks on WhatsApp through **GOWA** (`go-whatsapp-web-multidevice`,
MIT, built on whatsmeow), a bridge that holds the WhatsApp session in its own
container. Supernova never sees the WhatsApp credentials. GOWA calls
Supernova's webhook for every message, and Supernova replies through GOWA's
REST API.

```
WhatsApp ── GOWA (supernova-gowa:3000) ──signed webhook──▶ Supernova (:8790, internal)
                  ▲                                             │
                  └──────────── REST + basic auth ◀────────────┘
```

## What to know first

- **It is not an official API.** WhatsApp may log the number out or suspend
  it. When that happens, GOWA reports `device.logged_out` or
  `device.temporary_ban`. Supernova then alerts the admins ("O canal whatsapp
  caiu: …") and marks the channel failed in `/health/ready`.
- **GOWA sees the messages.** It keeps the session and the downloaded media
  on its volumes (`gowa_storages`, `gowa_statics`).
- **GOWA serves its media without auth** (`/statics/…`), even with basic
  auth on. Its port is published on the host's loopback only. Never expose
  it elsewhere.
- **The image is pinned by digest** (v9.10.0). Update it by hand: read the
  changelog, change the tag and digest in `docker-compose.yml`, and update
  the webhook payloads in the tests (`test/adapters/whatsapp_*`) if they
  changed.

## Setup

1. In `.env`:

   ```
   COMPOSE_PROFILES=whatsapp
   SUPERNOVA_WHATSAPP_ENABLED=true
   SUPERNOVA_WHATSAPP_BASIC_AUTH=supernova:<openssl rand -hex 24>
   SUPERNOVA_WHATSAPP_WEBHOOK_SECRET=<openssl rand -hex 32>
   ```

2. In `supernova.yaml`, turn the channel on and let the webhook listen inside
   the container:

   ```yaml
   whatsapp:
     enabled: true
   channels:
     internal_hosts: [gowa]
     webhook:
       bind: 0.0.0.0
       port: 8790
   ```

3. `docker compose up -d`. The log should show `whatsapp: started` and
   `✓ Webhook server on 0.0.0.0:8790`.

The compose file already sets what GOWA must not do. Do not change these
settings:

| Variable | Value | Why |
|---|---|---|
| `WHATSAPP_AUTO_REPLY` | empty | GOWA's example answers every message by itself |
| `APP_UI_AUTO_UPDATE` | `false` | otherwise the UI is fetched from GitHub every 3 h and runs with your session |
| `MCP_ENABLED` | `false` | GOWA's own MCP server is not used |
| `WHATSAPP_WEBHOOK_EVENTS` | `message,device.logged_out,device.temporary_ban` | only what Supernova reads |
| `WHATSAPP_WEBHOOK_INCLUDE_OUTGOING` | `false` | the agent's own replies do not come back |

## Pairing the number

1. From your computer, open a tunnel to the GOWA UI:

   ```
   ssh -L 3000:127.0.0.1:3000 <server>
   ```

2. Open http://localhost:3000 and log in with the user and password from
   `SUPERNOVA_WHATSAPP_BASIC_AUTH`.
3. Choose **Login** and scan the QR code with the agent's phone (WhatsApp →
   Linked devices). You can also ask for a pairing code.
4. Send a message to the agent's number from an allowed person. The log
   shows the turn. If nothing happens, see the troubleshooting section.
5. Close the tunnel.

## People and groups

- A person on WhatsApp is `whatsapp:<phone>`, digits only, with the country
  code (`whatsapp:5511999999999`). Add people with `/acesso` or in
  `access.members`, like on Telegram.
- **Same agent as on Telegram.** A person who already talks to the agent
  elsewhere sends `/vincular` there, in private. They then send
  `/vincular CÓDIGO` to the agent's WhatsApp, also in private. From then on
  it is the same agent, with the same memory, on both channels.
  `/desvincular` undoes the link.
- **Groups** are authorized as `whatsapp:<group id>@g.us` in
  `access.allowed_chats` (or `/acesso chat` from inside the group). In a
  group, the agent answers only when mentioned, when someone replies to it,
  or when the message is a command.
- **LIDs.** WhatsApp sometimes hides the phone behind a LID (`…@lid`),
  mostly in groups. Supernova learns which phone a LID belongs to when both
  arrive together. If someone it does not recognize yet calls it in a
  group, the agent asks them to write in private once.
- **Images.** Images the person sends (up to 5 MB) reach the model once.
  The history keeps `[imagem]`. Audio and documents are not read yet.

## Troubleshooting

| Symptom | Look at |
|---|---|
| No turn when a message arrives | GOWA log: webhook errors. Supernova log: `401` means the two `WEBHOOK_SECRET` values differ |
| Replies fail with "Unauthorized" | `SUPERNOVA_WHATSAPP_BASIC_AUTH` differs from GOWA's `APP_BASIC_AUTH` (both come from the same `.env` line) |
| "O canal whatsapp caiu" | Pair again (see above). After a temporary ban, wait until the time in the alert |
| A person in a group is never answered | Check that they mentioned or replied to the agent, and that the group is in `access.allowed_chats` |

Metrics: `whatsapp_lid_learned_total`, `whatsapp_unknown_lid_total`,
`whatsapp_account_down_total`, `channel_media_total{channel="whatsapp"}`.
