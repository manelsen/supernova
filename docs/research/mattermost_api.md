# Mattermost API Documentation

**Documentação:** https://docs.mattermost.com/  
**API Reference:** https://api.mattermost.com/

## Authentication

Bearer token:
```bash
Authorization: Bearer token
```

## WebSocket Gateway

```
wss://your-server.com/api/v4/websocket
```

## Message Structure

```json
{
  "id": "message_id",
  "channel_id": "channel_id",
  "team_id": "team_id",
  "user_id": "user_id",
  "root_id": "parent_id",
  "parent_id": "parent_id",
  "create_at": 1234567890,
  "update_at": 1234567890,
  "edit_at": 1234567890,
  "delete_at": 0,
  "is_pinned": false,
  "user_id": "user_id",
  "channel_id": "channel_id",
  "original_id": "",
  "message": "message content",
  "type": "",
  "props": {},
  "hashtags": "",
  "pending_post_id": ""
}
```

## Endpoints

### Posts
- `GET /posts` - List posts
- `POST /posts` - Create post
- `PUT /posts/{post_id}` - Update post
- `DELETE /posts/{post_id}` - Delete post

### Channels
- `GET /channels` - List channels
- `POST /channels` - Create channel
- `GET /channels/{channel_id}` - Get channel
- `PUT /channels/{channel_id}` - Update channel
- `DELETE /channels/{channel_id}` - Delete channel

### Teams
- `GET /teams` - List teams
- `POST /teams` - Create team
- `GET /teams/{team_id}` - Get team

### Users
- `GET /users` - List users
- `POST /users` - Create user
- `GET /users/{user_id}` - Get user
- `PUT /users/{user_id}` - Update user

## Webhooks

### Incoming Webhooks
```json
POST /hooks/incoming/create
{
  "channel_id": "channel_id",
  "team_id": "team_id",
  "display_name": "Webhook Name",
  "description": "Description"
}
```

### Outgoing Webhooks
```json
POST /hooks/outgoing/create
{
  "channel_id": "channel_id",
  "team_id": "team_id",
  "callback_urls": ["https://callback.url"],
  "trigger_words": ["word1", "word2"]
}
```

## Message Attachments

```json
{
  "message": "Optional text",
  "props": {
    "attachments": [
      {
        "fallback": "Required plain-text",
        "color": "#FF0000",
        "pretext": "Pretext",
        "author_name": "Author",
        "author_icon": "https://icon.url",
        "title": "Title",
        "title_link": "https://link.com",
        "text": "Text content",
        "fields": [
          {
            "short": true,
            "title": "Field Title",
            "value": "Field Value"
          }
        ],
        "image_url": "https://image.url",
        "footer": "Footer"
      }
    ]
  }
}
```

## Slash Commands

Create via API or UI:
```
/command arg1 arg2
```

## React with Built-in Emojis

```json
POST /reactions
{
  "user_id": "user_id",
  "post_id": "post_id",
  "emoji_name": "smile"
}
```

## Threading

Mattermost v10+ supports threads:
- Reply in thread via `root_id` field
- GET /threads - List threads
- GET /threads/{thread_id} - Get thread
- POST /threads/{thread_id}/follow - Follow thread
- DELETE /threads/{thread_id}/follow - Unfollow thread

## Mattermost Plugins

Extend functionality via plugins:
- React components
- REST API endpoints
- Slash commands
- Webhooks
- Sidebar components

## Rate Limits

- Default: varies by plan
- Enterprise: configurable

## Mattermost v11 Features

- Enhanced threading
- Better mobile experience
- Improved search
- Performance improvements
