# Telegram Bot API Documentation

**Última atualização:** 2026-03-26  
**Versão da API:** 9.5 (Março 1, 2026)  
**Fonte:** https://core.telegram.org/bots/api

## Resumo das Funcionalidades Principais

### 1. Autenticação
- Token único no formato: `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`
- HTTPS obrigatório
- Base URL: `https://api.telegram.org/bot<token>/METHOD_NAME`

### 2. Métodos Suportados
- GET e POST
- Formatos: URL query string, application/x-www-form-urlencoded, application/json, multipart/form-data

### 3. Receiving Updates
- **getUpdates**: Long polling
- **webhook**: Push notifications
- Updates armazenados por 24h

### 4. Tipos de Update
- message, edited_message
- channel_post, edited_channel_post
- callback_query (botões)
- inline_query
- chat_member, my_chat_member
- message_reaction, message_reaction_count

## Funcionalidades Relevantes para Supernova

### 1. Inline Keyboards (Botões Interativos)
```json
{
  "inline_keyboard": [
    [
      {"text": "Button 1", "callback_data": "btn1"},
      {"text": "Button 2", "callback_data": "btn2"}
    ]
  ]
}
```

### 2. Threading
- `reply_to_message_id`: Para responder a uma mensagem específica
- `message_thread_id`: Para tópicos em grupos
- Suporte a tópicos em chats privados (novo na API 9.3)

### 3. Message Metadata
- `message_id`: Identificador único
- `from`: Usuário que enviou
- `chat`: Chat onde foi enviada
- `date`: Timestamp Unix
- `reply_to_message`: Mensagem respondida

### 4. Callback Queries
- `callback_query.id`: ID único do callback
- `callback_query.from`: Usuário que pressionou
- `callback_query.message`: Mensagem original
- `callback_query.data`: Dados do botão

### 5. Rate Limits
- Mensagens em grupos: 20/minute
- Mensagens em canais: 30/minute para bots
- 30 messages/second em geral

## Integração com Supernova

### Mapeamento ChannelMessage → Telegram
```gleam
pub type TelegramMessage {
  TelegramMessage(
    update_id: Int,
    message: Option(Message),
    callback_query: Option(CallbackQuery),
    // ...
  )
}

pub fn to_channel_message(msg: TelegramMessage) -> ChannelMessage {
  ChannelMessage(
    id: msg.update_id.to_string(),
    channel: "telegram",
    channel_id: extract_channel_id(msg),
    user_id: extract_user_id(msg),
    username: extract_username(msg),
    content: extract_content(msg),
    is_bot: is_from_bot(msg),
    reply_to_id: extract_reply_to_id(msg),
  )
}
```

### Mapeamento ChannelReply → Telegram
```gleam
pub fn from_channel_reply(reply: ChannelReply) -> TelegramSendMessage {
  case reply {
    TextReply(content, reply_to_id) -> 
      SendMessage(text: content, reply_to_message_id: reply_to_id)
    
    InteractiveReply(content, components, reply_to_id) ->
      SendMessage(
        text: content,
        reply_to_message_id: reply_to_id,
        reply_markup: build_inline_keyboard(components)
      )
  }
}
```

## Novidades na API 9.5

### 1. MessageEntity "date_time"
- Mostrar data e hora formatada

### 2. sendMessageDraft
- Streaming parcial de mensagens

### 3. Custom Emoji em Botões
- `icon_custom_emoji_id` em botões

### 4. Button Styles
- Campo `style` para mudar cor dos botões

### 5. Topics in Private Chats
- Tópicos em chats privativos
- `message_thread_id` suportado
