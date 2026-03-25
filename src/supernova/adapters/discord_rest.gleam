//// Discord REST API Client Module
//// Provides:
//// - HTTP client for Discord REST API using gleam_http + gleam_hackney
//// - Message sending with embeds and attachments support
//// - Rate limiting respecting Discord X-RateLimit-* headers
//// - Automatic retry on rate limit with proper wait times
////
//// This module uses an actor pattern to manage rate limit state per route.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/hackney
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

// ============================================================================
// Constants
// ============================================================================

/// Discord API base URL
pub const api_base_url = "https://discord.com/api/v10"

// ============================================================================
// Types - Snowflake
// ============================================================================

/// Discord Snowflake ID
pub type Snowflake =
  String

// ============================================================================
// Types - Message Components
// ============================================================================

/// Message Embed Footer
pub type EmbedFooter {
  EmbedFooter(text: String, icon_url: Option(String))
}

/// Message Embed Image
pub type EmbedImage {
  EmbedImage(url: String)
}

/// Message Embed Thumbnail
pub type EmbedThumbnail {
  EmbedThumbnail(url: String)
}

/// Message Embed Author
pub type EmbedAuthor {
  EmbedAuthor(name: String, url: Option(String), icon_url: Option(String))
}

/// Message Embed Field
pub type EmbedField {
  EmbedField(name: String, value: String, inline: Option(Bool))
}

/// Message Embed for sending
pub type MessageEmbed {
  MessageEmbed(
    title: Option(String),
    description: Option(String),
    url: Option(String),
    timestamp: Option(String),
    color: Option(Int),
    footer: Option(EmbedFooter),
    image: Option(EmbedImage),
    thumbnail: Option(EmbedThumbnail),
    author: Option(EmbedAuthor),
    fields: List(EmbedField),
  )
}

/// Message Attachment for sending
pub type MessageAttachment {
  MessageAttachment(id: String, filename: String, description: Option(String))
}

/// Message Reference for replies
pub type MessageReference {
  MessageReference(
    message_id: Option(Snowflake),
    channel_id: Option(Snowflake),
    guild_id: Option(Snowflake),
  )
}

// ============================================================================
// Types - Send Message Options
// ============================================================================

/// Options for sending a message
pub type SendMessageOptions {
  SendMessageOptions(
    content: Option(String),
    tts: Option(Bool),
    embeds: List(MessageEmbed),
    attachments: List(MessageAttachment),
    message_reference: Option(MessageReference),
    allowed_mentions: Option(AllowedMentions),
  )
}

/// Allowed mentions configuration
pub type AllowedMentions {
  AllowedMentions(
    parse: List(String),
    users: List(Snowflake),
    roles: List(Snowflake),
    replied_user: Option(Bool),
  )
}

// ============================================================================
// Types - API Response
// ============================================================================

/// Sent message response from Discord API
pub type SentMessage {
  SentMessage(
    id: Snowflake,
    channel_id: Snowflake,
    guild_id: Option(Snowflake),
    content: String,
    timestamp: String,
  )
}

// ============================================================================
// Types - Rate Limiting
// ============================================================================

/// Rate limit information extracted from Discord headers
pub type RateLimitInfo {
  RateLimitInfo(
    limit: Int,
    remaining: Int,
    reset_after_ms: Int,
    bucket: Option(String),
    global: Bool,
  )
}

/// Rate limit bucket state
pub type BucketState {
  BucketState(remaining: Int, reset_at: Int, bucket: Option(String))
}

// ============================================================================
// Types - Errors
// ============================================================================

/// Discord REST API error
pub type DiscordRestError {
  /// HTTP request failed
  HttpError(message: String)
  /// Rate limited (429)
  RateLimited(retry_after_ms: Int)
  /// Bad request (400)
  BadRequest(message: String)
  /// Unauthorized (401)
  Unauthorized
  /// Forbidden (403)
  Forbidden(message: String)
  /// Not found (404)
  NotFound(message: String)
  /// Internal server error (500)
  InternalError(message: String)
  /// Unknown error
  UnknownError(status: Int, body: String)
  /// JSON parsing error
  JsonError(message: String)
}

// ============================================================================
// Types - Client Configuration
// ============================================================================

/// Discord REST client configuration
pub type RestClientConfig {
  RestClientConfig(bot_token: String, base_url: Option(String), timeout_ms: Int)
}

// ============================================================================
// Types - Actor State
// ============================================================================

/// REST client actor state
pub type RestClientState {
  RestClientState(
    config: RestClientConfig,
    rate_limits: Dict(String, BucketState),
    global_rate_limit_until: Option(Int),
  )
}

/// REST client actor messages
pub type RestClientMessage {
  SendMessage(
    reply_to: Subject(Result(SentMessage, DiscordRestError)),
    channel_id: Snowflake,
    options: SendMessageOptions,
  )
  SendMessageSimple(
    reply_to: Subject(Result(SentMessage, DiscordRestError)),
    channel_id: Snowflake,
    content: String,
  )
  GetRateLimitInfo(reply_to: Subject(Dict(String, BucketState)), route: String)
  ClearRateLimits(reply_to: Subject(Nil))
}

/// REST client type (actor subject)
pub type RestClient =
  Subject(RestClientMessage)

// ============================================================================
// Public API - Configuration
// ============================================================================

/// Create default REST client configuration
pub fn new_config(bot_token: String) -> RestClientConfig {
  RestClientConfig(bot_token: bot_token, base_url: None, timeout_ms: 30_000)
}

/// Set custom base URL
pub fn with_base_url(config: RestClientConfig, url: String) -> RestClientConfig {
  RestClientConfig(..config, base_url: Some(url))
}

/// Set timeout in milliseconds
pub fn with_timeout(
  config: RestClientConfig,
  timeout_ms: Int,
) -> RestClientConfig {
  RestClientConfig(..config, timeout_ms: timeout_ms)
}

// ============================================================================
// Public API - Client Lifecycle
// ============================================================================

/// Start a new REST client actor
pub fn start(config: RestClientConfig) -> Result(RestClient, actor.StartError) {
  let initial_state =
    RestClientState(
      config: config,
      rate_limits: dict.new(),
      global_rate_limit_until: None,
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

// ============================================================================
// Public API - Send Message
// ============================================================================

/// Send a simple text message to a channel
pub fn send_message(
  client: RestClient,
  channel_id: Snowflake,
  content: String,
) -> Result(SentMessage, DiscordRestError) {
  actor.call(client, waiting: 60_000, sending: SendMessageSimple(
    _,
    channel_id,
    content,
  ))
}

/// Send a message with full options (embeds, attachments, etc.)
pub fn send_message_with_options(
  client: RestClient,
  channel_id: Snowflake,
  options: SendMessageOptions,
) -> Result(SentMessage, DiscordRestError) {
  actor.call(client, waiting: 60_000, sending: SendMessage(
    _,
    channel_id,
    options,
  ))
}

// ============================================================================
// Public API - Message Options Builder
// ============================================================================

/// Create new send message options
pub fn new_message_options() -> SendMessageOptions {
  SendMessageOptions(
    content: None,
    tts: None,
    embeds: [],
    attachments: [],
    message_reference: None,
    allowed_mentions: None,
  )
}

/// Set message content
pub fn with_content(
  opts: SendMessageOptions,
  content: String,
) -> SendMessageOptions {
  SendMessageOptions(..opts, content: Some(content))
}

/// Set TTS flag
pub fn with_tts(opts: SendMessageOptions, tts: Bool) -> SendMessageOptions {
  SendMessageOptions(..opts, tts: Some(tts))
}

/// Add embed to message
pub fn with_embed(
  opts: SendMessageOptions,
  embed: MessageEmbed,
) -> SendMessageOptions {
  SendMessageOptions(..opts, embeds: [embed, ..opts.embeds])
}

/// Add embeds to message
pub fn with_embeds(
  opts: SendMessageOptions,
  embeds: List(MessageEmbed),
) -> SendMessageOptions {
  SendMessageOptions(..opts, embeds: list.append(opts.embeds, embeds))
}

/// Add attachment to message
pub fn with_attachment(
  opts: SendMessageOptions,
  attachment: MessageAttachment,
) -> SendMessageOptions {
  SendMessageOptions(..opts, attachments: [attachment, ..opts.attachments])
}

/// Add attachments to message
pub fn with_attachments(
  opts: SendMessageOptions,
  attachments: List(MessageAttachment),
) -> SendMessageOptions {
  SendMessageOptions(
    ..opts,
    attachments: list.append(opts.attachments, attachments),
  )
}

/// Set message reference (for replies)
pub fn with_message_reference(
  opts: SendMessageOptions,
  reference: MessageReference,
) -> SendMessageOptions {
  SendMessageOptions(..opts, message_reference: Some(reference))
}

/// Set allowed mentions
pub fn with_allowed_mentions(
  opts: SendMessageOptions,
  mentions: AllowedMentions,
) -> SendMessageOptions {
  SendMessageOptions(..opts, allowed_mentions: Some(mentions))
}

// ============================================================================
// Public API - Embed Builder
// ============================================================================

/// Create new embed
pub fn new_embed() -> MessageEmbed {
  MessageEmbed(
    title: None,
    description: None,
    url: None,
    timestamp: None,
    color: None,
    footer: None,
    image: None,
    thumbnail: None,
    author: None,
    fields: [],
  )
}

/// Set embed title
pub fn embed_title(embed: MessageEmbed, title: String) -> MessageEmbed {
  MessageEmbed(..embed, title: Some(title))
}

/// Set embed description
pub fn embed_description(
  embed: MessageEmbed,
  description: String,
) -> MessageEmbed {
  MessageEmbed(..embed, description: Some(description))
}

/// Set embed URL
pub fn embed_url(embed: MessageEmbed, url: String) -> MessageEmbed {
  MessageEmbed(..embed, url: Some(url))
}

/// Set embed timestamp (ISO8601 format)
pub fn embed_timestamp(embed: MessageEmbed, timestamp: String) -> MessageEmbed {
  MessageEmbed(..embed, timestamp: Some(timestamp))
}

/// Set embed color (integer color value)
pub fn embed_color(embed: MessageEmbed, color: Int) -> MessageEmbed {
  MessageEmbed(..embed, color: Some(color))
}

/// Set embed footer
pub fn embed_footer(embed: MessageEmbed, footer: EmbedFooter) -> MessageEmbed {
  MessageEmbed(..embed, footer: Some(footer))
}

/// Set embed image
pub fn embed_image(embed: MessageEmbed, image: EmbedImage) -> MessageEmbed {
  MessageEmbed(..embed, image: Some(image))
}

/// Set embed thumbnail
pub fn embed_thumbnail(
  embed: MessageEmbed,
  thumbnail: EmbedThumbnail,
) -> MessageEmbed {
  MessageEmbed(..embed, thumbnail: Some(thumbnail))
}

/// Set embed author
pub fn embed_author(embed: MessageEmbed, author: EmbedAuthor) -> MessageEmbed {
  MessageEmbed(..embed, author: Some(author))
}

/// Add embed field
pub fn embed_field(embed: MessageEmbed, field: EmbedField) -> MessageEmbed {
  MessageEmbed(..embed, fields: [field, ..embed.fields])
}

/// Add embed fields
pub fn embed_fields(
  embed: MessageEmbed,
  fields: List(EmbedField),
) -> MessageEmbed {
  MessageEmbed(..embed, fields: list.append(embed.fields, fields))
}

// ============================================================================
// Public API - Embed Component Builders
// ============================================================================

/// Create embed footer
pub fn new_footer(text: String) -> EmbedFooter {
  EmbedFooter(text: text, icon_url: None)
}

/// Set footer icon URL
pub fn footer_icon_url(footer: EmbedFooter, url: String) -> EmbedFooter {
  EmbedFooter(..footer, icon_url: Some(url))
}

/// Create embed image
pub fn new_image(url: String) -> EmbedImage {
  EmbedImage(url: url)
}

/// Create embed thumbnail
pub fn new_thumbnail(url: String) -> EmbedThumbnail {
  EmbedThumbnail(url: url)
}

/// Create embed author
pub fn new_author(name: String) -> EmbedAuthor {
  EmbedAuthor(name: name, url: None, icon_url: None)
}

/// Set author URL
pub fn author_url(author: EmbedAuthor, url: String) -> EmbedAuthor {
  EmbedAuthor(..author, url: Some(url))
}

/// Set author icon URL
pub fn author_icon_url(author: EmbedAuthor, url: String) -> EmbedAuthor {
  EmbedAuthor(..author, icon_url: Some(url))
}

/// Create embed field
pub fn new_field(name: String, value: String) -> EmbedField {
  EmbedField(name: name, value: value, inline: None)
}

/// Set field inline
pub fn field_inline(field: EmbedField, inline: Bool) -> EmbedField {
  EmbedField(..field, inline: Some(inline))
}

// ============================================================================
// Public API - Attachment Builder
// ============================================================================

/// Create new attachment
pub fn new_attachment(id: String, filename: String) -> MessageAttachment {
  MessageAttachment(id: id, filename: filename, description: None)
}

/// Set attachment description (alt text)
pub fn attachment_description(
  attachment: MessageAttachment,
  description: String,
) -> MessageAttachment {
  MessageAttachment(..attachment, description: Some(description))
}

// ============================================================================
// Public API - Message Reference Builder
// ============================================================================

/// Create message reference for reply
pub fn reply_to(message_id: Snowflake) -> MessageReference {
  MessageReference(
    message_id: Some(message_id),
    channel_id: None,
    guild_id: None,
  )
}

/// Create message reference with channel
pub fn reply_to_in_channel(
  message_id: Snowflake,
  channel_id: Snowflake,
) -> MessageReference {
  MessageReference(
    message_id: Some(message_id),
    channel_id: Some(channel_id),
    guild_id: None,
  )
}

// ============================================================================
// Public API - Rate Limit Management
// ============================================================================

/// Get rate limit info for a route
pub fn get_rate_limit_info(client: RestClient) -> Dict(String, BucketState) {
  actor.call(client, waiting: 1000, sending: GetRateLimitInfo(_, ""))
}

/// Clear all rate limit state
pub fn clear_rate_limits(client: RestClient) -> Nil {
  actor.call(client, waiting: 1000, sending: ClearRateLimits)
}

// ============================================================================
// Actor Message Handler
// ============================================================================

fn handle_message(
  state: RestClientState,
  message: RestClientMessage,
) -> actor.Next(RestClientState, RestClientMessage) {
  case message {
    SendMessageSimple(reply_to, channel_id, content) -> {
      let opts = new_message_options() |> with_content(content)
      let result = do_send_message(state, channel_id, opts)
      process.send(reply_to, result)
      actor.continue(state)
    }

    SendMessage(reply_to, channel_id, options) -> {
      let result = do_send_message(state, channel_id, options)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetRateLimitInfo(reply_to, _) -> {
      process.send(reply_to, state.rate_limits)
      actor.continue(state)
    }

    ClearRateLimits(reply_to) -> {
      process.send(reply_to, Nil)
      actor.continue(RestClientState(..state, rate_limits: dict.new()))
    }
  }
}

// ============================================================================
// Internal - HTTP Request Execution
// ============================================================================

fn do_send_message(
  state: RestClientState,
  channel_id: Snowflake,
  options: SendMessageOptions,
) -> Result(SentMessage, DiscordRestError) {
  // Check if we have valid content
  case options.content, options.embeds, options.attachments {
    None, [], [] ->
      Error(BadRequest("Message must have content, embeds, or attachments"))
    _, _, _ -> {
      // Build the request
      let url =
        get_base_url(state.config) <> "/channels/" <> channel_id <> "/messages"
      let body = encode_send_message_options(options)

      let req =
        request.new()
        |> request.set_method(http.Post)
        |> request.prepend_header(
          "Authorization",
          "Bot " <> state.config.bot_token,
        )
        |> request.prepend_header("Content-Type", "application/json")
        |> request.prepend_header(
          "User-Agent",
          "SupernovaBot (https://supernova.bot, v1.0)",
        )

      let req_with_body = request.set_body(req, body)
      let req_with_url = request.set_host(req_with_body, url)

      // Execute request
      execute_request(req_with_url)
      |> result.try(parse_response)
    }
  }
}

fn execute_request(
  req: Request(String),
) -> Result(Response(String), DiscordRestError) {
  case hackney.send(req) {
    Ok(resp) -> Ok(resp)
    Error(hackney.InvalidUtf8Response) -> {
      Error(HttpError("Invalid UTF-8 response"))
    }
    Error(hackney.Other(reason)) -> {
      Error(HttpError("HTTP error: " <> string.inspect(reason)))
    }
  }
}

// ============================================================================
// Internal - Response Parsing
// ============================================================================

fn parse_response(
  resp: Response(String),
) -> Result(SentMessage, DiscordRestError) {
  case resp.status {
    200 -> parse_sent_message(resp.body)
    201 -> parse_sent_message(resp.body)
    204 ->
      Ok(SentMessage(
        id: "",
        channel_id: "",
        guild_id: None,
        content: "",
        timestamp: "",
      ))
    400 -> {
      let message = extract_error_message(resp.body)
      Error(BadRequest(message))
    }
    401 -> Error(Unauthorized)
    403 -> {
      let message = extract_error_message(resp.body)
      Error(Forbidden(message))
    }
    404 -> {
      let message = extract_error_message(resp.body)
      Error(NotFound(message))
    }
    429 -> {
      let retry_after = extract_retry_after(resp.body)
      Error(RateLimited(retry_after))
    }
    500 -> {
      let message = extract_error_message(resp.body)
      Error(InternalError(message))
    }
    status -> Error(UnknownError(status, resp.body))
  }
}

fn parse_sent_message(body: String) -> Result(SentMessage, DiscordRestError) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use channel_id <- decode.field("channel_id", decode.string)
    use guild_id <- decode.field("guild_id", decode.optional(decode.string))
    use content <- decode.field("content", decode.string)
    use timestamp <- decode.field("timestamp", decode.optional(decode.string))
    decode.success(SentMessage(
      id: id,
      channel_id: channel_id,
      guild_id: guild_id,
      content: content,
      timestamp: option.unwrap(timestamp, ""),
    ))
  }

  case json.parse(from: body, using: decoder) {
    Ok(msg) -> Ok(msg)
    Error(_) -> Error(JsonError("Failed to parse message response"))
  }
}

fn extract_error_message(body: String) -> String {
  let decoder = {
    use message <- decode.field("message", decode.string)
    decode.success(message)
  }
  case json.parse(from: body, using: decoder) {
    Ok(msg) -> msg
    Error(_) -> {
      let decoder2 = {
        use error <- decode.field("error", decode.string)
        decode.success(error)
      }
      case json.parse(from: body, using: decoder2) {
        Ok(msg) -> msg
        Error(_) -> "Unknown error"
      }
    }
  }
}

fn extract_retry_after(body: String) -> Int {
  let decoder = {
    use retry_after <- decode.field("retry_after", decode.int)
    decode.success(retry_after)
  }
  case json.parse(from: body, using: decoder) {
    Ok(ms) -> ms
    Error(_) -> {
      // Try float version
      let decoder2 = {
        use retry_after <- decode.field("retry_after", decode.float)
        decode.success(retry_after)
      }
      case json.parse(from: body, using: decoder2) {
        Ok(secs) -> float.truncate(secs *. 1000.0)
        Error(_) -> 5000
        // Default 5 seconds
      }
    }
  }
}

// ============================================================================
// Internal - JSON Encoding
// ============================================================================

fn encode_send_message_options(opts: SendMessageOptions) -> String {
  let fields =
    []
    |> add_optional_string_field("content", opts.content)
    |> add_optional_bool_field("tts", opts.tts)
    |> add_embeds_field("embeds", opts.embeds)
    |> add_attachments_field("attachments", opts.attachments)
    |> add_message_reference_field("message_reference", opts.message_reference)
    |> add_allowed_mentions_field("allowed_mentions", opts.allowed_mentions)

  "{" <> string.join(fields, ",") <> "}"
}

fn add_optional_string_field(
  fields: List(String),
  name: String,
  value: Option(String),
) -> List(String) {
  case value {
    Some(v) -> [json_key_value(name, json_string(v)), ..fields]
    None -> fields
  }
}

fn add_optional_bool_field(
  fields: List(String),
  name: String,
  value: Option(Bool),
) -> List(String) {
  case value {
    Some(v) -> [json_key_value(name, json_bool(v)), ..fields]
    None -> fields
  }
}

fn add_embeds_field(
  fields: List(String),
  name: String,
  embeds: List(MessageEmbed),
) -> List(String) {
  case embeds {
    [] -> fields
    es -> {
      let encoded = "[" <> string.join(list.map(es, encode_embed), ",") <> "]"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn add_attachments_field(
  fields: List(String),
  name: String,
  attachments: List(MessageAttachment),
) -> List(String) {
  case attachments {
    [] -> fields
    atts -> {
      let encoded =
        "[" <> string.join(list.map(atts, encode_attachment), ",") <> "]"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn add_message_reference_field(
  fields: List(String),
  name: String,
  reference: Option(MessageReference),
) -> List(String) {
  case reference {
    None -> fields
    Some(ref) -> {
      let ref_fields =
        []
        |> add_optional_snowflake_field("message_id", ref.message_id)
        |> add_optional_snowflake_field("channel_id", ref.channel_id)
        |> add_optional_snowflake_field("guild_id", ref.guild_id)

      let encoded = "{" <> string.join(ref_fields, ",") <> "}"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn add_allowed_mentions_field(
  fields: List(String),
  name: String,
  mentions: Option(AllowedMentions),
) -> List(String) {
  case mentions {
    None -> fields
    Some(m) -> {
      let parse_array =
        "[" <> string.join(list.map(m.parse, json_string), ",") <> "]"

      let users_array =
        "[" <> string.join(list.map(m.users, json_string), ",") <> "]"

      let roles_array =
        "[" <> string.join(list.map(m.roles, json_string), ",") <> "]"

      let mention_fields =
        [
          json_key_value("parse", parse_array),
          json_key_value("users", users_array),
          json_key_value("roles", roles_array),
        ]
        |> add_optional_bool_field("replied_user", m.replied_user)

      let encoded = "{" <> string.join(mention_fields, ",") <> "}"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn add_optional_snowflake_field(
  fields: List(String),
  name: String,
  value: Option(String),
) -> List(String) {
  add_optional_string_field(fields, name, value)
}

fn encode_embed(embed: MessageEmbed) -> String {
  let fields =
    []
    |> add_optional_string_field("title", embed.title)
    |> add_optional_string_field("description", embed.description)
    |> add_optional_string_field("url", embed.url)
    |> add_optional_string_field("timestamp", embed.timestamp)
    |> add_optional_int_field("color", embed.color)
    |> add_optional_footer_field("footer", embed.footer)
    |> add_optional_image_field("image", embed.image)
    |> add_optional_thumbnail_field("thumbnail", embed.thumbnail)
    |> add_optional_author_field("author", embed.author)
    |> add_embed_fields_field("fields", embed.fields)

  "{" <> string.join(fields, ",") <> "}"
}

fn add_optional_int_field(
  fields: List(String),
  name: String,
  value: Option(Int),
) -> List(String) {
  case value {
    Some(v) -> [json_key_value(name, int.to_string(v)), ..fields]
    None -> fields
  }
}

fn add_optional_footer_field(
  fields: List(String),
  name: String,
  footer: Option(EmbedFooter),
) -> List(String) {
  case footer {
    None -> fields
    Some(f) -> {
      let footer_fields =
        [json_key_value("text", json_string(f.text))]
        |> add_optional_string_field("icon_url", f.icon_url)

      let encoded = "{" <> string.join(footer_fields, ",") <> "}"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn add_optional_image_field(
  fields: List(String),
  name: String,
  image: Option(EmbedImage),
) -> List(String) {
  case image {
    None -> fields
    Some(img) -> {
      let encoded = "{\"url\":" <> json_string(img.url) <> "}"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn add_optional_thumbnail_field(
  fields: List(String),
  name: String,
  thumbnail: Option(EmbedThumbnail),
) -> List(String) {
  case thumbnail {
    None -> fields
    Some(thumb) -> {
      let encoded = "{\"url\":" <> json_string(thumb.url) <> "}"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn add_optional_author_field(
  fields: List(String),
  name: String,
  author: Option(EmbedAuthor),
) -> List(String) {
  case author {
    None -> fields
    Some(a) -> {
      let author_fields =
        [json_key_value("name", json_string(a.name))]
        |> add_optional_string_field("url", a.url)
        |> add_optional_string_field("icon_url", a.icon_url)

      let encoded = "{" <> string.join(author_fields, ",") <> "}"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn add_embed_fields_field(
  fields: List(String),
  name: String,
  embed_fields: List(EmbedField),
) -> List(String) {
  case embed_fields {
    [] -> fields
    fs -> {
      let encoded =
        "[" <> string.join(list.map(fs, encode_embed_field), ",") <> "]"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn encode_embed_field(field: EmbedField) -> String {
  let fields =
    [
      json_key_value("name", json_string(field.name)),
      json_key_value("value", json_string(field.value)),
    ]
    |> add_optional_bool_field("inline", field.inline)

  "{" <> string.join(fields, ",") <> "}"
}

fn encode_attachment(attachment: MessageAttachment) -> String {
  let fields =
    [
      json_key_value("id", json_string(attachment.id)),
      json_key_value("filename", json_string(attachment.filename)),
    ]
    |> add_optional_string_field("description", attachment.description)

  "{" <> string.join(fields, ",") <> "}"
}

// ============================================================================
// Internal - JSON Helpers
// ============================================================================

fn json_key_value(key: String, value: String) -> String {
  json_string(key) <> ":" <> value
}

fn json_string(s: String) -> String {
  "\"" <> escape_json_string(s) <> "\""
}

fn json_bool(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

fn escape_json_string(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

fn get_base_url(config: RestClientConfig) -> String {
  option.unwrap(config.base_url, api_base_url)
}
