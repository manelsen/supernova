# QQ Bot API Documentation

**官方文档:** https://bot.q.qq.com  
**API版本:** v2

## Authentication

### Credentials

| 名称 | 描述 |
|------|------|
| AppID | 机器人 ID (必需) |
| AppSecret | 机器人密钥 |
| AccessToken | OAuth token (废弃) |

## WebSocket Gateway

连接方式:
```
wss://api.sgroup.qq.com/websocket
```

### Handshake

```json
{
  "op": 2,
  "d": {
    "token": "qq.access_token",
    "intents": 1,
    "shard": [0, 1],
    "properties": {
      "$os": "linux",
      "$browser": "supernova",
      "$device": "supernova"
    }
  }
}
```

## Message Structure

```json
{
  "id": "message_id",
  "channel_id": "channel_id",
  "guild_id": "guild_id",
  "content": "message content",
  "timestamp": "ISO8601",
  "author": {
    "id": "user_id",
    "username": "name",
    "avatar": "avatar_url"
  },
  "member": {
    "roles": ["role_id"],
    "nick": "nickname"
  }
}
```

## Intents

| Intent | Value | Description |
|--------|-------|-------------|
| GUILDS | 1 << 0 | Guild events |
| GUILD_MESSAGES | 1 << 9 | Message events |
| DIRECT_MESSAGES | 1 << 12 | DM events |
| MESSAGE_AUDIT | 1 << 27 | Message audit |

## SDKs Disponíveis

- **Go:** [botgo](https://github.com/tencent-connect/botgo)
- **Python:** [botpy](https://github.com/tencent-connect/botpy)
- **Node.js:** [bot-node-sdk](https://github.com/tencent-connect/bot-node-sdk)

## Rate Limits

- Default: 50 requests/second
- Varies by endpoint

## Message Types

- `0` - Text message
- `2` - Image
- `3` - Audio/Markdown
- `4` - Video
- `7` - Red packet
- `8` - Poke (戳一戳)
- `9` - Reply
- `10` - Gift
- `12` - Forward/Share

## Channels

| Channel Type | Value |
|-------------|-------|
| TEXT | 1 |
| VOICE | 2 |
| CATEGORY | 4 |
| NEWS | 5 |
| SCHEDULE | 7 |
| IMAGE | 10 |

## Guild/Channel Structure

```
Guild
├── channels[] - 子频道
├── roles[] - 身份组
└── members[] - 成员
```

## Rich Media Messages

使用 `files.create` 上传获取 file_key，然后发送:
```json
{
  "content": "{\"file_key\": \"file_key\", \"filename\": \"name\", \"srv_id\": \"id\", \"md5\": \"md5\"}",
  "msg_type": 2  // 2 = image
}
```
