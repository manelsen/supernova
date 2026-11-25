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
## What the agent opens

Nothing a person sends disappears. Each kind becomes something the agent
can answer:

| The person sends | The agent gets |
|---|---|
| Text | The text |
| Image, still sticker | The image itself, with Amélie's audio description rules for when the person asked nothing else |
| Voice note, audio | A literal transcription ("[mensagem de voz de 0:42, transcrita]" and the text) |
| Video, round video | An audio description with the speech transcribed |
| Document (PDF, Word, Excel, PowerPoint, text) | Its content, with what matters first: amount, due date and full barcode line of a bill; parties and terms of a contract |
| Animated sticker | A description of the animation, read from up to eight frames |
| Location, contact, poll | Text: "[localização: …]", "[contato: …]", "[enquete: …]" |

Audio, video, documents and animated stickers are read before the turn by a
Gemini model (`media.reader_model`, `gemini-3.5-flash-lite`, with
`SUPERNOVA_GEMINI_API_KEY`), using Amélie's media prompts. The text takes
the medium's place: it stays in the conversation and the memory, the agent
can search it later, and `/esquecer` erases it. Images go to the agent's
own model. Without the Gemini key, these become a note the agent answers
("[uma mensagem de voz de 0:42, que ainda não consigo ouvir]").

Every reading is admitted in the ledger first and charged to the person
(US$ 0.30 per million input tokens, US$ 2.50 per million output tokens):
about US$ 0.001 for a one-minute voice note, US$ 0.003 for an animated
sticker. A stranger's media is never read: it costs nothing, and the gate
answers them as usual. A reading that fails, or a day's budget that ran
out, becomes a note with the reason. The file is deleted once read.

Animated stickers are split into frames with Pillow
(`priv/media/sticker_frames.py`): Gemini sees only the first frame of an
animated WebP. The image installs `python3` and `py3-pillow`.

## Commands for how the agent answers

Each is a preference of the person, kept in their agent folder and erased
by `/esquecer`.

| Command | What it does |
|---|---|
| `/voz` | Answers come as voice notes (Gemini TTS, voice `media.voice`, Sulafat by default), cited to the person's message. Again to go back to text. If speaking fails, the answer goes as text. |
| `/transcricao` | Your own voice notes also come back transcribed before the answer. |
| `/curto`, `/longo` | Short or complete descriptions of images, videos and documents. |
| `/cego` | Turns the complete audio description on and off. |

A forwarded audio, alone, comes back as its transcription ("Transcrição do
áudio" … "Fim da transcrição"), without the model: the use case is reading
someone else's long audio instead of listening to it. The exchange stays in
the history. Speech costs US$ 0.50 per million input tokens and US$ 6.00
per million audio tokens through 31/12/2026 (about US$ 0.01 a minute), and
twice that from 1/1/2027.

## When the number falls

When GOWA reports `device.logged_out`, the admins get an alert on another
channel (never through WhatsApp itself; Telegram in the pilot) that already
carries a new pairing code: "Para reconectar, no celular da agente:
WhatsApp → Aparelhos conectados → Conectar aparelho → Conectar com número
de telefone, e digite o código …". `SUPERNOVA_WHATSAPP_DEVICE_ID` gives the
number. If the code expires, an admin sends `/parear` (on Telegram) for a
new one. A temporary ban keeps the session; the alert says until when.

## Troubleshooting

| Symptom | Look at |
|---|---|
| No turn when a message arrives | GOWA log: webhook errors. Supernova log: `401` means the two `WEBHOOK_SECRET` values differ |
| Replies fail with "Unauthorized" | `SUPERNOVA_WHATSAPP_BASIC_AUTH` differs from GOWA's `APP_BASIC_AUTH` (both come from the same `.env` line) |
| "O WhatsApp caiu" | Type the code from the alert on the agent's phone, or `/parear` for a new one. After a temporary ban, wait until the time in the alert |
| Audio comes as "que ainda não consigo ouvir" | `SUPERNOVA_GEMINI_API_KEY` is not set, or `media.audio: off` |
| Animated stickers come as notes | `python3` or `py3-pillow` missing in the image ("Pillow is not installed" in the note) |
| A person in a group is never answered | Groups are off by default (`whatsapp.allow_groups`). With them on: check that they mentioned or replied to the agent, and that the group is in `access.allowed_chats` |

Metrics: `whatsapp_lid_learned_total`, `whatsapp_unknown_lid_total`,
`whatsapp_account_down_total`, `whatsapp_group_messages_dropped_total`,
`channel_media_total{channel="whatsapp"}`. Media readings and speech show in
the ledger as `gemini` usage of the person.
