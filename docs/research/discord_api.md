# Discord API Documentation

**Última atualização:** 2026-03  
**Versão:** v10 (current)  
**Base URL:** `https://discord.com/api`

## Authentication

Autenticação com Bot Token:
```bash
Authorization: Bot MTk4NjIyNDgzNDcxOTI1MjQ4.Cl2FMQ.ZnCjm1XVW7vRze4b7Cq4se7kKWs
```

## Snowflakes

IDs únicos no formato Twitter snowflake:
- 64 bits
- Timestamp: milissegundos desde Discord Epoch (2015-01-01)
- Composed of: timestamp + worker_id + process_id + increment

## API Versions

| Version | Status |
|---------|--------|
| v10 | Available |
| v9 | Available |
| v8 | Deprecated |
| v7 | Deprecated |
| v6 | Deprecated |

## Message Structure

```json
{
  "id": "snowflake_id",
  "channel_id": "snowflake_id",
  "guild_id": "snowflake_id (optional)",
  "author": {
    "id": "snowflake_id",
    "username": "string",
    "discriminator": "string",
    "avatar": "string (optional)",
    "bot": "boolean"
  },
  "content": "string",
  "timestamp": "ISO8601 timestamp",
  "edited_timestamp": "ISO8601 timestamp (optional)",
  "tts": "boolean",
  "mention_everyone": "boolean",
  "mentions": "array of user objects",
  "mention_roles": "array of role object snowflakes",
  "attachments": "array of attachment objects",
  "embeds": "array of embed objects",
  "reactions": "array of reaction objects",
  "pinned": "boolean",
  "type": "integer (message type)",
  "message_reference": {
    "guild_id": "snowflake (optional)",
    "channel_id": "snowflake",
    "message_id": "snowflake"
  }
}
```

## Webhook

```json
POST /webhooks/{webhook.id}/{webhook.token}
{
  "content": "message content",
  "username": "override username",
  "avatar_url": "override avatar URL",
  "tts": false,
  "embeds": []
}
```

## Rate Limits

- Global: 50 requests per second
- Per-route: varies

## Endpoints

### Messages
- `GET /channels/{channel_id}/messages` - List messages
- `POST /channels/{channel_id}/messages` - Send message
- `PATCH /channels/{channel_id}/messages/{message_id}` - Edit message
- `DELETE /channels/{channel_id}/messages/{message_id}` - Delete message

### Guilds
- `POST /guilds` - Create guild
- `GET /guilds/{guild.id}` - Get guild
- `PATCH /guilds/{guild.id}` - Modify guild

### Channels
- `GET /channels/{channel.id}` - Get channel
- `PATCH /channels/{channel.id}` - Modify channel
- `DELETE /channels/{channel.id}` - Delete channel

## Guilded Endpoints

### Messages
- Create message: `POST /channels/{channel_id}/messages`
- Edit message: `PATCH /channels/{channel_id}/messages/{message_id}`
- Delete message: `DELETE /channels/{channel_id}/messages/{message_id}`

### Threads
- Create thread: `POST /channels/{channel_id}/threads`
- Join thread: `PUT /channels/{channel_id}/thread-members/@me`
- Leave thread: `DELETE /channels/{channel_id}/thread-members/@me`

## Slash Commands

```json
POST /applications/{application_id}/guilds/{guild_id}/commands
{
  "name": "command_name",
  "description": "Command description",
  "options": [
    {
      "name": "option_name",
      "description": "Option description",
      "type": 3,  // STRING, INTEGER, BOOLEAN, USER, CHANNEL, MENTIONABLE, NUMBER
      "required": true
    }
  ]
}
```

## Intents

Required for gateway connection:
- GUILDS (1 << 0)
- GUILD_MESSAGES (1 << 9)
- DIRECT_MESSAGES (1 << 12)
- MESSAGE_CONTENT (1 << 15)
