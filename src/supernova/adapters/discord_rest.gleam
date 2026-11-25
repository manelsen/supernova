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
import supernova/core/safe_call

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

/// Action row container for interactive message components.
pub type MessageComponentRow {
  MessageComponentRow(components: List(MessageComponent))
}

/// Message component supported by the send-message endpoint.
pub type MessageComponent {
  MessageButton(style: MessageButtonStyle, label: String, custom_id: String)
  MessageStringSelect(
    custom_id: String,
    placeholder: Option(String),
    options: List(MessageSelectOption),
  )
}

/// Button styles for interactive message components.
pub type MessageButtonStyle {
  PrimaryButtonStyle
  SecondaryButtonStyle
  SuccessButtonStyle
  DangerButtonStyle
}

/// Select menu option for a string select component.
pub type MessageSelectOption {
  MessageSelectOption(label: String, value: String)
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
    components: List(MessageComponentRow),
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
    /// DM channel of each person already opened: Discord keeps it, so it
    /// is asked once per person.
    dm_channels: Dict(Snowflake, Snowflake),
  )
}

/// REST client actor messages
pub type RestClientMessage {
  SendMessage(
    reply_to: Subject(Result(SentMessage, DiscordRestError)),
    channel_id: Snowflake,
    options: SendMessageOptions,
  )
  EditMessage(
    reply_to: Subject(Result(SentMessage, DiscordRestError)),
    channel_id: Snowflake,
    message_id: Snowflake,
    options: SendMessageOptions,
  )
  SendMessageSimple(
    reply_to: Subject(Result(SentMessage, DiscordRestError)),
    channel_id: Snowflake,
    content: String,
  )
  OpenDm(
    reply_to: Subject(Result(Snowflake, DiscordRestError)),
    user_id: Snowflake,
  )
  TriggerTyping(
    reply_to: Subject(Result(Nil, DiscordRestError)),
    channel_id: Snowflake,
  )
  GetRateLimitInfo(reply_to: Subject(Dict(String, BucketState)), route: String)
  ClearRateLimits(reply_to: Subject(Nil))
  Stop(reply_to: Subject(Nil))
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
pub fn with_base_url(
  config: RestClientConfig,
  url: String,
) -> RestClientConfig {
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
      dm_channels: dict.new(),
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

/// Open (or reuse) the DM channel with a user and return its channel id.
pub fn open_dm(
  client: RestClient,
  user_id: Snowflake,
) -> Result(Snowflake, DiscordRestError) {
  case safe_call.call(client, 5000, OpenDm(_, user_id)) {
    Ok(result) -> result
    Error(_) -> Error(HttpError("HTTP error: DM channel unavailable"))
  }
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

/// Edit an existing message with full options.
pub fn edit_message_with_options(
  client: RestClient,
  channel_id: Snowflake,
  message_id: Snowflake,
  options: SendMessageOptions,
) -> Result(SentMessage, DiscordRestError) {
  actor.call(client, waiting: 60_000, sending: EditMessage(
    _,
    channel_id,
    message_id,
    options,
  ))
}

/// Answer an interaction (PRD-D, 6.2). Runs in the caller's process, not
/// through the client actor: Discord gives 3 s, and the answer must not wait
/// behind other requests.
pub fn interaction_callback(
  config: RestClientConfig,
  interaction_id: Snowflake,
  token: String,
  body: String,
) -> Result(Nil, DiscordRestError) {
  use req <- result.try(base_request(
    config,
    http.Post,
    "/interactions/" <> interaction_id <> "/" <> token <> "/callback",
  ))
  use resp <- result.try(
    req
    |> request.prepend_header("Content-Type", "application/json")
    |> request.set_body(body)
    |> execute_request,
  )
  case resp.status {
    200 | 204 -> Ok(Nil)
    400 -> Error(BadRequest(extract_error_message(resp.body)))
    401 -> Error(Unauthorized)
    404 -> Error(NotFound(extract_error_message(resp.body)))
    429 -> Error(RateLimited(extract_retry_after(resp.body)))
    status -> Error(UnknownError(status, resp.body))
  }
}

/// A slash command to register: name, description and whether it takes
/// arguments (one optional `args` text option with autocomplete, D6).
pub type SlashCommand {
  SlashCommand(name: String, description: String, takes_arguments: Bool)
}

/// Whether Discord accepts this command: a lowercase name of 1 to 32
/// letters, digits, `-` or `_`, and a description of 1 to 100 characters.
pub fn valid_slash_command(command: SlashCommand) -> Bool {
  let name_ok =
    string.length(command.name) >= 1
    && string.length(command.name) <= 32
    && string.lowercase(command.name) == command.name
    && list.all(string.to_graphemes(command.name), fn(char) {
      char == "-"
      || char == "_"
      || string.contains("abcdefghijklmnopqrstuvwxyz0123456789", char)
    })
  let description_length = string.length(command.description)
  name_ok && description_length >= 1 && description_length <= 100
}

/// The body of a bulk overwrite: the whole list replaces what was there.
pub fn slash_commands_body(commands: List(SlashCommand)) -> String {
  json.array(commands, fn(command) {
    let options = case command.takes_arguments {
      False -> []
      True -> [
        json.object([
          #("type", json.int(3)),
          #("name", json.string("args")),
          #("description", json.string("O que vem depois do comando")),
          #("required", json.bool(False)),
          #("autocomplete", json.bool(True)),
        ]),
      ]
    }
    json.object([
      #("name", json.string(command.name)),
      #("description", json.string(command.description)),
      #("type", json.int(1)),
      #("options", json.preprocessed_array(options)),
    ])
  })
  |> json.to_string
}

/// Replace the application's slash commands, globally or in one server.
/// Runs in the caller's process.
pub fn overwrite_slash_commands(
  config: RestClientConfig,
  application_id: Snowflake,
  guild_id: Option(Snowflake),
  body: String,
) -> Result(Nil, DiscordRestError) {
  let path = case guild_id {
    Some(guild) ->
      "/applications/" <> application_id <> "/guilds/" <> guild <> "/commands"
    None -> "/applications/" <> application_id <> "/commands"
  }
  use req <- result.try(base_request(config, http.Put, path))
  use resp <- result.try(
    req
    |> request.prepend_header("Content-Type", "application/json")
    |> request.set_body(body)
    |> execute_request,
  )
  case resp.status {
    200 | 201 | 204 -> Ok(Nil)
    400 -> Error(BadRequest(extract_error_message(resp.body)))
    401 -> Error(Unauthorized)
    403 -> Error(Forbidden(extract_error_message(resp.body)))
    429 -> Error(RateLimited(extract_retry_after(resp.body)))
    status -> Error(UnknownError(status, resp.body))
  }
}

/// Acknowledge a button or menu without changing anything yet (type 6). The
/// answer comes later by editing the message that held it.
pub fn deferred_update_response() -> String {
  json.object([#("type", json.int(6))]) |> json.to_string
}

/// Answer a slash command by showing it in the channel (type 4), the way a
/// typed command shows in Telegram. The agent's reply follows as a message.
pub fn command_echo_response(content: String) -> String {
  json.object([
    #("type", json.int(4)),
    #(
      "data",
      json.object([
        #("content", json.string(content)),
        #("allowed_mentions", no_mentions()),
      ]),
    ),
  ])
  |> json.to_string
}

/// Suggestions while a slash command option is typed (type 8). Discord takes
/// at most 25, each up to 100 characters.
pub fn autocomplete_response(choices: List(#(String, String))) -> String {
  let choices =
    choices
    |> list.filter(fn(choice) { choice.1 != "" })
    |> list.map(fn(choice) {
      #(string.slice(choice.0, 0, 100), string.slice(choice.1, 0, 100))
    })
    |> list.take(25)
  json.object([
    #("type", json.int(8)),
    #(
      "data",
      json.object([
        #(
          "choices",
          json.array(choices, fn(choice) {
            json.object([
              #("name", json.string(choice.0)),
              #("value", json.string(choice.1)),
            ])
          }),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

/// `allowed_mentions` that pings nobody: no @everyone, @here, role or user.
pub fn no_mentions() -> json.Json {
  json.object([#("parse", json.preprocessed_array([]))])
}

/// Trigger Discord's typing indicator for a channel or thread.
pub fn trigger_typing_indicator(
  client: RestClient,
  channel_id: Snowflake,
) -> Result(Nil, DiscordRestError) {
  actor.call(client, waiting: 60_000, sending: TriggerTyping(_, channel_id))
}

/// Stop the REST client actor.
pub fn stop(client: RestClient) -> Nil {
  actor.call(client, waiting: 5000, sending: Stop)
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
    components: [],
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

/// Attach interactive message components.
pub fn with_components(
  opts: SendMessageOptions,
  components: List(MessageComponentRow),
) -> SendMessageOptions {
  SendMessageOptions(..opts, components: components)
}

/// Create an action row from components.
pub fn action_row(components: List(MessageComponent)) -> MessageComponentRow {
  MessageComponentRow(components: components)
}

/// Create a primary button component.
pub fn primary_button(custom_id: String, label: String) -> MessageComponent {
  MessageButton(style: PrimaryButtonStyle, label: label, custom_id: custom_id)
}

/// Create a secondary button component.
pub fn secondary_button(custom_id: String, label: String) -> MessageComponent {
  MessageButton(style: SecondaryButtonStyle, label: label, custom_id: custom_id)
}

/// Create a success button component.
pub fn success_button(custom_id: String, label: String) -> MessageComponent {
  MessageButton(style: SuccessButtonStyle, label: label, custom_id: custom_id)
}

/// Create a danger button component.
pub fn danger_button(custom_id: String, label: String) -> MessageComponent {
  MessageButton(style: DangerButtonStyle, label: label, custom_id: custom_id)
}

/// Create a string select menu component.
pub fn string_select(
  custom_id: String,
  options: List(MessageSelectOption),
) -> MessageComponent {
  MessageStringSelect(custom_id: custom_id, placeholder: None, options: options)
}

/// Create a select option for string select components.
pub fn select_option(label: String, value: String) -> MessageSelectOption {
  MessageSelectOption(label: label, value: value)
}

/// Set a placeholder on a string select component.
pub fn select_with_placeholder(
  component: MessageComponent,
  placeholder: String,
) -> MessageComponent {
  case component {
    MessageStringSelect(custom_id, _, options) ->
      MessageStringSelect(
        custom_id: custom_id,
        placeholder: Some(placeholder),
        options: options,
      )
    _ -> component
  }
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

    OpenDm(reply_to, user_id) ->
      case dict.get(state.dm_channels, user_id) {
        Ok(channel_id) -> {
          process.send(reply_to, Ok(channel_id))
          actor.continue(state)
        }
        Error(Nil) -> {
          let result = do_open_dm(state, user_id)
          process.send(reply_to, result)
          case result {
            Ok(channel_id) ->
              actor.continue(
                RestClientState(
                  ..state,
                  dm_channels: dict.insert(
                    state.dm_channels,
                    user_id,
                    channel_id,
                  ),
                ),
              )
            Error(_) -> actor.continue(state)
          }
        }
      }

    EditMessage(reply_to, channel_id, message_id, options) -> {
      let result = do_edit_message(state, channel_id, message_id, options)
      process.send(reply_to, result)
      actor.continue(state)
    }

    TriggerTyping(reply_to, channel_id) -> {
      let result = do_trigger_typing(state, channel_id)
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

    Stop(reply_to) -> {
      process.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Internal - HTTP Request Execution
// ============================================================================

fn do_open_dm(
  state: RestClientState,
  user_id: Snowflake,
) -> Result(Snowflake, DiscordRestError) {
  let body =
    json.object([#("recipient_id", json.string(user_id))]) |> json.to_string
  case execute_json_request(state, http.Post, "/users/@me/channels", body) {
    Error(error) -> Error(error)
    Ok(resp) ->
      case resp.status {
        200 | 201 -> {
          let decoder = {
            use id <- decode.field("id", decode.string)
            decode.success(id)
          }
          case json.parse(from: resp.body, using: decoder) {
            Ok(channel_id) -> Ok(channel_id)
            Error(_) -> Error(JsonError("DM channel response has no id"))
          }
        }
        400 -> Error(BadRequest(extract_error_message(resp.body)))
        401 -> Error(Unauthorized)
        403 -> Error(Forbidden(extract_error_message(resp.body)))
        404 -> Error(NotFound(extract_error_message(resp.body)))
        429 -> Error(RateLimited(extract_retry_after(resp.body)))
        500 -> Error(InternalError(extract_error_message(resp.body)))
        status -> Error(UnknownError(status, resp.body))
      }
  }
}

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
      execute_message_request(
        state,
        http.Post,
        "/channels/" <> channel_id <> "/messages",
        options,
      )
      |> result.try(parse_response)
    }
  }
}

fn do_edit_message(
  state: RestClientState,
  channel_id: Snowflake,
  message_id: Snowflake,
  options: SendMessageOptions,
) -> Result(SentMessage, DiscordRestError) {
  case options.content, options.embeds, options.attachments {
    None, [], [] ->
      Error(BadRequest("Message must have content, embeds, or attachments"))
    _, _, _ ->
      execute_message_request(
        state,
        http.Patch,
        "/channels/" <> channel_id <> "/messages/" <> message_id,
        options,
      )
      |> result.try(parse_response)
  }
}

fn do_trigger_typing(
  state: RestClientState,
  channel_id: Snowflake,
) -> Result(Nil, DiscordRestError) {
  execute_empty_request(
    state,
    http.Post,
    "/channels/" <> channel_id <> "/typing",
  )
  |> result.try(parse_empty_response)
}

fn execute_message_request(
  state: RestClientState,
  method: http.Method,
  path: String,
  options: SendMessageOptions,
) -> Result(Response(String), DiscordRestError) {
  execute_json_request(state, method, path, encode_message_options(options))
}

fn execute_json_request(
  state: RestClientState,
  method: http.Method,
  path: String,
  body: String,
) -> Result(Response(String), DiscordRestError) {
  use req <- result.try(base_request(state.config, method, path))
  req
  |> request.prepend_header("Content-Type", "application/json")
  |> request.set_body(body)
  |> execute_request
}

fn execute_empty_request(
  state: RestClientState,
  method: http.Method,
  path: String,
) -> Result(Response(String), DiscordRestError) {
  use req <- result.try(base_request(state.config, method, path))
  execute_request(request.set_body(req, ""))
}

/// A request to `base_url <> path`, with the bot's authorization. The URL is
/// parsed into scheme, host, port and path: putting the whole URL in the host
/// (as before) made every request fail to connect.
fn base_request(
  config: RestClientConfig,
  method: http.Method,
  path: String,
) -> Result(Request(String), DiscordRestError) {
  case request.to(get_base_url(config) <> path) {
    Error(_) -> Error(HttpError("invalid Discord API URL"))
    Ok(req) ->
      Ok(
        req
        |> request.set_method(method)
        |> request.prepend_header("Authorization", "Bot " <> config.bot_token)
        |> request.prepend_header(
          "User-Agent",
          "DiscordBot (https://supernova.bot, 0.4)",
        ),
      )
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

fn parse_empty_response(
  resp: Response(String),
) -> Result(Nil, DiscordRestError) {
  case parse_response(resp) {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

pub fn parse_sent_message(
  body: String,
) -> Result(SentMessage, DiscordRestError) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use channel_id <- decode.field("channel_id", decode.string)
    // A REST message carries no `guild_id`, and `content` is empty for a
    // message with only attachments.
    use guild_id <- decode.optional_field(
      "guild_id",
      None,
      decode.optional(decode.string),
    )
    use content <- decode.optional_field("content", "", decode.string)
    use timestamp <- decode.optional_field(
      "timestamp",
      None,
      decode.optional(decode.string),
    )
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

/// Discord's `retry_after` is in seconds, whole or fractional (`5`,
/// `0.35`); the result is in milliseconds, rounded up. Without one, 5 s.
pub fn extract_retry_after(body: String) -> Int {
  let seconds =
    decode.one_of(decode.float, or: [decode.map(decode.int, int.to_float)])
  case json.parse(from: body, using: decode.at(["retry_after"], seconds)) {
    Ok(secs) -> float.round(float.ceiling(secs *. 1000.0))
    Error(_) -> 5000
  }
}

// ============================================================================
// Internal - JSON Encoding
// ============================================================================

pub fn encode_message_options(opts: SendMessageOptions) -> String {
  let fields =
    []
    |> add_optional_string_field("content", opts.content)
    |> add_optional_bool_field("tts", opts.tts)
    |> add_embeds_field("embeds", opts.embeds)
    |> add_attachments_field("attachments", opts.attachments)
    |> add_message_reference_field("message_reference", opts.message_reference)
    |> add_allowed_mentions_field("allowed_mentions", opts.allowed_mentions)
    |> add_components_field("components", opts.components)

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

fn add_components_field(
  fields: List(String),
  name: String,
  components: List(MessageComponentRow),
) -> List(String) {
  case components {
    [] -> fields
    rows -> {
      let encoded =
        "[" <> string.join(list.map(rows, encode_component_row), ",") <> "]"
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

fn encode_component_row(row: MessageComponentRow) -> String {
  let MessageComponentRow(components:) = row
  let encoded =
    "[" <> string.join(list.map(components, encode_component), ",") <> "]"

  "{\"type\":1,\"components\":" <> encoded <> "}"
}

fn encode_component(component: MessageComponent) -> String {
  case component {
    MessageButton(style, label, custom_id) ->
      "{\"type\":2,\"style\":"
      <> int.to_string(encode_button_style(style))
      <> ",\"label\":"
      <> json_string(label)
      <> ",\"custom_id\":"
      <> json_string(custom_id)
      <> "}"
    MessageStringSelect(custom_id, placeholder, options) ->
      "{\"type\":3,\"custom_id\":"
      <> json_string(custom_id)
      <> encode_select_placeholder(placeholder)
      <> ",\"options\":"
      <> "["
      <> string.join(list.map(options, encode_select_option), ",")
      <> "]}"
  }
}

fn encode_button_style(style: MessageButtonStyle) -> Int {
  case style {
    PrimaryButtonStyle -> 1
    SecondaryButtonStyle -> 2
    SuccessButtonStyle -> 3
    DangerButtonStyle -> 4
  }
}

fn encode_select_placeholder(placeholder: Option(String)) -> String {
  case placeholder {
    Some(value) -> ",\"placeholder\":" <> json_string(value)
    None -> ""
  }
}

fn encode_select_option(option: MessageSelectOption) -> String {
  let MessageSelectOption(label:, value:) = option

  "{\"label\":"
  <> json_string(label)
  <> ",\"value\":"
  <> json_string(value)
  <> "}"
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
  |> string.to_utf_codepoints
  |> list.map(fn(codepoint) {
    case string.utf_codepoint_to_int(codepoint) {
      0x5C -> "\\\\"
      0x22 -> "\\\""
      0x0A -> "\\n"
      0x0D -> "\\r"
      0x09 -> "\\t"
      // Any other control character is invalid raw in JSON.
      code if code < 0x20 ->
        "\\u00" <> string.pad_start(int.to_base16(code), 2, "0")
      _ -> string.from_utf_codepoints([codepoint])
    }
  })
  |> string.concat
}

fn get_base_url(config: RestClientConfig) -> String {
  option.unwrap(config.base_url, api_base_url)
}
