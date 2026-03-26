# Google Chat API

**Base URL:** `https://chat.googleapis.com/v1`

## Authentication

OAuth 2.0 with scope: `https://www.googleapis.com/auth/chat.bot`

## Spaces (Rooms)

### List spaces
```
GET /spaces
```

### Create space
```
POST /spaces
{
  "displayName": "Space Name",
  "type": "SPACE"  // or "DIRECT_MESSAGE"
}
```

### Get space
```
GET /spaces/{spaceId}
```

## Messages

### Create message
```
POST /spaces/{spaceId}/messages
{
  "text": "Hello!",
  "cards": [
    {
      "header": {
        "title": "Card Title",
        "subtitle": "Subtitle"
      },
      "sections": [
        {
          "widgets": [
            {
              "textParagraph": {
                "text": "Paragraph text"
              }
            }
          ]
        }
      ]
    }
  ]
}
```

### Reply to thread
```
POST /spaces/{spaceId}/messages
{
  "text": "Reply text",
  "thread": {
    "replyToMessage": "originalMessageId"
  }
}
```

## Interactive Cards

### Button
```json
{
  "action": {
    "actionMethodName": "buttonClick",
    "parameters": [
      {
        "key": "buttonParam",
        "value": "buttonValue"
      }
    ]
  },
  "onClick": {
    "openLink": {
      "url": "https://example.com"
    }
  }
}
```

### Text Input
```json
{
  "name": "text_input",
  "textInput": {
    "label": "Enter text",
    "type": "SINGLE_LINE"
  }
}
```

## Events

Webhook payload:
```json
{
  "type": "MESSAGE",
  "eventTime": "2026-03-26T12:00:00Z",
  "space": {
    "name": "spaces/xxx",
    "type": "DM"
  },
  "message": {
    "name": "messages/xxx",
    "sender": {
      "name": "users/xxx",
      "displayName": "User"
    },
    "text": "Hello"
  }
}
```

## Threading

Reply in thread:
```
POST /spaces/{spaceId}/messages
{
  "text": "Reply",
  "thread": {
    "replyToMessage": "parentMessageId"
  }
}
```

## Member Management

### List members
```
GET /spaces/{spaceId}/members
```

### Create membership
```
POST /spaces/{spaceId}/members
{
  "member": {
    "user": {
      "name": "users/{userId}"
    }
  }
}
```

## Rate Limits

- Default: 10,000 requests/day
- Per-project: varies by endpoint
