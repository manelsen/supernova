//// Telegram Bot API Client Module
//// Provides:
//// - HTTP client for Telegram Bot API using gleam_http + gleam_hackney
//// - Long polling for receiving updates via get_updates/1
//// - Parser for Update objects (messages, callbacks, etc.)
//// - Polling loop with configurable interval and offset management
////
//// This module uses an actor pattern to manage polling state.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import gleam/uri

// ============================================================================
// Constants
// ============================================================================

/// Telegram Bot API base URL
pub const api_base_url = "https://api.telegram.org/bot"

// ============================================================================
// Types - Chat and User
// ============================================================================

/// Telegram Chat ID
pub type ChatId =
  String

/// Telegram User ID
pub type UserId =
  String

/// Telegram Chat Type
pub type ChatType {
  PrivateChat
  GroupChat
  SupergroupChat
  ChannelChat
}

/// Telegram Chat
pub type Chat {
  Chat(
    id: ChatId,
    chat_type: ChatType,
    title: Option(String),
    username: Option(String),
    first_name: Option(String),
    last_name: Option(String),
  )
}

/// Telegram User
pub type User {
  User(
    id: UserId,
    is_bot: Bool,
    first_name: String,
    last_name: Option(String),
    username: Option(String),
    language_code: Option(String),
  )
}

// ============================================================================
// Types - Messages
// ============================================================================

/// Telegram Message Entity Type
pub type MessageEntityType {
  MentionEntity
  HashtagEntity
  CashtagEntity
  BotCommandEntity
  UrlEntity
  EmailEntity
  PhoneNumberEntity
  BoldEntity
  ItalicEntity
  UnderlineEntity
  StrikethroughEntity
  SpoilerEntity
  CodeEntity
  PreEntity
  TextLinkEntity
  TextMentionEntity
  CustomEmojiEntity
}

/// Telegram Message Entity
pub type MessageEntity {
  MessageEntity(
    entity_type: MessageEntityType,
    offset: Int,
    length: Int,
    url: Option(String),
    user: Option(User),
    language: Option(String),
    custom_emoji_id: Option(String),
  )
}

/// Telegram Message (without recursive reply_to_message to avoid circular decoder issues)
pub type Message {
  Message(
    message_id: Int,
    from: Option(User),
    sender_chat: Option(Chat),
    date: Int,
    chat: Chat,
    forward_from: Option(User),
    forward_date: Option(Int),
    text: Option(String),
    caption: Option(String),
    entities: List(MessageEntity),
    caption_entities: List(MessageEntity),
    reply_to_message_id: Option(Int),
  )
}

// ============================================================================
// Types - Callbacks and Inline
// ============================================================================

/// Telegram Callback Query
pub type CallbackQuery {
  CallbackQuery(
    id: String,
    from: User,
    message: Option(Message),
    inline_message_id: Option(String),
    chat_instance: String,
    data: Option(String),
    game_short_name: Option(String),
  )
}

// ============================================================================
// Types - Updates
// ============================================================================

/// Telegram Update
pub type Update {
  Update(
    update_id: Int,
    message: Option(Message),
    edited_message: Option(Message),
    channel_post: Option(Message),
    edited_channel_post: Option(Message),
    inline_query: Option(InlineQuery),
    chosen_inline_result: Option(ChosenInlineResult),
    callback_query: Option(CallbackQuery),
    poll_answer: Option(PollAnswer),
    message_reaction: Option(MessageReaction),
  )
}

/// Telegram Inline Query
pub type InlineQuery {
  InlineQuery(
    id: String,
    from: User,
    query: String,
    offset: String,
    chat_type: Option(ChatType),
  )
}

/// Telegram Chosen Inline Result
pub type ChosenInlineResult {
  ChosenInlineResult(
    result_id: String,
    from: User,
    location: Option(Location),
    inline_message_id: Option(String),
    query: String,
  )
}

/// Telegram Location
pub type Location {
  Location(latitude: Float, longitude: Float)
}

/// A single reaction (emoji, custom emoji, or paid star)
pub type ReactionType {
  ReactionType(
    reaction_type: String,
    emoji: Option(String),
    custom_emoji_id: Option(String),
  )
}

/// Poll answer submitted by a user
pub type PollAnswer {
  PollAnswer(poll_id: String, user: Option(User), option_ids: List(Int))
}

/// Reaction change on a message
pub type MessageReaction {
  MessageReaction(
    chat: Chat,
    message_id: Int,
    user: Option(User),
    date: Int,
    old_reaction: List(ReactionType),
    new_reaction: List(ReactionType),
  )
}

// ============================================================================
// Types - API Response
// ============================================================================

/// Telegram API Response
pub type TelegramResponse(a) {
  TelegramResponse(ok: Bool, result: a, description: Option(String))
}

// ============================================================================
// Types - Configuration
// ============================================================================

/// Telegram Bot Configuration
pub type Config {
  Config(
    token: String,
    polling_timeout: Int,
    polling_interval: Int,
    allowed_updates: List(String),
  )
}

// ============================================================================
// Types - Polling State
// ============================================================================

/// Polling State
pub type PollingState {
  PollingState(config: Config, offset: Int, is_running: Bool)
}

/// Polling Message
pub type PollingMessage {
  GetUpdates(reply_to: Subject(Result(List(Update), TelegramError)))
  StartPolling(reply_to: Subject(Result(Nil, TelegramError)))
  StopPolling(reply_to: Subject(Result(Nil, TelegramError)))
  SetOffset(reply_to: Subject(Result(Nil, TelegramError)), offset: Int)
  GetState(reply_to: Subject(PollingState))
}

/// Telegram Poller Actor
pub type Poller =
  Subject(PollingMessage)

// ============================================================================
// Types - Parse Mode
// ============================================================================

/// Telegram Parse Mode for message formatting
pub type ParseMode {
  ParseModeNone
  ParseModeMarkdown
  ParseModeMarkdownV2
  ParseModeHTML
}

// ============================================================================
// Types - Chat Action
// ============================================================================

/// Telegram Chat Action for send_chat_action
pub type ChatAction {
  TypingAction
  UploadPhotoAction
  RecordVideoAction
  UploadVideoAction
  RecordVoiceAction
  UploadVoiceAction
  UploadDocumentAction
  ChooseStickerAction
  FindLocationAction
  RecordVideoNoteAction
  UploadVideoNoteAction
}

// ============================================================================
// Types - Send Message Options
// ============================================================================

/// Options for sending messages
pub type SendMessageOptions {
  SendMessageOptions(
    parse_mode: ParseMode,
    disable_notification: Bool,
    reply_to_message_id: Option(Int),
    message_thread_id: Option(Int),
    protect_content: Bool,
    reply_markup: Option(ReplyMarkup),
  )
}

/// Reply markup supported by send/edit message requests.
pub type ReplyMarkup {
  InlineKeyboardMarkup(inline_keyboard: List(List(InlineKeyboardButton)))
}

/// Inline keyboard button.
pub type InlineKeyboardButton {
  InlineKeyboardButton(text: String, callback_data: String)
}

// ============================================================================
// Types - Sent Message
// ============================================================================

/// Result from sending a message
pub type SentMessage {
  SentMessage(message_id: Int, chat: Chat, date: Int, text: Option(String))
}

// ============================================================================
// Types - Errors
// ============================================================================

/// Telegram Error
pub type TelegramError {
  HttpError(String)
  JsonDecodeError(String)
  ApiError(code: Int, description: String)
  RateLimitError(retry_after: Int)
  InvalidTokenError
  NetworkError(String)
  TimeoutError
  MessageTooLongError
  InvalidParseModeError
}

// ============================================================================
// Configuration Helpers
// ============================================================================

/// Create default config with token
pub fn new_config(token: String) -> Config {
  Config(
    token: token,
    polling_timeout: 30,
    polling_interval: 0,
    allowed_updates: [],
  )
}

/// Set polling timeout (in seconds, 0-100)
pub fn with_polling_timeout(config: Config, timeout: Int) -> Config {
  Config(..config, polling_timeout: timeout)
}

/// Set polling interval (in seconds between polls)
pub fn with_polling_interval(config: Config, interval: Int) -> Config {
  Config(..config, polling_interval: interval)
}

/// Set allowed update types
pub fn with_allowed_updates(config: Config, updates: List(String)) -> Config {
  Config(..config, allowed_updates: updates)
}

// ============================================================================
// HTTP Client
// ============================================================================

/// Build API URL for endpoint
fn build_api_url(token: String, endpoint: String) -> String {
  api_base_url <> token <> "/" <> endpoint
}

/// Make HTTP GET request to Telegram API
fn api_get(
  config: Config,
  endpoint: String,
  params: List(#(String, String)),
) -> Result(String, TelegramError) {
  let url = build_api_url(config.token, endpoint)
  let query_string = build_query_string(params)
  let full_url = case query_string {
    "" -> url
    _ -> url <> "?" <> query_string
  }

  case uri.parse(full_url) {
    Ok(parsed_uri) -> {
      case request.from_uri(parsed_uri) {
        Ok(req_with_url) -> {
          let req_with_ua =
            req_with_url
            |> request.prepend_header("User-Agent", "SupernovaBot/1.0")
          case hackney.send(req_with_ua) {
            Ok(response) -> handle_response(response)
            Error(hackney.InvalidUtf8Response) ->
              Error(HttpError("Invalid UTF-8 response"))
            Error(hackney.Other(reason)) ->
              Error(HttpError(string.inspect(reason)))
          }
        }
        Error(_) -> Error(HttpError("Failed to build request from URI"))
      }
    }
    Error(_) -> Error(HttpError("Failed to parse URL: " <> full_url))
  }
}

/// Build query string from parameters
fn build_query_string(params: List(#(String, String))) -> String {
  params
  |> list.map(fn(param) {
    let #(key, value) = param
    key <> "=" <> value
  })
  |> string.join("&")
}

/// Handle HTTP response
fn handle_response(response: Response(String)) -> Result(String, TelegramError) {
  case response.status {
    200 -> Ok(response.body)
    429 -> {
      let retry_after = parse_retry_after(response.body)
      Error(RateLimitError(retry_after: retry_after))
    }
    401 -> Error(InvalidTokenError)
    status -> {
      let description = parse_error_description(response.body)
      Error(ApiError(code: status, description: description))
    }
  }
}

/// Parse retry_after from error response
fn parse_retry_after(body: String) -> Int {
  let decoder = {
    use retry_after <- decode.field("retry_after", decode.int)
    decode.success(retry_after)
  }
  case json.parse(from: body, using: decoder) {
    Ok(value) -> value
    Error(_) -> 30
  }
}

/// Parse error description from response
fn parse_error_description(body: String) -> String {
  let decoder = {
    use description <- decode.field("description", decode.string)
    decode.success(description)
  }
  case json.parse(from: body, using: decoder) {
    Ok(desc) -> desc
    Error(_) -> "Unknown error"
  }
}

// ============================================================================
// API Methods - getUpdates
// ============================================================================

/// Get updates from Telegram Bot API
/// Returns list of updates and automatically manages offset
pub fn get_updates(poller: Poller) -> Result(List(Update), TelegramError) {
  actor.call(poller, waiting: 60_000, sending: GetUpdates)
}

/// Fetch updates from API (internal)
fn fetch_updates(
  config: Config,
  offset: Int,
) -> Result(List(Update), TelegramError) {
  let params = [
    #("offset", int.to_string(offset)),
    #("timeout", int.to_string(config.polling_timeout)),
    #("limit", "100"),
  ]

  case api_get(config, "getUpdates", params) {
    Ok(body) -> parse_updates_response(body)
    Error(error) -> Error(error)
  }
}

/// Parse getUpdates response
fn parse_updates_response(body: String) -> Result(List(Update), TelegramError) {
  let decoder = {
    use result <- decode.field("result", decode.list(decode_update()))
    decode.success(result)
  }

  case json.parse(from: body, using: decoder) {
    Ok(updates) -> Ok(updates)
    Error(error) -> Error(JsonDecodeError(string.inspect(error)))
  }
}

// ============================================================================
// JSON Decoders
// ============================================================================

/// Decode Update object
fn decode_update() -> decode.Decoder(Update) {
  use update_id <- decode.field("update_id", decode.int)
  use message <- decode.optional_field(
    "message",
    None,
    decode.optional(decode_message()),
  )
  use edited_message <- decode.optional_field(
    "edited_message",
    None,
    decode.optional(decode_message()),
  )
  use channel_post <- decode.optional_field(
    "channel_post",
    None,
    decode.optional(decode_message()),
  )
  use edited_channel_post <- decode.optional_field(
    "edited_channel_post",
    None,
    decode.optional(decode_message()),
  )
  use inline_query <- decode.optional_field(
    "inline_query",
    None,
    decode.optional(decode_inline_query()),
  )
  use chosen_inline_result <- decode.optional_field(
    "chosen_inline_result",
    None,
    decode.optional(decode_chosen_inline_result()),
  )
  use callback_query <- decode.optional_field(
    "callback_query",
    None,
    decode.optional(decode_callback_query()),
  )
  use poll_answer <- decode.optional_field(
    "poll_answer",
    None,
    decode.optional(decode_poll_answer()),
  )
  use message_reaction <- decode.optional_field(
    "message_reaction",
    None,
    decode.optional(decode_message_reaction()),
  )

  decode.success(Update(
    update_id: update_id,
    message: message,
    edited_message: edited_message,
    channel_post: channel_post,
    edited_channel_post: edited_channel_post,
    inline_query: inline_query,
    chosen_inline_result: chosen_inline_result,
    callback_query: callback_query,
    poll_answer: poll_answer,
    message_reaction: message_reaction,
  ))
}

/// Decode Message object
fn decode_message() -> decode.Decoder(Message) {
  use message_id <- decode.field("message_id", decode.int)
  use from <- decode.optional_field(
    "from",
    None,
    decode.optional(decode_user()),
  )
  use sender_chat <- decode.optional_field(
    "sender_chat",
    None,
    decode.optional(decode_chat()),
  )
  use date <- decode.field("date", decode.int)
  use chat <- decode.field("chat", decode_chat())
  use forward_from <- decode.optional_field(
    "forward_from",
    None,
    decode.optional(decode_user()),
  )
  use forward_date <- decode.optional_field(
    "forward_date",
    None,
    decode.optional(decode.int),
  )
  use text <- decode.optional_field(
    "text",
    None,
    decode.optional(decode.string),
  )
  use caption <- decode.optional_field(
    "caption",
    None,
    decode.optional(decode.string),
  )
  use entities <- decode.optional_field(
    "entities",
    None,
    decode.optional(decode.list(decode_message_entity())),
  )
  use caption_entities <- decode.optional_field(
    "caption_entities",
    None,
    decode.optional(decode.list(decode_message_entity())),
  )
  use reply_to_message <- decode.optional_field(
    "reply_to_message",
    None,
    decode.optional(decode.dynamic),
  )
  let reply_to_message_id = case reply_to_message {
    Some(data) -> decode_reply_message_id(data)
    None -> None
  }

  decode.success(Message(
    message_id: message_id,
    from: from,
    sender_chat: sender_chat,
    date: date,
    chat: chat,
    forward_from: forward_from,
    forward_date: forward_date,
    text: text,
    caption: caption,
    entities: option.unwrap(entities, []),
    caption_entities: option.unwrap(caption_entities, []),
    reply_to_message_id: reply_to_message_id,
  ))
}

/// Extract message_id from reply_to_message dynamic data
fn decode_reply_message_id(data: dynamic.Dynamic) -> Option(Int) {
  let decoder = {
    use message_id <- decode.field("message_id", decode.int)
    decode.success(message_id)
  }
  case decode.run(data, decoder) {
    Ok(id) -> Some(id)
    Error(_) -> None
  }
}

/// Decode User object
fn decode_user() -> decode.Decoder(User) {
  use id <- decode.field("id", decode.int)
  use is_bot <- decode.field("is_bot", decode.bool)
  use first_name <- decode.field("first_name", decode.string)
  use last_name <- decode.optional_field(
    "last_name",
    None,
    decode.optional(decode.string),
  )
  use username <- decode.optional_field(
    "username",
    None,
    decode.optional(decode.string),
  )
  use language_code <- decode.optional_field(
    "language_code",
    None,
    decode.optional(decode.string),
  )

  decode.success(User(
    id: int.to_string(id),
    is_bot: is_bot,
    first_name: first_name,
    last_name: last_name,
    username: username,
    language_code: language_code,
  ))
}

/// Decode Chat object
fn decode_chat() -> decode.Decoder(Chat) {
  use id <- decode.field("id", decode.int)
  use chat_type_str <- decode.field("type", decode.string)
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use username <- decode.optional_field(
    "username",
    None,
    decode.optional(decode.string),
  )
  use first_name <- decode.optional_field(
    "first_name",
    None,
    decode.optional(decode.string),
  )
  use last_name <- decode.optional_field(
    "last_name",
    None,
    decode.optional(decode.string),
  )

  let chat_type = parse_chat_type(chat_type_str)

  decode.success(Chat(
    id: int.to_string(id),
    chat_type: chat_type,
    title: title,
    username: username,
    first_name: first_name,
    last_name: last_name,
  ))
}

/// Parse chat type from string
fn parse_chat_type(type_str: String) -> ChatType {
  case type_str {
    "private" -> PrivateChat
    "group" -> GroupChat
    "supergroup" -> SupergroupChat
    "channel" -> ChannelChat
    _ -> PrivateChat
  }
}

/// Decode MessageEntity object
fn decode_message_entity() -> decode.Decoder(MessageEntity) {
  use entity_type_str <- decode.field("type", decode.string)
  use offset <- decode.field("offset", decode.int)
  use length <- decode.field("length", decode.int)
  use url <- decode.optional_field("url", None, decode.optional(decode.string))
  use user <- decode.optional_field(
    "user",
    None,
    decode.optional(decode_user()),
  )
  use language <- decode.optional_field(
    "language",
    None,
    decode.optional(decode.string),
  )
  use custom_emoji_id <- decode.optional_field(
    "custom_emoji_id",
    None,
    decode.optional(decode.string),
  )

  let entity_type = parse_message_entity_type(entity_type_str)

  decode.success(MessageEntity(
    entity_type: entity_type,
    offset: offset,
    length: length,
    url: url,
    user: user,
    language: language,
    custom_emoji_id: custom_emoji_id,
  ))
}

/// Parse message entity type from string
fn parse_message_entity_type(type_str: String) -> MessageEntityType {
  case type_str {
    "mention" -> MentionEntity
    "hashtag" -> HashtagEntity
    "cashtag" -> CashtagEntity
    "bot_command" -> BotCommandEntity
    "url" -> UrlEntity
    "email" -> EmailEntity
    "phone_number" -> PhoneNumberEntity
    "bold" -> BoldEntity
    "italic" -> ItalicEntity
    "underline" -> UnderlineEntity
    "strikethrough" -> StrikethroughEntity
    "spoiler" -> SpoilerEntity
    "code" -> CodeEntity
    "pre" -> PreEntity
    "text_link" -> TextLinkEntity
    "text_mention" -> TextMentionEntity
    "custom_emoji" -> CustomEmojiEntity
    _ -> MentionEntity
  }
}

/// Decode CallbackQuery object
fn decode_callback_query() -> decode.Decoder(CallbackQuery) {
  // Telegram's API specifies id as String, but some clients/sanitized fixtures
  // may emit it as an integer — accept both.
  use id <- decode.field(
    "id",
    decode.one_of(decode.string, [decode.map(decode.int, int.to_string)]),
  )
  use from <- decode.field("from", decode_user())
  use message <- decode.optional_field(
    "message",
    None,
    decode.optional(decode_message()),
  )
  use inline_message_id <- decode.optional_field(
    "inline_message_id",
    None,
    decode.optional(decode.string),
  )
  use chat_instance <- decode.field("chat_instance", decode.string)
  use data <- decode.optional_field(
    "data",
    None,
    decode.optional(decode.string),
  )
  use game_short_name <- decode.optional_field(
    "game_short_name",
    None,
    decode.optional(decode.string),
  )

  decode.success(CallbackQuery(
    id: id,
    from: from,
    message: message,
    inline_message_id: inline_message_id,
    chat_instance: chat_instance,
    data: data,
    game_short_name: game_short_name,
  ))
}

/// Decode InlineQuery object
fn decode_inline_query() -> decode.Decoder(InlineQuery) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", decode_user())
  use query <- decode.field("query", decode.string)
  use offset <- decode.field("offset", decode.string)
  use chat_type <- decode.field("chat_type", decode.optional(decode.string))

  let parsed_chat_type = case chat_type {
    Some(type_str) -> Some(parse_chat_type(type_str))
    None -> None
  }

  decode.success(InlineQuery(
    id: id,
    from: from,
    query: query,
    offset: offset,
    chat_type: parsed_chat_type,
  ))
}

/// Decode ChosenInlineResult object
fn decode_chosen_inline_result() -> decode.Decoder(ChosenInlineResult) {
  use result_id <- decode.field("result_id", decode.string)
  use from <- decode.field("from", decode_user())
  use location <- decode.field("location", decode.optional(decode_location()))
  use inline_message_id <- decode.field(
    "inline_message_id",
    decode.optional(decode.string),
  )
  use query <- decode.field("query", decode.string)

  decode.success(ChosenInlineResult(
    result_id: result_id,
    from: from,
    location: location,
    inline_message_id: inline_message_id,
    query: query,
  ))
}

/// Decode Location object
fn decode_location() -> decode.Decoder(Location) {
  use latitude <- decode.field("latitude", decode.float)
  use longitude <- decode.field("longitude", decode.float)

  decode.success(Location(latitude: latitude, longitude: longitude))
}

/// Decode ReactionType object
fn decode_reaction_type() -> decode.Decoder(ReactionType) {
  use reaction_type <- decode.field("type", decode.string)
  use emoji <- decode.optional_field(
    "emoji",
    None,
    decode.optional(decode.string),
  )
  use custom_emoji_id <- decode.optional_field(
    "custom_emoji_id",
    None,
    decode.optional(decode.string),
  )

  decode.success(ReactionType(
    reaction_type: reaction_type,
    emoji: emoji,
    custom_emoji_id: custom_emoji_id,
  ))
}

/// Decode PollAnswer object
fn decode_poll_answer() -> decode.Decoder(PollAnswer) {
  use poll_id <- decode.field("poll_id", decode.string)
  use user <- decode.optional_field(
    "user",
    None,
    decode.optional(decode_user()),
  )
  use option_ids <- decode.field("option_ids", decode.list(decode.int))

  decode.success(PollAnswer(
    poll_id: poll_id,
    user: user,
    option_ids: option_ids,
  ))
}

/// Decode MessageReaction object
fn decode_message_reaction() -> decode.Decoder(MessageReaction) {
  use chat <- decode.field("chat", decode_chat())
  use message_id <- decode.field("message_id", decode.int)
  use user <- decode.optional_field(
    "user",
    None,
    decode.optional(decode_user()),
  )
  use date <- decode.field("date", decode.int)
  use old_reaction <- decode.field(
    "old_reaction",
    decode.list(decode_reaction_type()),
  )
  use new_reaction <- decode.field(
    "new_reaction",
    decode.list(decode_reaction_type()),
  )

  decode.success(MessageReaction(
    chat: chat,
    message_id: message_id,
    user: user,
    date: date,
    old_reaction: old_reaction,
    new_reaction: new_reaction,
  ))
}

// ============================================================================
// Polling Actor
// ============================================================================

/// Start the polling actor
pub fn start_poller(config: Config) -> Result(Poller, actor.StartError) {
  let initial_state = PollingState(config: config, offset: 0, is_running: False)

  case
    actor.new(initial_state)
    |> actor.on_message(handle_polling_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Handle polling messages
fn handle_polling_message(
  state: PollingState,
  message: PollingMessage,
) -> actor.Next(PollingState, PollingMessage) {
  case message {
    GetUpdates(reply_to) -> {
      case fetch_updates(state.config, state.offset) {
        Ok(updates) -> {
          // Update offset to latest update_id + 1
          let new_offset = calculate_new_offset(state.offset, updates)
          let new_state = PollingState(..state, offset: new_offset)
          actor.send(reply_to, Ok(updates))
          actor.continue(new_state)
        }
        Error(error) -> {
          actor.send(reply_to, Error(error))
          actor.continue(state)
        }
      }
    }

    StartPolling(reply_to) -> {
      let new_state = PollingState(..state, is_running: True)
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    StopPolling(reply_to) -> {
      let new_state = PollingState(..state, is_running: False)
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    SetOffset(reply_to, offset) -> {
      let new_state = PollingState(..state, offset: offset)
      actor.send(reply_to, Ok(Nil))
      actor.continue(new_state)
    }

    GetState(reply_to) -> {
      actor.send(reply_to, state)
      actor.continue(state)
    }
  }
}

/// Calculate new offset from updates
fn calculate_new_offset(current_offset: Int, updates: List(Update)) -> Int {
  case updates {
    [] -> current_offset
    _ -> {
      let max_id =
        updates
        |> list.map(fn(update) { update.update_id })
        |> list.fold(0, int.max)
      max_id + 1
    }
  }
}

// ============================================================================
// Polling Loop
// ============================================================================

/// Start continuous polling loop
/// This function blocks and continuously polls for updates
pub fn start_polling_loop(
  poller: Poller,
  callback: fn(Update) -> Nil,
) -> Result(Nil, TelegramError) {
  // Start the poller
  case actor.call(poller, waiting: 1000, sending: StartPolling) {
    Ok(Nil) -> {
      polling_loop(poller, callback)
      Ok(Nil)
    }
    Error(error) -> Error(error)
  }
}

/// Internal polling loop
fn polling_loop(poller: Poller, callback: fn(Update) -> Nil) -> Nil {
  let state = actor.call(poller, waiting: 1000, sending: GetState)

  case state.is_running {
    False -> Nil
    True -> {
      // Fetch updates
      case get_updates(poller) {
        Ok(updates) -> {
          // Process each update with callback
          updates
          |> list.each(callback)

          // Continue polling
          polling_loop(poller, callback)
        }
        Error(_error) -> {
          // Continue polling on error
          polling_loop(poller, callback)
        }
      }
    }
  }
}

/// Stop the polling loop
pub fn stop_polling(poller: Poller) -> Result(Nil, TelegramError) {
  actor.call(poller, waiting: 1000, sending: StopPolling)
}

/// Get current polling state
pub fn get_poller_state(poller: Poller) -> PollingState {
  actor.call(poller, waiting: 1000, sending: GetState)
}

/// Manually set offset (useful for recovery)
pub fn set_offset(poller: Poller, offset: Int) -> Result(Nil, TelegramError) {
  actor.call(poller, waiting: 1000, sending: SetOffset(_, offset))
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Extract message text from update
pub fn get_message_text(update: Update) -> Option(String) {
  case update.message {
    Some(message) -> message.text
    None -> None
  }
}

/// Extract callback data from update
pub fn get_callback_data(update: Update) -> Option(String) {
  case update.callback_query {
    Some(callback) -> callback.data
    None -> None
  }
}

/// Extract chat ID from update
pub fn get_chat_id(update: Update) -> Option(ChatId) {
  case update.message {
    Some(message) -> Some(message.chat.id)
    None ->
      case update.edited_message {
        Some(message) -> Some(message.chat.id)
        None ->
          case update.callback_query {
            Some(callback) ->
              case callback.message {
                Some(message) -> Some(message.chat.id)
                None -> None
              }
            None ->
              case update.message_reaction {
                Some(reaction) -> Some(reaction.chat.id)
                None -> None
              }
          }
      }
  }
}

/// Extract user from update
pub fn get_user(update: Update) -> Option(User) {
  case update.message {
    Some(message) -> message.from
    None ->
      case update.callback_query {
        Some(callback) -> Some(callback.from)
        None ->
          case update.poll_answer {
            Some(answer) -> answer.user
            None ->
              case update.message_reaction {
                Some(reaction) -> reaction.user
                None -> None
              }
          }
      }
  }
}

/// Check if update is a command (starts with /)
pub fn is_command(update: Update) -> Bool {
  case get_message_text(update) {
    Some(text) -> string.starts_with(text, "/")
    None -> False
  }
}

/// Extract command and arguments from message
pub fn parse_command(update: Update) -> Option(#(String, List(String))) {
  case get_message_text(update) {
    Some(text) -> {
      case string.starts_with(text, "/") {
        True -> {
          let parts =
            text
            |> string.drop_start(1)
            |> string.split(" ")

          case parts {
            [command, ..rest] -> Some(#(command, rest))
            _ -> None
          }
        }
        False -> None
      }
    }
    None -> None
  }
}

// ============================================================================
// Send Message Options Helpers
// ============================================================================

/// Create default send message options
pub fn new_send_options() -> SendMessageOptions {
  SendMessageOptions(
    parse_mode: ParseModeNone,
    disable_notification: False,
    reply_to_message_id: None,
    message_thread_id: None,
    protect_content: False,
    reply_markup: None,
  )
}

/// Set parse mode for message
pub fn with_parse_mode(
  options: SendMessageOptions,
  mode: ParseMode,
) -> SendMessageOptions {
  SendMessageOptions(..options, parse_mode: mode)
}

/// Set disable notification
pub fn with_disable_notification(
  options: SendMessageOptions,
  disable: Bool,
) -> SendMessageOptions {
  SendMessageOptions(..options, disable_notification: disable)
}

/// Set reply to message ID
pub fn with_reply_to(
  options: SendMessageOptions,
  message_id: Int,
) -> SendMessageOptions {
  SendMessageOptions(..options, reply_to_message_id: Some(message_id))
}

/// Set explicit Telegram forum topic / thread target.
pub fn with_message_thread_id(
  options: SendMessageOptions,
  thread_id: Int,
) -> SendMessageOptions {
  SendMessageOptions(..options, message_thread_id: Some(thread_id))
}

/// Set protect content
pub fn with_protect_content(
  options: SendMessageOptions,
  protect: Bool,
) -> SendMessageOptions {
  SendMessageOptions(..options, protect_content: protect)
}

/// Set inline reply markup for a message.
pub fn with_reply_markup(
  options: SendMessageOptions,
  markup: ReplyMarkup,
) -> SendMessageOptions {
  SendMessageOptions(..options, reply_markup: Some(markup))
}

/// Build an inline keyboard button.
pub fn inline_keyboard_button(
  text: String,
  callback_data: String,
) -> InlineKeyboardButton {
  InlineKeyboardButton(text: text, callback_data: callback_data)
}

/// Build an inline keyboard markup payload.
pub fn inline_keyboard(rows: List(List(InlineKeyboardButton))) -> ReplyMarkup {
  InlineKeyboardMarkup(inline_keyboard: rows)
}

// ============================================================================
// HTTP Client - POST
// ============================================================================

/// Make HTTP POST request to Telegram API
fn api_post(
  config: Config,
  endpoint: String,
  body: String,
) -> Result(String, TelegramError) {
  let url = build_api_url(config.token, endpoint)

  case uri.parse(url) {
    Ok(parsed_uri) -> {
      case request.from_uri(parsed_uri) {
        Ok(req_with_url) -> {
          let req =
            req_with_url
            |> request.set_method(http.Post)
            |> request.prepend_header("Content-Type", "application/json")
            |> request.prepend_header("User-Agent", "SupernovaBot/1.0")
          let req_with_body = request.set_body(req, body)

          case hackney.send(req_with_body) {
            Ok(response) -> handle_response(response)
            Error(hackney.InvalidUtf8Response) ->
              Error(HttpError("Invalid UTF-8 response"))
            Error(hackney.Other(reason)) ->
              Error(HttpError(string.inspect(reason)))
          }
        }
        Error(_) -> Error(HttpError("Failed to build request from URI"))
      }
    }
    Error(_) -> Error(HttpError("Failed to parse URL: " <> url))
  }
}

// ============================================================================
// API Methods - sendChatAction
// ============================================================================

/// Send chat action (e.g., typing indicator)
/// Returns Ok(Nil) on success
pub fn send_chat_action(
  config: Config,
  chat_id: ChatId,
  action: ChatAction,
) -> Result(Nil, TelegramError) {
  let action_str = chat_action_to_string(action)
  let body =
    "{\"chat_id\":\"" <> chat_id <> "\",\"action\":\"" <> action_str <> "\"}"

  case api_post(config, "sendChatAction", body) {
    Ok(_response) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

/// Convert ChatAction to string for API
fn chat_action_to_string(action: ChatAction) -> String {
  case action {
    TypingAction -> "typing"
    UploadPhotoAction -> "upload_photo"
    RecordVideoAction -> "record_video"
    UploadVideoAction -> "upload_video"
    RecordVoiceAction -> "record_voice"
    UploadVoiceAction -> "upload_voice"
    UploadDocumentAction -> "upload_document"
    ChooseStickerAction -> "choose_sticker"
    FindLocationAction -> "find_location"
    RecordVideoNoteAction -> "record_video_note"
    UploadVideoNoteAction -> "upload_video_note"
  }
}

// ============================================================================
// API Methods - sendMessage
// ============================================================================

/// Send a simple text message
pub fn send_message(
  config: Config,
  chat_id: ChatId,
  text: String,
) -> Result(SentMessage, TelegramError) {
  send_message_with_options(config, chat_id, text, new_send_options())
}

/// Send a message with options
pub fn send_message_with_options(
  config: Config,
  chat_id: ChatId,
  text: String,
  options: SendMessageOptions,
) -> Result(SentMessage, TelegramError) {
  // Check message length
  case string.length(text) > 4096 {
    True -> Error(MessageTooLongError)
    False -> {
      let body = build_send_message_body(chat_id, text, options)

      case api_post(config, "sendMessage", body) {
        Ok(response) -> parse_sent_message_response(response)
        Error(error) -> Error(error)
      }
    }
  }
}

/// Build JSON body for sendMessage
pub fn build_send_message_body(
  chat_id: ChatId,
  text: String,
  options: SendMessageOptions,
) -> String {
  let parse_mode_json = case options.parse_mode {
    ParseModeNone -> ""
    ParseModeMarkdown -> ",\"parse_mode\":\"Markdown\""
    ParseModeMarkdownV2 -> ",\"parse_mode\":\"MarkdownV2\""
    ParseModeHTML -> ",\"parse_mode\":\"HTML\""
  }

  let disable_notification_json = case options.disable_notification {
    True -> ",\"disable_notification\":true"
    False -> ""
  }

  let reply_to_json = case options.reply_to_message_id {
    Some(id) -> ",\"reply_to_message_id\":" <> int.to_string(id)
    None -> ""
  }

  let message_thread_json = case options.message_thread_id {
    Some(id) -> ",\"message_thread_id\":" <> int.to_string(id)
    None -> ""
  }

  let protect_content_json = case options.protect_content {
    True -> ",\"protect_content\":true"
    False -> ""
  }

  let reply_markup_json = case options.reply_markup {
    Some(markup) -> ",\"reply_markup\":" <> encode_reply_markup(markup)
    None -> ""
  }

  let escaped_text = escape_json_string(text)

  "{\"chat_id\":\""
  <> chat_id
  <> "\",\"text\":\""
  <> escaped_text
  <> "\""
  <> parse_mode_json
  <> disable_notification_json
  <> reply_to_json
  <> message_thread_json
  <> protect_content_json
  <> reply_markup_json
  <> "}"
}

/// Escape special characters for JSON string
fn escape_json_string(text: String) -> String {
  text
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

fn encode_reply_markup(markup: ReplyMarkup) -> String {
  case markup {
    InlineKeyboardMarkup(inline_keyboard) -> {
      let rows =
        inline_keyboard
        |> list.map(encode_inline_keyboard_row)
        |> string.join(",")

      "{\"inline_keyboard\":[" <> rows <> "]}"
    }
  }
}

fn encode_inline_keyboard_row(row: List(InlineKeyboardButton)) -> String {
  let encoded =
    row
    |> list.map(encode_inline_keyboard_button)
    |> string.join(",")

  "[" <> encoded <> "]"
}

fn encode_inline_keyboard_button(button: InlineKeyboardButton) -> String {
  let InlineKeyboardButton(text:, callback_data:) = button

  "{\"text\":\""
  <> escape_json_string(text)
  <> "\",\"callback_data\":\""
  <> escape_json_string(callback_data)
  <> "\"}"
}

/// Parse sent message response
fn parse_sent_message_response(
  body: String,
) -> Result(SentMessage, TelegramError) {
  let decoder = {
    use result <- decode.field("result", decode_sent_message())
    decode.success(result)
  }

  case json.parse(from: body, using: decoder) {
    Ok(message) -> Ok(message)
    Error(error) -> Error(JsonDecodeError(string.inspect(error)))
  }
}

/// Decode SentMessage from API response
fn decode_sent_message() -> decode.Decoder(SentMessage) {
  use message_id <- decode.field("message_id", decode.int)
  use chat <- decode.field("chat", decode_chat())
  use date <- decode.field("date", decode.int)
  use text <- decode.field("text", decode.optional(decode.string))

  decode.success(SentMessage(
    message_id: message_id,
    chat: chat,
    date: date,
    text: text,
  ))
}

// ============================================================================
// API Methods - editMessageText
// ============================================================================

/// Edit an existing message's text
pub fn edit_message_text(
  config: Config,
  chat_id: ChatId,
  message_id: Int,
  text: String,
) -> Result(SentMessage, TelegramError) {
  edit_message_text_with_options(
    config,
    chat_id,
    message_id,
    text,
    new_send_options(),
  )
}

/// Edit message text with options
pub fn edit_message_text_with_options(
  config: Config,
  chat_id: ChatId,
  message_id: Int,
  text: String,
  options: SendMessageOptions,
) -> Result(SentMessage, TelegramError) {
  // Check message length
  case string.length(text) > 4096 {
    True -> Error(MessageTooLongError)
    False -> {
      let body = build_edit_message_body(chat_id, message_id, text, options)

      case api_post(config, "editMessageText", body) {
        Ok(response) -> parse_sent_message_response(response)
        Error(error) -> Error(error)
      }
    }
  }
}

/// Build JSON body for editMessageText
fn build_edit_message_body(
  chat_id: ChatId,
  message_id: Int,
  text: String,
  options: SendMessageOptions,
) -> String {
  let parse_mode_json = case options.parse_mode {
    ParseModeNone -> ""
    ParseModeMarkdown -> ",\"parse_mode\":\"Markdown\""
    ParseModeMarkdownV2 -> ",\"parse_mode\":\"MarkdownV2\""
    ParseModeHTML -> ",\"parse_mode\":\"HTML\""
  }

  let escaped_text = escape_json_string(text)
  let reply_markup_json = case options.reply_markup {
    Some(markup) -> ",\"reply_markup\":" <> encode_reply_markup(markup)
    None -> ""
  }
  let message_thread_json = case options.message_thread_id {
    Some(id) -> ",\"message_thread_id\":" <> int.to_string(id)
    None -> ""
  }

  "{\"chat_id\":\""
  <> chat_id
  <> "\",\"message_id\":"
  <> int.to_string(message_id)
  <> ",\"text\":\""
  <> escaped_text
  <> "\""
  <> parse_mode_json
  <> message_thread_json
  <> reply_markup_json
  <> "}"
}

// ============================================================================
// Message Splitting
// ============================================================================

/// Maximum message length for Telegram
pub const max_message_length = 4096

/// Split a long message into multiple parts
/// Returns list of message parts, each under max_message_length
pub fn split_message(text: String) -> List(String) {
  split_message_with_max(text, max_message_length)
}

/// Split message with custom max length
pub fn split_message_with_max(text: String, max_length: Int) -> List(String) {
  case string.length(text) <= max_length {
    True -> [text]
    False -> {
      // Try to split at newline or space
      case find_split_point(text, max_length) {
        Some(point) -> {
          let first_part = string.slice(text, 0, point)
          let rest = string.drop_start(text, point)
          [first_part, ..split_message_with_max(rest, max_length)]
        }
        None -> {
          // Force split at max_length
          let first_part = string.slice(text, 0, max_length)
          let rest = string.drop_start(text, max_length)
          [first_part, ..split_message_with_max(rest, max_length)]
        }
      }
    }
  }
}

/// Find a good split point (newline or space) before max_length
fn find_split_point(text: String, max_length: Int) -> Option(Int) {
  let slice = string.slice(text, 0, max_length)
  // Try to find last newline
  case string.split(slice, "\n") {
    [] -> None
    parts -> {
      let last_newline_pos = calculate_last_separator_pos(parts, 0, 0)
      case last_newline_pos > 0 {
        True -> Some(last_newline_pos)
        False -> {
          // Try to find last space
          case find_last_space(slice) {
            Some(pos) -> Some(pos)
            None -> None
          }
        }
      }
    }
  }
}

/// Calculate position of last newline separator
fn calculate_last_separator_pos(
  parts: List(String),
  current_pos: Int,
  last_sep_pos: Int,
) -> Int {
  case parts {
    [] -> last_sep_pos
    [_part] -> last_sep_pos
    [part, ..rest] -> {
      let new_pos = current_pos + string.length(part) + 1
      calculate_last_separator_pos(
        rest,
        new_pos,
        current_pos + string.length(part),
      )
    }
  }
}

/// Find position of last space in string
fn find_last_space(text: String) -> Option(Int) {
  let chars = string.to_graphemes(text)
  find_last_space_loop(chars, 0, None)
}

fn find_last_space_loop(
  chars: List(String),
  pos: Int,
  last_space: Option(Int),
) -> Option(Int) {
  case chars {
    [] -> last_space
    [char, ..rest] -> {
      let new_last_space = case char {
        " " -> Some(pos)
        _ -> last_space
      }
      find_last_space_loop(rest, pos + 1, new_last_space)
    }
  }
}

// ============================================================================
// Streaming Helper
// ============================================================================

/// Send or update message for streaming
/// If message_id is None, sends a new message
/// If message_id is Some, edits the existing message
pub fn send_or_edit_message(
  config: Config,
  chat_id: ChatId,
  text: String,
  message_id: Option(Int),
  options: SendMessageOptions,
) -> Result(SentMessage, TelegramError) {
  case message_id {
    None -> send_message_with_options(config, chat_id, text, options)
    Some(id) ->
      edit_message_text_with_options(config, chat_id, id, text, options)
  }
}

// ============================================================================
// Public Parse Helpers (for testing and direct JSON ingestion)
// ============================================================================

/// Parse a single Update object from a JSON string.
pub fn parse_update(json_str: String) -> Result(Update, String) {
  case json.parse(from: json_str, using: decode_update()) {
    Ok(update) -> Ok(update)
    Error(err) -> Error(string.inspect(err))
  }
}

/// Parse a raw JSON array of Update objects (not the API envelope).
pub fn parse_updates_array(json_str: String) -> Result(List(Update), String) {
  case json.parse(from: json_str, using: decode.list(decode_update())) {
    Ok(updates) -> Ok(updates)
    Error(err) -> Error(string.inspect(err))
  }
}

/// Parse a single CallbackQuery object from a JSON string.
pub fn parse_callback_query(json_str: String) -> Result(CallbackQuery, String) {
  case json.parse(from: json_str, using: decode_callback_query()) {
    Ok(cb) -> Ok(cb)
    Error(err) -> Error(string.inspect(err))
  }
}

/// Stream message with typing indicator
/// Sends typing action, then sends/edits message
pub fn stream_message(
  config: Config,
  chat_id: ChatId,
  text: String,
  message_id: Option(Int),
  options: SendMessageOptions,
) -> Result(SentMessage, TelegramError) {
  // Send typing indicator first
  let _ = send_chat_action(config, chat_id, TypingAction)

  // Send or edit the message
  send_or_edit_message(config, chat_id, text, message_id, options)
}
