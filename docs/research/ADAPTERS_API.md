# Channel Adapters API Reference

This document contains API reference information for implementing channel adapters.

---

## Matrix Client-Server API

**Spec**: [spec.matrix.org/v1.12/client-server-api](https://spec.matrix.org/v1.12/client-server-api/)

### Sending Messages

**Endpoint**: `PUT /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}`

```
PUT /_matrix/client/v3/rooms/%21roomId%3Aexample.org/send/m.room.message/txn_count
Authorization: Bearer {access_token}
Content-Type: application/json

{
  "body": "Hello World!",
  "msgtype": "m.notice"
}
```

**Response**:
```json
{
  "event_id": "$event_id"
}
```

### Authentication

1. **Login** (username/password or SSO):
   ```
   POST /_matrix/client/v3/login
   {
     "type": "m.login.password",
     "identifier": { "type": "m.id.user", "user": "user" },
     "password": "password"
   }
   ```

2. **Access Token**: Response contains `access_token` for subsequent requests.

3. **Include in requests**:
   ```
   Authorization: Bearer {access_token}
   ```

### Key Concepts

| Concept | Description |
|---------|-------------|
| `roomId` | Room identifier (e.g., `!roomId:server.org`) |
| `eventType` | Event type (e.g., `m.room.message`) |
| `txnId` | Unique transaction ID (client-generated, prevents duplicates) |
| `msgtype` | `m.text` (user), `m.notice` (bot) |
| `userId` | User identifier (e.g., `@user:server.org`) |

### Receiving Messages (Sync Loop)

**Endpoint**: `GET /_matrix/client/v3/sync`

```
GET /_matrix/client/v3/sync?since={next_batch}&timeout=30000
Authorization: Bearer {access_token}
```

**Response** contains `rooms.join.{roomId}.timeline.events`.

### Server Discovery

```
GET /.well-known/matrix/client
```

Returns:
```json
{
  "m.homeserver": { "base_url": "https://matrix.example.org" }
}
```

---

## WhatsApp Web Multi-Device Protocol

**Libraries**: [whatsmeow (Go)](https://github.com/tulir/whatsmeow), [Baileys (Node.js)](https://github.com/WhiskeySockets/baileys)

This is the **unofficial WhatsApp Web protocol** used by web.whatsapp.com. It is completely different from the official WhatsApp Cloud API.

### Architecture

```
┌─────────────────┐     WebSocket      ┌─────────────────┐
│  Your App       │◄──────────────────►│  WhatsApp       │
│  (whatsmeow)    │    wss://w SSR     │  Servers        │
└─────────────────┘                    └─────────────────┘
```

### Connection Flow

1. **Generate QR Code**: App connects and gets QR code data
2. **Scan QR**: User scans with WhatsApp mobile app
3. **Pairing**: Mobile app approves pairing
4. **Authenticated Session**: WebSocket connection established
5. **Message Exchange**: Send/receive via binary protocol (Protobuf)

### Key Concepts

| Concept | Description |
|---------|-------------|
| `JID` | WhatsApp user ID (e.g., `123456789@s.whatsapp.net`) |
| `Device ID` | Unique device identifier |
| `Session` | Encrypted session with WhatsApp servers |
| `txMsgId` | Transaction message ID for idempotency |

### Sending Messages (via library, not raw HTTP)

```go
// Example with whatsmeow (Go)
// Client sends message via library methods, not HTTP

client.SendMessage(ctx, jid, &waProto.Message{
    Conversation: utils.String("Hello from WhatsApp!"),
})
```

### Receiving Messages

```go
// Listen for incoming messages
client.AddEventHandler(func(evt *waEvent.Message) {
    fmt.Printf("Received from %s: %s\n", 
        evt.Info.MessageSource.Sender,
        evt.Message.GetConversation())
})
```

### Implementation Options

| Option | Library | Language | Notes |
|--------|---------|----------|-------|
| Direct | [whatsmeow](https://github.com/tulir/whatsmeow) | Go | Most mature |
| Direct | [Baileys](https://github.com/WhiskeySockets/baileys) | TypeScript | Popular, well-maintained |
| Direct | [waProto](https://github.com/dtpnk/waProto) | Python | Protobuf definitions |
| Server-based | [go-whatsapp-web-multidevice](https://github.com/aldinokemal/go-whatsapp-web-multidevice) | Go | REST API wrapper |

### Server-Based REST API (Alternative)

If you don't want to implement the raw protocol, use **go-whatsapp-web-multidevice**:

**Base URL**: `http://localhost:3000` (default)

#### Authentication
- Basic Auth: `--basic-auth=user:pass`

#### Connection Management

```bash
# Generate QR code for login
GET /app/login

# Or login with pairing code (phone number)
GET /app/login-with-code?phone=628912344551

# Check connection status
GET /app/status

# Logout
GET /app/logout
```

#### Sending Messages

```bash
# Send text message
POST /send/text
{
  "chat_id": "628123456789@s.whatsapp.net",
  "text": "Hello from WhatsApp!"
}

# Send image
POST /send/image
{
  "chat_id": "628123456789@s.whatsapp.net",
  "image": "https://example.com/image.jpg",
  "caption": "Check this out!"
}
```

#### Webhook for Incoming Messages

```bash
# Configure webhook
--webhook="http://yourserver.com/webhook"
--webhook-secret="secret"
```

**Webhook payload**:
```json
{
  "event": "message",
  "device_id": "628123456789@s.whatsapp.net",
  "payload": {
    "key": {
      "remoteJid": "628123456789@s.whatsapp.net",
      "id": "XYZ123"
    },
    "message": {
      "conversation": "Hello!"
    },
    "messageTimestamp": "1700000000"
  }
}
```

---

## Mattermost API

**Docs**: [api.mattermost.com](https://api.mattermost.com/)

**Base URL**: `{your-mattermost-url}/api/v4`

### Authentication

```
Authorization: Bearer {USER_ACCESS_TOKEN}
```

Or with username/password login:
```
POST /api/v4/users/login
{
  "login_id": "user@example.com",
  "password": "password"
}
```
Response contains `token` for subsequent requests.

### Sending Messages (Create Post)

**Endpoint**: `POST /api/v4/posts`

```json
POST /api/v4/posts
Authorization: Bearer {TOKEN}
Content-Type: application/json

{
  "channel_id": "{CHANNEL_ID}",
  "message": "Hello from Mattermost!",
  "props": {}
}
```

**Response**:
```json
{
  "id": "post_id",
  "create_at": 1234567890,
  "update_at": 1234567890,
  "channel_id": "{CHANNEL_ID}",
  "user_id": "{USER_ID}",
  "message": "Hello from Mattermost!"
}
```

### Key Concepts

| Concept | Description |
|---------|-------------|
| `channel_id` | Channel identifier (36-char UUID) |
| `team_id` | Team identifier for team-scoped operations |
| `user_id` | User identifier |
| `post_id` | Post/message identifier |

### Getting Channels

**Endpoint**: `GET /api/v4/channels`

Query params: `team_id`, `private`, `direct`, `include_deleted`

```json
GET /api/v4/channels?team_id={TEAM_ID}
Authorization: Bearer {TOKEN}
```

### Creating Webhooks (Alternative)

**Incoming Webhook**: Receives messages from external sources
```
POST /api/v4/hooks/incoming/create
```

**Outgoing Webhook**: Sends messages to external services on events
```
POST /api/v4/hooks/outgoing/create
```

### File Uploads

**Endpoint**: `POST /api/v4/files`

```json
POST /api/v4/files
Authorization: Bearer {TOKEN}
Content-Type: multipart/form-data

file=@{file}
```

### Message Attachments

```json
{
  "channel_id": "{CHANNEL_ID}",
  "message": "Check this out!",
  "props": {
    "attachments": [{
      "fallback": "Required plain text",
      "color": "#36a64f",
      "title": "Title",
      "title_link": "https://example.com",
      "text": "Description text",
      "fields": [
        { "short": true, "title": "Field 1", "value": "Value 1" }
      ]
    }]
  }
}
```

---

## Implementation Checklist

### Matrix
- [ ] Obtain homeserver URL
- [ ] Implement login flow to get access token
- [ ] Store access token securely
- [ ] Implement sync loop for receiving messages
- [ ] Implement message sending with transaction IDs
- [ ] Handle room joins and invitations
- [ ] Implement reconnection logic

### WhatsApp Web MD
- [ ] Choose implementation approach (direct library vs server)
- [ ] For direct: Use whatsmeow (Go) or Baileys (TypeScript)
- [ ] Generate/serve QR code for login
- [ ] Handle QR code scanning and pairing
- [ ] Implement message sending via library
- [ ] Add event handler for incoming messages
- [ ] Implement reconnection logic
- [ ] Store session data for reconnection

**Alternative (server-based)**:
- [ ] Deploy go-whatsapp-web-multidevice
- [ ] Configure Basic Auth
- [ ] Implement login (QR code or pairing code)
- [ ] Send messages via REST API
- [ ] Configure webhook for incoming messages
- [ ] Handle webhook authentication

### Mattermost
- [ ] Obtain Mattermost instance URL
- [ ] Create bot account or user account
- [ ] Get user access token
- [ ] Get channel ID for posting
- [ ] Implement webhook endpoint (alternative to bot)
- [ ] Implement message sending
- [ ] Handle file uploads if needed
