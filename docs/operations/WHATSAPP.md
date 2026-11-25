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

GOWA offers two ways through its REST API: a code typed on the phone, or a
QR code. Both are asked for from the server, on GOWA's loopback port, with
the basic auth from `.env`. Neither GOWA's docs nor its readme say how long
a code or QR stays valid, so use it right away.

**With a code (simplest, no browser):**

1. On the server:

   ```
   curl -u "$SUPERNOVA_WHATSAPP_BASIC_AUTH" \
     "http://127.0.0.1:3000/app/login-with-code?phone=5511999999999"
   ```

   Use the agent's number with the country code, digits only. The answer
   carries `results.pair_code`, such as `ABCD-1234`.
2. On the agent's phone: WhatsApp → Linked devices → Link a device → **Link
   with phone number instead**, and type the code.

**With a QR code:**

1. On the server:

   ```
   curl -u "$SUPERNOVA_WHATSAPP_BASIC_AUTH" http://127.0.0.1:3000/app/login
   ```

   The answer carries `results.qr_link`, a PNG under `/statics/images/qrcode/`.
2. Open that image through an SSH tunnel (`ssh -L 3000:127.0.0.1:3000
   <server>`, then the link with `localhost:3000`), and scan it with the
   agent's phone (WhatsApp → Linked devices → Link a device).

**Then** send a message to the agent's number from an allowed person. The
log shows the turn. If nothing happens, see the troubleshooting section.

## People and groups

- A person on WhatsApp is `whatsapp:<phone>`, digits only, with the country
  code (`whatsapp:5511999999999`). Add people with `/acesso` or in
  `access.members`, like on Telegram.
- **Same agent as on Telegram.** A person who already talks to the agent
  elsewhere sends `/vincular` there, in private. They then send
  `/vincular CÓDIGO` to the agent's WhatsApp, also in private. From then on
  it is the same agent, with the same memory, on both channels.
  `/desvincular` undoes the link.
- **Groups are off.** Every conversation is in private: a message from a
  group is dropped unread, even a mention or a command, and the agent says
  nothing in the group. Metric `whatsapp_group_messages_dropped_total`.
  To turn groups on later, set `whatsapp.allow_groups: true`; groups are
  then authorized as `whatsapp:<group id>@g.us` in `access.allowed_chats`
  (or `/acesso chat` from inside the group), and the agent answers only
  when mentioned, when someone replies to it, or when the message is a
  command.
- **LIDs.** WhatsApp sometimes hides the phone behind a LID (`…@lid`).
  Supernova learns which phone a LID belongs to when both arrive together.
  With groups on, someone it does not recognize yet who calls it in a group
  is asked to write in private.
- **Images.** Images the person sends (up to 5 MB) reach the model once.
  The history keeps `[imagem]`. Audio and documents are not read yet.

## Troubleshooting

| Symptom | Look at |
|---|---|
| No turn when a message arrives | GOWA log: webhook errors. Supernova log: `401` means the two `WEBHOOK_SECRET` values differ |
| Replies fail with "Unauthorized" | `SUPERNOVA_WHATSAPP_BASIC_AUTH` differs from GOWA's `APP_BASIC_AUTH` (both come from the same `.env` line) |
| "O canal whatsapp caiu" | Pair again (see above). After a temporary ban, wait until the time in the alert |
| A person in a group is never answered | Groups are off by default (`whatsapp.allow_groups`). With them on: check that they mentioned or replied to the agent, and that the group is in `access.allowed_chats` |

Metrics: `whatsapp_lid_learned_total`, `whatsapp_unknown_lid_total`,
`whatsapp_account_down_total`, `whatsapp_group_messages_dropped_total`, `channel_media_total{channel="whatsapp"}`.
