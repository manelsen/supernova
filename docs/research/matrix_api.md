# Matrix Client-Server API

**Especificação:** v1.17  
**Base URL:** Variável por homeserver

## Authentication

Login endpoint:
```
POST /_matrix/client/v3/login
{
  "type": "m.login.password",
  "identifier": {
    "type": "m.id.user",
    "user": "@user:domain.org"
  },
  "password": "password123"
}
```

Response:
```json
{
  "access_token": "token",
  "user_id": "@user:domain.org",
  "device_id": "device_id",
  "home_server": "domain.org"
}
```

## Sending Messages

Send message:
```
PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}
{
  "msgtype": "m.text",
  "body": "Hello world"
}
```

## Room Events

```json
{
  "type": "m.room.message",
  "sender": "@user:domain.org",
  "content": {
    "msgtype": "m.text",
    "body": "message text"
  },
  "room_id": "!room:domain.org",
  "event_id": "$event:domain.org",
  "origin_server_ts": 1234567890
}
```

## Endpoints Principais

### Sync
```
GET /_matrix/client/v3/sync
  ?filter=filter_id
  &timeout=30000
  &since=next_batch
```

### Rooms
- Create room: `POST /_matrix/client/v3/createRoom`
- Join room: `POST /_matrix/client/v3/join/{roomIdOrAlias}`
- Leave room: `POST /_matrix/client/v3/rooms/{roomId}/leave`
- Invite: `POST /_matrix/client/v3/rooms/{roomId}/invite`

### Messages
- Send message: `PUT /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}`
- Get messages: `GET /_matrix/client/v3/rooms/{roomId}/messages`

### Users
- Get profile: `GET /_matrix/client/v3/profile/{userId}`
- Set displayname: `PUT /_matrix/client/v3/profile/{userId}/displayname`
- Set avatar: `PUT /_matrix/client/v3/profile/{userId}/avatar_url`

## Typing Notifications

```
PUT /_matrix/client/v3/rooms/{roomId}/typing/{userId}
{
  "typing": true,
  "timeout": 30000
}
```

## Receipts

```
POST /_matrix/client/v3/rooms/{roomId}/receipt/m.read/{eventId}
{}
```

## Room Versions

Matrix supports multiple room versions with different features.

## Keys

- ED25519 signature for identity
- Curve25519 for Olm encryption
- Megolm for group encryption

## Rate Limiting

- 100 requests per 30 seconds per user
- 100 requests per 30 seconds per IP for registration
- Custom limits per homeserver

## Application Services

Bots via AS API:
```
POST /_matrix/client/v3/rooms/{roomId}/state/m.room.member/{userId}
{
  "membership": "join",
  "avatar_url": "mxc://...",
  "displayname": "Bot"
}
```
