# Lark/Feishu API Documentation

**Base URL:** `https://open.feishu.cn` ou `https://open.larksuite.com`

## Authentication

### Self-built App
```javascript
const client = new lark.Client({
  appId: 'app_id',
  appSecret: 'app_secret'
});
```

### Store App
```javascript
const client = new lark.Client({
  appId: 'app_id',
  appSecret: 'app_secret',
  appType: lark.AppType.ISV
});
```

## Send Message

```javascript
const res = await client.im.message.create({
  params: {
    receive_id_type: 'chat_id',
  },
  data: {
    receive_id: 'chat_id',
    msg_type: 'text',
    content: JSON.stringify({ text: 'Hello' })
  }
});
```

## Message Types

- `text` - Plain text
- `post` - Rich text with markdown
- `image` - Image by key
- `file` - File by key
- `audio` - Audio
- `media` - Video
- `sticker` - Sticker
- `interactive` - Cards with interactive elements

## Receive Messages

Subscribe to events via webhook or long polling.

### Webhook Event Structure
```json
{
  "schema": "2.0",
  "header": {
    "event_id": "event_id",
    "event_type": "im.message.receive_v1",
    "create_time": "timestamp",
    "token": "token",
    "app_id": "app_id",
    "tenant_key": "tenant_key"
  },
  "event": {
    "sender": {
      "sender_id": {
        "open_id": "open_id",
        "user_id": "user_id",
        "union_id": "union_id"
      },
      "sender_type": "user" | "bot",
      "tenant_key": "tenant_key"
    },
    "message": {
      "message_id": "message_id",
      "root_id": "root_id",
      "parent_id": "parent_id",
      "create_time": "timestamp",
      "chat_id": "chat_id",
      "chat_type": "p2p" | "group",
      "message_type": "text" | "post" | ...
      "content": "message_content"
    }
  }
}
```

## Interactive Cards

```json
{
  "msg_type": "interactive",
  "card": {
    "header": {
      "title": {
        "tag": "plain_text",
        "content": "Title"
      },
      "template": "blue"
    },
    "elements": [
      {
        "tag": "div",
        "text": {
          "tag": "lark_md",
          "content": "Content"
        }
      },
      {
        "tag": "action",
        "actions": [
          {
            "tag": "button",
            "text": {
              "tag": "plain_text",
              "content": "Click"
            },
            "type": "primary",
            "action_type": "click",
            "value": {}
          }
        ]
      }
    ]
  }
}
```

## Rate Limits

Varies by endpoint and plan.

## Resources

- Messages: `POST /im/v1/messages`
- Chats: `GET /chat/v4/chats`
- Users: `GET /contact/v3/users`
- Files upload: `POST /im/v1/files`
