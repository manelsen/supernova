//// Discord Webhooks Module
//// Provides:
//// - Webhook creation and configuration via Discord REST API
//// - Execute webhooks with custom username/avatar
//// - Embed support for webhook messages
//// - Thread support for webhook execution
//// - Webhook message editing and deletion
////
//// This module uses the same HTTP client patterns as discord_rest.

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
// Types - Webhook
// ============================================================================

/// Webhook type
pub type WebhookType {
  /// Incoming webhook (can post messages)
  Incoming
  /// Channel following webhook (posted by Discord)
  ChannelFollower
  /// Application webhook (posted by application)
  Application
}

/// Webhook information
pub type Webhook {
  Webhook(
    id: Snowflake,
    webhook_type: WebhookType,
    guild_id: Option(Snowflake),
    channel_id: Option(Snowflake),
    name: Option(String),
    avatar: Option(String),
    token: Option(String),
    application_id: Option(Snowflake),
  )
}

/// Webhook creation options
pub type CreateWebhookOptions {
  CreateWebhookOptions(name: String, avatar: Option(String))
}

/// Webhook modification options
pub type ModifyWebhookOptions {
  ModifyWebhookOptions(
    name: Option(String),
    avatar: Option(String),
    channel_id: Option(Snowflake),
  )
}

// ============================================================================
// Types - Webhook Execution
// ============================================================================

/// Options for executing a webhook
pub type ExecuteWebhookOptions {
  ExecuteWebhookOptions(
    content: Option(String),
    username: Option(String),
    avatar_url: Option(String),
    tts: Option(Bool),
    embeds: List(WebhookEmbed),
    allowed_mentions: Option(AllowedMentions),
    thread_id: Option(Snowflake),
    wait: Option(Bool),
  )
}

/// Webhook embed (same structure as message embed)
pub type WebhookEmbed {
  WebhookEmbed(
    title: Option(String),
    description: Option(String),
    url: Option(String),
    timestamp: Option(String),
    color: Option(Int),
    footer: Option(WebhookEmbedFooter),
    image: Option(WebhookEmbedImage),
    thumbnail: Option(WebhookEmbedThumbnail),
    author: Option(WebhookEmbedAuthor),
    fields: List(WebhookEmbedField),
  )
}

/// Webhook embed footer
pub type WebhookEmbedFooter {
  WebhookEmbedFooter(text: String, icon_url: Option(String))
}

/// Webhook embed image
pub type WebhookEmbedImage {
  WebhookEmbedImage(url: String)
}

/// Webhook embed thumbnail
pub type WebhookEmbedThumbnail {
  WebhookEmbedThumbnail(url: String)
}

/// Webhook embed author
pub type WebhookEmbedAuthor {
  WebhookEmbedAuthor(
    name: String,
    url: Option(String),
    icon_url: Option(String),
  )
}

/// Webhook embed field
pub type WebhookEmbedField {
  WebhookEmbedField(name: String, value: String, inline: Option(Bool))
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
// Types - Webhook Message
// ============================================================================

/// Webhook message response
pub type WebhookMessage {
  WebhookMessage(
    id: Snowflake,
    channel_id: Snowflake,
    content: String,
    timestamp: String,
  )
}

/// Options for editing a webhook message
pub type EditWebhookMessageOptions {
  EditWebhookMessageOptions(
    content: Option(String),
    embeds: List(WebhookEmbed),
    allowed_mentions: Option(AllowedMentions),
  )
}

// ============================================================================
// Types - Errors
// ============================================================================

/// Discord Webhook API error
pub type WebhookError {
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
  /// Invalid webhook token
  InvalidToken
  /// Webhook not found
  WebhookNotFound
}

// ============================================================================
// Types - Client Configuration
// ============================================================================

/// Webhook client configuration
pub type WebhookClientConfig {
  WebhookClientConfig(
    bot_token: String,
    base_url: Option(String),
    timeout_ms: Int,
  )
}

// ============================================================================
// Types - Actor State
// ============================================================================

/// Webhook client actor state
pub type WebhookClientState {
  WebhookClientState(config: WebhookClientConfig)
}

/// Webhook client actor messages
pub type WebhookClientMessage {
  CreateWebhook(
    reply_to: Subject(Result(Webhook, WebhookError)),
    channel_id: Snowflake,
    options: CreateWebhookOptions,
  )
  GetWebhook(
    reply_to: Subject(Result(Webhook, WebhookError)),
    webhook_id: Snowflake,
  )
  GetWebhookWithToken(
    reply_to: Subject(Result(Webhook, WebhookError)),
    webhook_id: Snowflake,
    token: String,
  )
  ModifyWebhook(
    reply_to: Subject(Result(Webhook, WebhookError)),
    webhook_id: Snowflake,
    options: ModifyWebhookOptions,
  )
  ModifyWebhookWithToken(
    reply_to: Subject(Result(Webhook, WebhookError)),
    webhook_id: Snowflake,
    token: String,
    options: ModifyWebhookOptions,
  )
  DeleteWebhook(
    reply_to: Subject(Result(Nil, WebhookError)),
    webhook_id: Snowflake,
  )
  DeleteWebhookWithToken(
    reply_to: Subject(Result(Nil, WebhookError)),
    webhook_id: Snowflake,
    token: String,
  )
  ExecuteWebhook(
    reply_to: Subject(Result(Option(WebhookMessage), WebhookError)),
    webhook_id: Snowflake,
    token: String,
    options: ExecuteWebhookOptions,
  )
  EditWebhookMessage(
    reply_to: Subject(Result(WebhookMessage, WebhookError)),
    webhook_id: Snowflake,
    token: String,
    message_id: Snowflake,
    options: EditWebhookMessageOptions,
  )
  DeleteWebhookMessage(
    reply_to: Subject(Result(Nil, WebhookError)),
    webhook_id: Snowflake,
    token: String,
    message_id: Snowflake,
  )
  GetChannelWebhooks(
    reply_to: Subject(Result(List(Webhook), WebhookError)),
    channel_id: Snowflake,
  )
  GetGuildWebhooks(
    reply_to: Subject(Result(List(Webhook), WebhookError)),
    guild_id: Snowflake,
  )
}

/// Webhook client type (actor subject)
pub type WebhookClient =
  Subject(WebhookClientMessage)

// ============================================================================
// Public API - Configuration
// ============================================================================

/// Create default webhook client configuration
pub fn new_config(bot_token: String) -> WebhookClientConfig {
  WebhookClientConfig(bot_token: bot_token, base_url: None, timeout_ms: 30_000)
}

/// Set custom base URL
pub fn with_base_url(
  config: WebhookClientConfig,
  url: String,
) -> WebhookClientConfig {
  WebhookClientConfig(..config, base_url: Some(url))
}

/// Set timeout in milliseconds
pub fn with_timeout(
  config: WebhookClientConfig,
  timeout_ms: Int,
) -> WebhookClientConfig {
  WebhookClientConfig(..config, timeout_ms: timeout_ms)
}

// ============================================================================
// Public API - Client Lifecycle
// ============================================================================

/// Start a new webhook client actor
pub fn start(
  config: WebhookClientConfig,
) -> Result(WebhookClient, actor.StartError) {
  let initial_state = WebhookClientState(config: config)

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
// Public API - Webhook CRUD
// ============================================================================

/// Create a new webhook in a channel
pub fn create_webhook(
  client: WebhookClient,
  channel_id: Snowflake,
  options: CreateWebhookOptions,
) -> Result(Webhook, WebhookError) {
  actor.call(client, waiting: 60_000, sending: CreateWebhook(
    _,
    channel_id,
    options,
  ))
}

/// Get a webhook by ID (requires bot token)
pub fn get_webhook(
  client: WebhookClient,
  webhook_id: Snowflake,
) -> Result(Webhook, WebhookError) {
  actor.call(client, waiting: 60_000, sending: GetWebhook(_, webhook_id))
}

/// Get a webhook by ID with token (no bot token required)
pub fn get_webhook_with_token(
  client: WebhookClient,
  webhook_id: Snowflake,
  token: String,
) -> Result(Webhook, WebhookError) {
  actor.call(client, waiting: 60_000, sending: GetWebhookWithToken(
    _,
    webhook_id,
    token,
  ))
}

/// Modify a webhook (requires bot token)
pub fn modify_webhook(
  client: WebhookClient,
  webhook_id: Snowflake,
  options: ModifyWebhookOptions,
) -> Result(Webhook, WebhookError) {
  actor.call(client, waiting: 60_000, sending: ModifyWebhook(
    _,
    webhook_id,
    options,
  ))
}

/// Modify a webhook with token (no bot token required)
pub fn modify_webhook_with_token(
  client: WebhookClient,
  webhook_id: Snowflake,
  token: String,
  options: ModifyWebhookOptions,
) -> Result(Webhook, WebhookError) {
  actor.call(client, waiting: 60_000, sending: ModifyWebhookWithToken(
    _,
    webhook_id,
    token,
    options,
  ))
}

/// Delete a webhook (requires bot token)
pub fn delete_webhook(
  client: WebhookClient,
  webhook_id: Snowflake,
) -> Result(Nil, WebhookError) {
  actor.call(client, waiting: 60_000, sending: DeleteWebhook(_, webhook_id))
}

/// Delete a webhook with token (no bot token required)
pub fn delete_webhook_with_token(
  client: WebhookClient,
  webhook_id: Snowflake,
  token: String,
) -> Result(Nil, WebhookError) {
  actor.call(client, waiting: 60_000, sending: DeleteWebhookWithToken(
    _,
    webhook_id,
    token,
  ))
}

/// Get all webhooks for a channel
pub fn get_channel_webhooks(
  client: WebhookClient,
  channel_id: Snowflake,
) -> Result(List(Webhook), WebhookError) {
  actor.call(client, waiting: 60_000, sending: GetChannelWebhooks(_, channel_id))
}

/// Get all webhooks for a guild
pub fn get_guild_webhooks(
  client: WebhookClient,
  guild_id: Snowflake,
) -> Result(List(Webhook), WebhookError) {
  actor.call(client, waiting: 60_000, sending: GetGuildWebhooks(_, guild_id))
}

// ============================================================================
// Public API - Execute Webhook
// ============================================================================

/// Execute a webhook (send a message)
/// Returns None if wait=false, otherwise returns the message
pub fn execute_webhook(
  client: WebhookClient,
  webhook_id: Snowflake,
  token: String,
  options: ExecuteWebhookOptions,
) -> Result(Option(WebhookMessage), WebhookError) {
  actor.call(client, waiting: 60_000, sending: ExecuteWebhook(
    _,
    webhook_id,
    token,
    options,
  ))
}

/// Execute a webhook and wait for the message to be sent
pub fn execute_webhook_and_wait(
  client: WebhookClient,
  webhook_id: Snowflake,
  token: String,
  options: ExecuteWebhookOptions,
) -> Result(WebhookMessage, WebhookError) {
  let opts = options |> with_wait(True)
  case
    actor.call(client, waiting: 60_000, sending: ExecuteWebhook(
      _,
      webhook_id,
      token,
      opts,
    ))
  {
    Ok(Some(msg)) -> Ok(msg)
    Ok(None) -> Error(BadRequest("Webhook execution returned no message"))
    Error(e) -> Error(e)
  }
}

/// Edit a webhook message
pub fn edit_webhook_message(
  client: WebhookClient,
  webhook_id: Snowflake,
  token: String,
  message_id: Snowflake,
  options: EditWebhookMessageOptions,
) -> Result(WebhookMessage, WebhookError) {
  actor.call(client, waiting: 60_000, sending: EditWebhookMessage(
    _,
    webhook_id,
    token,
    message_id,
    options,
  ))
}

/// Delete a webhook message
pub fn delete_webhook_message(
  client: WebhookClient,
  webhook_id: Snowflake,
  token: String,
  message_id: Snowflake,
) -> Result(Nil, WebhookError) {
  actor.call(client, waiting: 60_000, sending: DeleteWebhookMessage(
    _,
    webhook_id,
    token,
    message_id,
  ))
}

// ============================================================================
// Public API - Create Webhook Options Builder
// ============================================================================

/// Create new webhook creation options
pub fn new_create_webhook_options(name: String) -> CreateWebhookOptions {
  CreateWebhookOptions(name: name, avatar: None)
}

/// Set webhook avatar (base64 data URI)
pub fn with_webhook_avatar(
  opts: CreateWebhookOptions,
  avatar: String,
) -> CreateWebhookOptions {
  CreateWebhookOptions(..opts, avatar: Some(avatar))
}

// ============================================================================
// Public API - Modify Webhook Options Builder
// ============================================================================

/// Create new webhook modification options
pub fn new_modify_webhook_options() -> ModifyWebhookOptions {
  ModifyWebhookOptions(name: None, avatar: None, channel_id: None)
}

/// Set webhook name
pub fn modify_webhook_name(
  opts: ModifyWebhookOptions,
  name: String,
) -> ModifyWebhookOptions {
  ModifyWebhookOptions(..opts, name: Some(name))
}

/// Set webhook avatar (base64 data URI)
pub fn modify_webhook_avatar(
  opts: ModifyWebhookOptions,
  avatar: String,
) -> ModifyWebhookOptions {
  ModifyWebhookOptions(..opts, avatar: Some(avatar))
}

/// Set webhook channel
pub fn modify_webhook_channel(
  opts: ModifyWebhookOptions,
  channel_id: Snowflake,
) -> ModifyWebhookOptions {
  ModifyWebhookOptions(..opts, channel_id: Some(channel_id))
}

// ============================================================================
// Public API - Execute Webhook Options Builder
// ============================================================================

/// Create new execute webhook options
pub fn new_execute_webhook_options() -> ExecuteWebhookOptions {
  ExecuteWebhookOptions(
    content: None,
    username: None,
    avatar_url: None,
    tts: None,
    embeds: [],
    allowed_mentions: None,
    thread_id: None,
    wait: None,
  )
}

/// Set message content
pub fn with_content(
  opts: ExecuteWebhookOptions,
  content: String,
) -> ExecuteWebhookOptions {
  ExecuteWebhookOptions(..opts, content: Some(content))
}

/// Set custom username for this message
pub fn with_username(
  opts: ExecuteWebhookOptions,
  username: String,
) -> ExecuteWebhookOptions {
  ExecuteWebhookOptions(..opts, username: Some(username))
}

/// Set custom avatar URL for this message
pub fn with_avatar_url(
  opts: ExecuteWebhookOptions,
  avatar_url: String,
) -> ExecuteWebhookOptions {
  ExecuteWebhookOptions(..opts, avatar_url: Some(avatar_url))
}

/// Set TTS flag
pub fn with_tts(opts: ExecuteWebhookOptions, tts: Bool) -> ExecuteWebhookOptions {
  ExecuteWebhookOptions(..opts, tts: Some(tts))
}

/// Add embed to message
pub fn with_embed(
  opts: ExecuteWebhookOptions,
  embed: WebhookEmbed,
) -> ExecuteWebhookOptions {
  ExecuteWebhookOptions(..opts, embeds: [embed, ..opts.embeds])
}

/// Add embeds to message
pub fn with_embeds(
  opts: ExecuteWebhookOptions,
  embeds: List(WebhookEmbed),
) -> ExecuteWebhookOptions {
  ExecuteWebhookOptions(..opts, embeds: list.append(opts.embeds, embeds))
}

/// Set allowed mentions
pub fn with_allowed_mentions(
  opts: ExecuteWebhookOptions,
  mentions: AllowedMentions,
) -> ExecuteWebhookOptions {
  ExecuteWebhookOptions(..opts, allowed_mentions: Some(mentions))
}

/// Set thread ID to post in a thread
pub fn with_thread_id(
  opts: ExecuteWebhookOptions,
  thread_id: Snowflake,
) -> ExecuteWebhookOptions {
  ExecuteWebhookOptions(..opts, thread_id: Some(thread_id))
}

/// Set wait flag (return message after sending)
pub fn with_wait(
  opts: ExecuteWebhookOptions,
  wait: Bool,
) -> ExecuteWebhookOptions {
  ExecuteWebhookOptions(..opts, wait: Some(wait))
}

// ============================================================================
// Public API - Embed Builder
// ============================================================================

/// Create new webhook embed
pub fn new_embed() -> WebhookEmbed {
  WebhookEmbed(
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
pub fn embed_title(embed: WebhookEmbed, title: String) -> WebhookEmbed {
  WebhookEmbed(..embed, title: Some(title))
}

/// Set embed description
pub fn embed_description(
  embed: WebhookEmbed,
  description: String,
) -> WebhookEmbed {
  WebhookEmbed(..embed, description: Some(description))
}

/// Set embed URL
pub fn embed_url(embed: WebhookEmbed, url: String) -> WebhookEmbed {
  WebhookEmbed(..embed, url: Some(url))
}

/// Set embed timestamp (ISO8601 format)
pub fn embed_timestamp(embed: WebhookEmbed, timestamp: String) -> WebhookEmbed {
  WebhookEmbed(..embed, timestamp: Some(timestamp))
}

/// Set embed color (integer color value)
pub fn embed_color(embed: WebhookEmbed, color: Int) -> WebhookEmbed {
  WebhookEmbed(..embed, color: Some(color))
}

/// Set embed footer
pub fn embed_footer(
  embed: WebhookEmbed,
  footer: WebhookEmbedFooter,
) -> WebhookEmbed {
  WebhookEmbed(..embed, footer: Some(footer))
}

/// Set embed image
pub fn embed_image(
  embed: WebhookEmbed,
  image: WebhookEmbedImage,
) -> WebhookEmbed {
  WebhookEmbed(..embed, image: Some(image))
}

/// Set embed thumbnail
pub fn embed_thumbnail(
  embed: WebhookEmbed,
  thumbnail: WebhookEmbedThumbnail,
) -> WebhookEmbed {
  WebhookEmbed(..embed, thumbnail: Some(thumbnail))
}

/// Set embed author
pub fn embed_author(
  embed: WebhookEmbed,
  author: WebhookEmbedAuthor,
) -> WebhookEmbed {
  WebhookEmbed(..embed, author: Some(author))
}

/// Add embed field
pub fn embed_field(
  embed: WebhookEmbed,
  field: WebhookEmbedField,
) -> WebhookEmbed {
  WebhookEmbed(..embed, fields: [field, ..embed.fields])
}

/// Add embed fields
pub fn embed_fields(
  embed: WebhookEmbed,
  fields: List(WebhookEmbedField),
) -> WebhookEmbed {
  WebhookEmbed(..embed, fields: list.append(embed.fields, fields))
}

// ============================================================================
// Public API - Embed Component Builders
// ============================================================================

/// Create embed footer
pub fn new_footer(text: String) -> WebhookEmbedFooter {
  WebhookEmbedFooter(text: text, icon_url: None)
}

/// Set footer icon URL
pub fn footer_icon_url(
  footer: WebhookEmbedFooter,
  url: String,
) -> WebhookEmbedFooter {
  WebhookEmbedFooter(..footer, icon_url: Some(url))
}

/// Create embed image
pub fn new_image(url: String) -> WebhookEmbedImage {
  WebhookEmbedImage(url: url)
}

/// Create embed thumbnail
pub fn new_thumbnail(url: String) -> WebhookEmbedThumbnail {
  WebhookEmbedThumbnail(url: url)
}

/// Create embed author
pub fn new_author(name: String) -> WebhookEmbedAuthor {
  WebhookEmbedAuthor(name: name, url: None, icon_url: None)
}

/// Set author URL
pub fn author_url(author: WebhookEmbedAuthor, url: String) -> WebhookEmbedAuthor {
  WebhookEmbedAuthor(..author, url: Some(url))
}

/// Set author icon URL
pub fn author_icon_url(
  author: WebhookEmbedAuthor,
  url: String,
) -> WebhookEmbedAuthor {
  WebhookEmbedAuthor(..author, icon_url: Some(url))
}

/// Create embed field
pub fn new_field(name: String, value: String) -> WebhookEmbedField {
  WebhookEmbedField(name: name, value: value, inline: None)
}

/// Set field inline
pub fn field_inline(field: WebhookEmbedField, inline: Bool) -> WebhookEmbedField {
  WebhookEmbedField(..field, inline: Some(inline))
}

// ============================================================================
// Public API - Edit Message Options Builder
// ============================================================================

/// Create new edit webhook message options
pub fn new_edit_webhook_message_options() -> EditWebhookMessageOptions {
  EditWebhookMessageOptions(content: None, embeds: [], allowed_mentions: None)
}

/// Set edit message content
pub fn edit_with_content(
  opts: EditWebhookMessageOptions,
  content: String,
) -> EditWebhookMessageOptions {
  EditWebhookMessageOptions(..opts, content: Some(content))
}

/// Add embed to edit message
pub fn edit_with_embed(
  opts: EditWebhookMessageOptions,
  embed: WebhookEmbed,
) -> EditWebhookMessageOptions {
  EditWebhookMessageOptions(..opts, embeds: [embed, ..opts.embeds])
}

/// Set allowed mentions for edit
pub fn edit_with_allowed_mentions(
  opts: EditWebhookMessageOptions,
  mentions: AllowedMentions,
) -> EditWebhookMessageOptions {
  EditWebhookMessageOptions(..opts, allowed_mentions: Some(mentions))
}

// ============================================================================
// Public API - Allowed Mentions Builder
// ============================================================================

/// Create new allowed mentions
pub fn new_allowed_mentions() -> AllowedMentions {
  AllowedMentions(parse: [], users: [], roles: [], replied_user: None)
}

/// Add parse type (e.g., "users", "roles", "everyone")
pub fn allow_parse(mentions: AllowedMentions, parse: String) -> AllowedMentions {
  AllowedMentions(..mentions, parse: [parse, ..mentions.parse])
}

/// Add user ID to allow
pub fn allow_user(
  mentions: AllowedMentions,
  user_id: Snowflake,
) -> AllowedMentions {
  AllowedMentions(..mentions, users: [user_id, ..mentions.users])
}

/// Add role ID to allow
pub fn allow_role(
  mentions: AllowedMentions,
  role_id: Snowflake,
) -> AllowedMentions {
  AllowedMentions(..mentions, roles: [role_id, ..mentions.roles])
}

/// Set replied user mention
pub fn allow_replied_user(
  mentions: AllowedMentions,
  allow: Bool,
) -> AllowedMentions {
  AllowedMentions(..mentions, replied_user: Some(allow))
}

// ============================================================================
// Actor Message Handler
// ============================================================================

fn handle_message(
  state: WebhookClientState,
  message: WebhookClientMessage,
) -> actor.Next(WebhookClientState, WebhookClientMessage) {
  case message {
    CreateWebhook(reply_to, channel_id, options) -> {
      let result = do_create_webhook(state, channel_id, options)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetWebhook(reply_to, webhook_id) -> {
      let result = do_get_webhook(state, webhook_id)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetWebhookWithToken(reply_to, webhook_id, token) -> {
      let result = do_get_webhook_with_token(state, webhook_id, token)
      process.send(reply_to, result)
      actor.continue(state)
    }

    ModifyWebhook(reply_to, webhook_id, options) -> {
      let result = do_modify_webhook(state, webhook_id, options)
      process.send(reply_to, result)
      actor.continue(state)
    }

    ModifyWebhookWithToken(reply_to, webhook_id, token, options) -> {
      let result =
        do_modify_webhook_with_token(state, webhook_id, token, options)
      process.send(reply_to, result)
      actor.continue(state)
    }

    DeleteWebhook(reply_to, webhook_id) -> {
      let result = do_delete_webhook(state, webhook_id)
      process.send(reply_to, result)
      actor.continue(state)
    }

    DeleteWebhookWithToken(reply_to, webhook_id, token) -> {
      let result = do_delete_webhook_with_token(state, webhook_id, token)
      process.send(reply_to, result)
      actor.continue(state)
    }

    ExecuteWebhook(reply_to, webhook_id, token, options) -> {
      let result = do_execute_webhook(state, webhook_id, token, options)
      process.send(reply_to, result)
      actor.continue(state)
    }

    EditWebhookMessage(reply_to, webhook_id, token, message_id, options) -> {
      let result =
        do_edit_webhook_message(state, webhook_id, token, message_id, options)
      process.send(reply_to, result)
      actor.continue(state)
    }

    DeleteWebhookMessage(reply_to, webhook_id, token, message_id) -> {
      let result =
        do_delete_webhook_message(state, webhook_id, token, message_id)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetChannelWebhooks(reply_to, channel_id) -> {
      let result = do_get_channel_webhooks(state, channel_id)
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetGuildWebhooks(reply_to, guild_id) -> {
      let result = do_get_guild_webhooks(state, guild_id)
      process.send(reply_to, result)
      actor.continue(state)
    }
  }
}

// ============================================================================
// Internal - Webhook CRUD Operations
// ============================================================================

fn do_create_webhook(
  state: WebhookClientState,
  channel_id: Snowflake,
  options: CreateWebhookOptions,
) -> Result(Webhook, WebhookError) {
  let url =
    get_base_url(state.config) <> "/channels/" <> channel_id <> "/webhooks"
  let body = encode_create_webhook_options(options)

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.prepend_header("Authorization", "Bot " <> state.config.bot_token)
    |> request.prepend_header("Content-Type", "application/json")
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_body = request.set_body(req, body)
  let req_with_url = request.set_host(req_with_body, url)

  execute_request(req_with_url)
  |> result.try(parse_webhook_response)
}

fn do_get_webhook(
  state: WebhookClientState,
  webhook_id: Snowflake,
) -> Result(Webhook, WebhookError) {
  let url = get_base_url(state.config) <> "/webhooks/" <> webhook_id

  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.prepend_header("Authorization", "Bot " <> state.config.bot_token)
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_url = request.set_host(req, url)

  execute_request(req_with_url)
  |> result.try(parse_webhook_response)
}

fn do_get_webhook_with_token(
  state: WebhookClientState,
  webhook_id: Snowflake,
  token: String,
) -> Result(Webhook, WebhookError) {
  let url =
    get_base_url(state.config) <> "/webhooks/" <> webhook_id <> "/" <> token

  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_url = request.set_host(req, url)

  execute_request(req_with_url)
  |> result.try(parse_webhook_response)
}

fn do_modify_webhook(
  state: WebhookClientState,
  webhook_id: Snowflake,
  options: ModifyWebhookOptions,
) -> Result(Webhook, WebhookError) {
  let url = get_base_url(state.config) <> "/webhooks/" <> webhook_id
  let body = encode_modify_webhook_options(options)

  let req =
    request.new()
    |> request.set_method(http.Patch)
    |> request.prepend_header("Authorization", "Bot " <> state.config.bot_token)
    |> request.prepend_header("Content-Type", "application/json")
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_body = request.set_body(req, body)
  let req_with_url = request.set_host(req_with_body, url)

  execute_request(req_with_url)
  |> result.try(parse_webhook_response)
}

fn do_modify_webhook_with_token(
  state: WebhookClientState,
  webhook_id: Snowflake,
  token: String,
  options: ModifyWebhookOptions,
) -> Result(Webhook, WebhookError) {
  let url =
    get_base_url(state.config) <> "/webhooks/" <> webhook_id <> "/" <> token
  let body = encode_modify_webhook_options(options)

  let req =
    request.new()
    |> request.set_method(http.Patch)
    |> request.prepend_header("Content-Type", "application/json")
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_body = request.set_body(req, body)
  let req_with_url = request.set_host(req_with_body, url)

  execute_request(req_with_url)
  |> result.try(parse_webhook_response)
}

fn do_delete_webhook(
  state: WebhookClientState,
  webhook_id: Snowflake,
) -> Result(Nil, WebhookError) {
  let url = get_base_url(state.config) <> "/webhooks/" <> webhook_id

  let req =
    request.new()
    |> request.set_method(http.Delete)
    |> request.prepend_header("Authorization", "Bot " <> state.config.bot_token)
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_url = request.set_host(req, url)

  execute_request(req_with_url)
  |> result.map(fn(_) { Nil })
}

fn do_delete_webhook_with_token(
  state: WebhookClientState,
  webhook_id: Snowflake,
  token: String,
) -> Result(Nil, WebhookError) {
  let url =
    get_base_url(state.config) <> "/webhooks/" <> webhook_id <> "/" <> token

  let req =
    request.new()
    |> request.set_method(http.Delete)
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_url = request.set_host(req, url)

  execute_request(req_with_url)
  |> result.map(fn(_) { Nil })
}

fn do_get_channel_webhooks(
  state: WebhookClientState,
  channel_id: Snowflake,
) -> Result(List(Webhook), WebhookError) {
  let url =
    get_base_url(state.config) <> "/channels/" <> channel_id <> "/webhooks"

  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.prepend_header("Authorization", "Bot " <> state.config.bot_token)
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_url = request.set_host(req, url)

  execute_request(req_with_url)
  |> result.try(parse_webhook_list_response)
}

fn do_get_guild_webhooks(
  state: WebhookClientState,
  guild_id: Snowflake,
) -> Result(List(Webhook), WebhookError) {
  let url = get_base_url(state.config) <> "/guilds/" <> guild_id <> "/webhooks"

  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.prepend_header("Authorization", "Bot " <> state.config.bot_token)
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_url = request.set_host(req, url)

  execute_request(req_with_url)
  |> result.try(parse_webhook_list_response)
}

// ============================================================================
// Internal - Webhook Execution Operations
// ============================================================================

fn do_execute_webhook(
  state: WebhookClientState,
  webhook_id: Snowflake,
  token: String,
  options: ExecuteWebhookOptions,
) -> Result(Option(WebhookMessage), WebhookError) {
  // Validate options
  case options.content, options.embeds {
    None, [] -> Error(BadRequest("Message must have content or embeds"))
    _, _ -> {
      let base_url =
        get_base_url(state.config) <> "/webhooks/" <> webhook_id <> "/" <> token

      // Add query parameters
      let url = case options.wait, options.thread_id {
        Some(True), Some(thread_id) ->
          base_url <> "?wait=true&thread_id=" <> thread_id
        Some(True), None -> base_url <> "?wait=true"
        Some(False), Some(thread_id) -> base_url <> "?thread_id=" <> thread_id
        Some(False), None -> base_url
        None, Some(thread_id) -> base_url <> "?thread_id=" <> thread_id
        None, None -> base_url
      }

      let body = encode_execute_webhook_options(options)

      let req =
        request.new()
        |> request.set_method(http.Post)
        |> request.prepend_header("Content-Type", "application/json")
        |> request.prepend_header(
          "User-Agent",
          "SupernovaBot (https://supernova.bot, v1.0)",
        )

      let req_with_body = request.set_body(req, body)
      let req_with_url = request.set_host(req_with_body, url)

      case options.wait {
        Some(True) -> {
          execute_request(req_with_url)
          |> result.try(parse_webhook_message_response)
          |> result.map(fn(msg) { Some(msg) })
        }
        Some(False) -> {
          execute_request_no_response(req_with_url)
          |> result.map(fn(_) { None })
        }
        None -> {
          execute_request_no_response(req_with_url)
          |> result.map(fn(_) { None })
        }
      }
    }
  }
}

fn do_edit_webhook_message(
  state: WebhookClientState,
  webhook_id: Snowflake,
  token: String,
  message_id: Snowflake,
  options: EditWebhookMessageOptions,
) -> Result(WebhookMessage, WebhookError) {
  let url =
    get_base_url(state.config)
    <> "/webhooks/"
    <> webhook_id
    <> "/"
    <> token
    <> "/messages/"
    <> message_id

  let body = encode_edit_webhook_message_options(options)

  let req =
    request.new()
    |> request.set_method(http.Patch)
    |> request.prepend_header("Content-Type", "application/json")
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_body = request.set_body(req, body)
  let req_with_url = request.set_host(req_with_body, url)

  execute_request(req_with_url)
  |> result.try(parse_webhook_message_response)
}

fn do_delete_webhook_message(
  state: WebhookClientState,
  webhook_id: Snowflake,
  token: String,
  message_id: Snowflake,
) -> Result(Nil, WebhookError) {
  let url =
    get_base_url(state.config)
    <> "/webhooks/"
    <> webhook_id
    <> "/"
    <> token
    <> "/messages/"
    <> message_id

  let req =
    request.new()
    |> request.set_method(http.Delete)
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_url = request.set_host(req, url)

  execute_request(req_with_url)
  |> result.map(fn(_) { Nil })
}

// ============================================================================
// Internal - HTTP Request Execution
// ============================================================================

fn execute_request(
  req: Request(String),
) -> Result(Response(String), WebhookError) {
  case hackney.send(req) {
    Ok(resp) -> {
      case resp.status {
        200 -> Ok(resp)
        201 -> Ok(resp)
        204 -> Ok(resp)
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
    Error(hackney.InvalidUtf8Response) -> {
      Error(HttpError("Invalid UTF-8 response"))
    }
    Error(hackney.Other(reason)) -> {
      Error(HttpError("HTTP error: " <> string.inspect(reason)))
    }
  }
}

fn execute_request_no_response(
  req: Request(String),
) -> Result(Nil, WebhookError) {
  case hackney.send(req) {
    Ok(resp) -> {
      case resp.status {
        200 | 201 | 204 | 300 -> Ok(Nil)
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

fn parse_webhook_response(
  resp: Response(String),
) -> Result(Webhook, WebhookError) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use type_int <- decode.field("type", decode.int)
    use guild_id <- decode.field("guild_id", decode.optional(decode.string))
    use channel_id <- decode.field("channel_id", decode.optional(decode.string))
    use name <- decode.field("name", decode.optional(decode.string))
    use avatar <- decode.field("avatar", decode.optional(decode.string))
    use token <- decode.field("token", decode.optional(decode.string))
    use application_id <- decode.field(
      "application_id",
      decode.optional(decode.string),
    )
    decode.success(Webhook(
      id: id,
      webhook_type: int_to_webhook_type(type_int),
      guild_id: guild_id,
      channel_id: channel_id,
      name: name,
      avatar: avatar,
      token: token,
      application_id: application_id,
    ))
  }

  case json.parse(from: resp.body, using: decoder) {
    Ok(webhook) -> Ok(webhook)
    Error(_) -> Error(JsonError("Failed to parse webhook response"))
  }
}

fn parse_webhook_list_response(
  resp: Response(String),
) -> Result(List(Webhook), WebhookError) {
  let webhook_decoder = {
    use id <- decode.field("id", decode.string)
    use type_int <- decode.field("type", decode.int)
    use guild_id <- decode.field("guild_id", decode.optional(decode.string))
    use channel_id <- decode.field("channel_id", decode.optional(decode.string))
    use name <- decode.field("name", decode.optional(decode.string))
    use avatar <- decode.field("avatar", decode.optional(decode.string))
    use token <- decode.field("token", decode.optional(decode.string))
    use application_id <- decode.field(
      "application_id",
      decode.optional(decode.string),
    )
    decode.success(Webhook(
      id: id,
      webhook_type: int_to_webhook_type(type_int),
      guild_id: guild_id,
      channel_id: channel_id,
      name: name,
      avatar: avatar,
      token: token,
      application_id: application_id,
    ))
  }

  let list_decoder = decode.list(webhook_decoder)

  case json.parse(from: resp.body, using: list_decoder) {
    Ok(webhooks) -> Ok(webhooks)
    Error(_) -> Error(JsonError("Failed to parse webhook list response"))
  }
}

fn parse_webhook_message_response(
  resp: Response(String),
) -> Result(WebhookMessage, WebhookError) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use channel_id <- decode.field("channel_id", decode.string)
    use content <- decode.field("content", decode.string)
    use timestamp <- decode.field("timestamp", decode.optional(decode.string))
    decode.success(WebhookMessage(
      id: id,
      channel_id: channel_id,
      content: content,
      timestamp: option.unwrap(timestamp, ""),
    ))
  }

  case json.parse(from: resp.body, using: decoder) {
    Ok(msg) -> Ok(msg)
    Error(_) -> Error(JsonError("Failed to parse webhook message response"))
  }
}

fn int_to_webhook_type(type_int: Int) -> WebhookType {
  case type_int {
    1 -> Incoming
    2 -> ChannelFollower
    3 -> Application
    _ -> Incoming
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

fn encode_create_webhook_options(opts: CreateWebhookOptions) -> String {
  let fields =
    [json_key_value("name", json_string(opts.name))]
    |> add_optional_string_field("avatar", opts.avatar)

  "{" <> string.join(fields, ",") <> "}"
}

fn encode_modify_webhook_options(opts: ModifyWebhookOptions) -> String {
  let fields =
    []
    |> add_optional_string_field("name", opts.name)
    |> add_optional_string_field("avatar", opts.avatar)
    |> add_optional_string_field("channel_id", opts.channel_id)

  "{" <> string.join(fields, ",") <> "}"
}

fn encode_execute_webhook_options(opts: ExecuteWebhookOptions) -> String {
  let fields =
    []
    |> add_optional_string_field("content", opts.content)
    |> add_optional_string_field("username", opts.username)
    |> add_optional_string_field("avatar_url", opts.avatar_url)
    |> add_optional_bool_field("tts", opts.tts)
    |> add_webhook_embeds_field("embeds", opts.embeds)
    |> add_allowed_mentions_field("allowed_mentions", opts.allowed_mentions)

  "{" <> string.join(fields, ",") <> "}"
}

fn encode_edit_webhook_message_options(
  opts: EditWebhookMessageOptions,
) -> String {
  let fields =
    []
    |> add_optional_string_field("content", opts.content)
    |> add_webhook_embeds_field("embeds", opts.embeds)
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

fn add_webhook_embeds_field(
  fields: List(String),
  name: String,
  embeds: List(WebhookEmbed),
) -> List(String) {
  case embeds {
    [] -> fields
    es -> {
      let encoded =
        "[" <> string.join(list.map(es, encode_webhook_embed), ",") <> "]"
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

fn encode_webhook_embed(embed: WebhookEmbed) -> String {
  let fields =
    []
    |> add_optional_string_field("title", embed.title)
    |> add_optional_string_field("description", embed.description)
    |> add_optional_string_field("url", embed.url)
    |> add_optional_string_field("timestamp", embed.timestamp)
    |> add_optional_int_field("color", embed.color)
    |> add_optional_webhook_footer_field("footer", embed.footer)
    |> add_optional_webhook_image_field("image", embed.image)
    |> add_optional_webhook_thumbnail_field("thumbnail", embed.thumbnail)
    |> add_optional_webhook_author_field("author", embed.author)
    |> add_webhook_embed_fields_field("fields", embed.fields)

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

fn add_optional_webhook_footer_field(
  fields: List(String),
  name: String,
  footer: Option(WebhookEmbedFooter),
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

fn add_optional_webhook_image_field(
  fields: List(String),
  name: String,
  image: Option(WebhookEmbedImage),
) -> List(String) {
  case image {
    None -> fields
    Some(img) -> {
      let encoded = "{\"url\":" <> json_string(img.url) <> "}"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn add_optional_webhook_thumbnail_field(
  fields: List(String),
  name: String,
  thumbnail: Option(WebhookEmbedThumbnail),
) -> List(String) {
  case thumbnail {
    None -> fields
    Some(thumb) -> {
      let encoded = "{\"url\":" <> json_string(thumb.url) <> "}"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn add_optional_webhook_author_field(
  fields: List(String),
  name: String,
  author: Option(WebhookEmbedAuthor),
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

fn add_webhook_embed_fields_field(
  fields: List(String),
  name: String,
  embed_fields: List(WebhookEmbedField),
) -> List(String) {
  case embed_fields {
    [] -> fields
    fs -> {
      let encoded =
        "[" <> string.join(list.map(fs, encode_webhook_embed_field), ",") <> "]"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn encode_webhook_embed_field(field: WebhookEmbedField) -> String {
  let fields =
    [
      json_key_value("name", json_string(field.name)),
      json_key_value("value", json_string(field.value)),
    ]
    |> add_optional_bool_field("inline", field.inline)

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

fn get_base_url(config: WebhookClientConfig) -> String {
  option.unwrap(config.base_url, api_base_url)
}
