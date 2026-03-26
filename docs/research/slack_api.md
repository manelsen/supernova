# Slack Web API Documentation

**Última atualização:** 2026-03-26  
**Fonte:** https://docs.slack.dev/apis/web-api/

## Resumo das Funcionalidades Principais

### 1. Autenticação
- Bearer tokens no formato: `xoxb-1234-56789abcdefghijklmnop`
- OAuth 2.0
- Tokens no header `Authorization: Bearer <token>`

### 2. Métodos HTTP
- GET e POST
- Formatos suportados:
  - URL-encoded (`application/x-www-form-urlencoded`)
  - JSON (`application/json`) - recomendado para métodos complexos

### 3. Base URL
- `https://slack.com/api/METHOD_FAMILY.method`

### 4. Response Format
```json
{
  "ok": true,
  "stuff": "data"
}
```

## Funcionalidades Relevantes para Supernova

### 1. Interactive Components
- **Buttons**: `action_id` + `value`
- **Select Menus**: Static, external, users, conversations, channels
- **Modals**: Views complexas com múltiplos inputs

### 2. Block Kit (Componentes Visuais)
```json
{
  "blocks": [
    {
      "type": "section",
      "text": {"type": "mrkdwn", "text": "Text"},
      "accessory": {
        "type": "button",
        "action_id": "button_id",
        "text": {"type": "plain_text", "text": "Click me"}
      }
    }
  ]
}
```

### 3. Threading
- `thread_ts`: Timestamp da mensagem principal
- `reply_broadcast`: Responder em thread e broadcast

### 4. Message Metadata
- `ts`: Timestamp único da mensagem
- `channel`: ID do canal
- `user`: ID do usuário
- `text`: Conteúdo da mensagem
- `blocks`: Componentes estruturados

### 5. Events API
- **message**: Mensagens recebidas
- **app_mention**: Menção ao bot
- **interactive**: Interações com componentes

### 6. Rate Limits
- Tier 1: 1+ requests/minute
- Tier 2: 20+ requests/minute
- Tier 3: 50+ requests/minute
- Tier 4: 100+ requests/minute

## Integração com Supernova

### Mapeamento ChannelMessage → Slack
```gleam
pub type SlackEvent {
  SlackEvent(
    type: String,
    user: String,
    channel: String,
    text: String,
    ts: String,
    thread_ts: Option(String),
    blocks: Option(List(Block)),
  )
}

pub fn to_channel_message(event: SlackEvent) -> ChannelMessage {
  ChannelMessage(
    id: event.ts,
    channel: "slack",
    channel_id: event.channel,
    user_id: event.user,
    username: get_username(event.user),
    content: event.text,
    is_bot: False,
    reply_to_id: event.thread_ts,
  )
}
```

### Mapeamento ChannelReply → Slack
```gleam
pub fn from_channel_reply(reply: ChannelReply) -> SlackMessagePost {
  case reply {
    TextReply(content, reply_to_id) ->
      MessagePost(
        channel: channel_id,
        text: content,
        thread_ts: reply_to_id,
      )
    
    InteractiveReply(content, components, reply_to_id) ->
      MessagePost(
        channel: channel_id,
        text: content,
        thread_ts: reply_to_id,
        blocks: build_blocks(components)
      )
  }
}
```

## Diferenças Importantes vs Telegram

### 1. Estrutura de Mensagens
- Slack usa **Block Kit** (estruturado)
- Telegram usa **Inline Keyboards** (simples)

### 2. Threading
- Slack: `thread_ts` (timestamp)
- Telegram: `reply_to_message_id` (int)

### 3. Componentes
- Slack: Ação via `action_id`
- Telegram: Ação via `callback_data`

### 4. Rate Limits
- Slack: Por tier (1-100+ requests/min)
- Telegram: Fixo (20-30/min para grupos)
