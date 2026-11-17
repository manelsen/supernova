//// Discord Slash Commands Module
//// Provides:
//// - Command registration via REST API
//// - Handler for INTERACTION_CREATE events
//// - Response types: ephemeral, public
//// - Support for options (string, integer, boolean, user, channel)
////
//// This module works with discord_rest for API calls and discord_events for parsing.

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
// Types - Command Definition
// ============================================================================

/// Slash command type
pub type CommandType {
  /// Chat input command (slash command)
  ChatInputCommand
  /// User context menu command
  UserContextMenu
  /// Message context menu command
  MessageContextMenu
}

/// Command option type
pub type CommandOptionType {
  CmdSubCommand
  CmdSubCommandGroup
  CmdStringOption
  CmdIntegerOption
  CmdBooleanOption
  CmdUserOption
  CmdChannelOption
  CmdRoleOption
  CmdMentionableOption
  CmdNumberOption
  CmdAttachmentOption
}

/// Command option choice
pub type CommandOptionChoice {
  CommandOptionChoice(name: String, value: CommandOptionChoiceValue)
}

/// Command option choice value
pub type CommandOptionChoiceValue {
  StringChoiceValue(value: String)
  IntChoiceValue(value: Int)
  FloatChoiceValue(value: Float)
}

/// Channel type filter for channel options
pub type ChannelTypeFilter {
  GuildTextChannel
  DmChannel
  GuildVoiceChannel
  GroupDmChannel
  GuildCategoryChannel
  GuildAnnouncementChannel
  AnnouncementThreadChannel
  PublicThreadChannel
  PrivateThreadChannel
  GuildStageVoiceChannel
  GuildDirectoryChannel
  GuildForumChannel
  GuildMediaChannel
}

/// Command option definition
pub type CommandOption {
  CommandOption(
    /// Option type
    option_type: CommandOptionType,
    /// Option name (1-32 chars, lowercase)
    name: String,
    /// Option description (1-100 chars)
    description: String,
    /// Is this option required?
    required: Bool,
    /// Choices for string/integer/number types
    choices: List(CommandOptionChoice),
    /// Channel types to filter (for channel options)
    channel_types: List(ChannelTypeFilter),
    /// Min value for integer/number options
    min_value: Option(Float),
    /// Max value for integer/number options
    max_value: Option(Float),
    /// Min length for string options (0-6000)
    min_length: Option(Int),
    /// Max length for string options (1-6000)
    max_length: Option(Int),
    /// Autocomplete enabled
    autocomplete: Bool,
    /// Sub-options for subcommands/groups
    options: List(CommandOption),
  )
}

/// Application command definition
pub type SlashCommand {
  SlashCommand(
    /// Command name (1-32 chars, lowercase for ChatInput)
    name: String,
    /// Command description (1-100 chars, required for ChatInput)
    description: String,
    /// Command type
    command_type: CommandType,
    /// Command options
    options: List(CommandOption),
    /// Default permission (deprecated, use default_member_permissions)
    default_permission: Option(Bool),
    /// Default member permissions as bit flags
    default_member_permissions: Option(String),
    /// Enable in DMs
    dm_permission: Option(Bool),
    /// Localizations (name_localizations, description_localizations)
    name_localizations: Option(Dict(String, String)),
    description_localizations: Option(Dict(String, String)),
    /// NSFW command
    nsfw: Option(Bool),
  )
}

/// Registered command from Discord
pub type RegisteredCommand {
  RegisteredCommand(
    id: Snowflake,
    application_id: Snowflake,
    name: String,
    description: String,
    command_type: CommandType,
    version: String,
    options: List(CommandOption),
    guild_id: Option(Snowflake),
  )
}

// ============================================================================
// Types - Interaction Response
// ============================================================================

/// Response type for interaction
pub type InteractionResponseType {
  /// ACK a Ping
  PongResponse
  /// Respond with a message (for ApplicationCommand, MessageComponent, ModalSubmit)
  ChannelMessageWithSource
  /// ACK and show a loading state (deferred)
  DeferredChannelMessageWithSource
  /// ACK and edit the message later (for MessageComponent)
  DeferredUpdateMessage
  /// Edit the message (for MessageComponent)
  UpdateMessage
  /// Response to autocomplete
  AutocompleteResult
  /// Modal response
  ModalResponse
}

/// Interaction callback data
pub type InteractionCallbackData {
  InteractionCallbackData(
    /// Message content
    content: Option(String),
    /// Is this response ephemeral? (only visible to user)
    ephemeral: Bool,
    /// Message embeds
    embeds: List(ResponseEmbed),
    /// Allowed mentions
    allowed_mentions: Option(AllowedMentions),
    /// Message flags (can override ephemeral)
    flags: Option(Int),
    /// Message components (buttons, select menus)
    components: List(ResponseActionRow),
    /// Attachments
    attachments: List(ResponseAttachment),
    /// Is TTS?
    tts: Option(Bool),
    /// Custom ID for modal responses
    custom_id: Option(String),
    /// Title for modal responses
    title: Option(String),
    /// Choices for autocomplete responses
    choices: List(CommandOptionChoice),
  )
}

/// Interaction response
pub type InteractionResponse {
  InteractionResponse(
    response_type: InteractionResponseType,
    data: Option(InteractionCallbackData),
  )
}

// ============================================================================
// Types - Message Components (for responses)
// ============================================================================

/// Message Embed for responses
pub type ResponseEmbed {
  ResponseEmbed(
    title: Option(String),
    description: Option(String),
    url: Option(String),
    timestamp: Option(String),
    color: Option(Int),
    footer: Option(ResponseEmbedFooter),
    image: Option(ResponseEmbedImage),
    thumbnail: Option(ResponseEmbedThumbnail),
    author: Option(ResponseEmbedAuthor),
    fields: List(ResponseEmbedField),
  )
}

/// Embed Footer
pub type ResponseEmbedFooter {
  ResponseEmbedFooter(text: String, icon_url: Option(String))
}

/// Embed Image
pub type ResponseEmbedImage {
  ResponseEmbedImage(url: String)
}

/// Embed Thumbnail
pub type ResponseEmbedThumbnail {
  ResponseEmbedThumbnail(url: String)
}

/// Embed Author
pub type ResponseEmbedAuthor {
  ResponseEmbedAuthor(
    name: String,
    url: Option(String),
    icon_url: Option(String),
  )
}

/// Embed Field
pub type ResponseEmbedField {
  ResponseEmbedField(name: String, value: String, inline: Option(Bool))
}

/// Message Attachment
pub type ResponseAttachment {
  ResponseAttachment(id: String, filename: String, description: Option(String))
}

/// Allowed Mentions
pub type AllowedMentions {
  AllowedMentions(
    parse: List(String),
    users: List(Snowflake),
    roles: List(Snowflake),
    replied_user: Option(Bool),
  )
}

/// Action Row (container for components)
pub type ResponseActionRow {
  ResponseActionRow(components: List(ResponseComponent))
}

/// Message Component
pub type ResponseComponent {
  ResponseButton(
    style: ResponseButtonStyle,
    label: Option(String),
    emoji: Option(ResponseEmoji),
    custom_id: Option(String),
    url: Option(String),
    disabled: Option(Bool),
  )
  ResponseStringSelect(
    custom_id: String,
    options: List(ResponseSelectOption),
    placeholder: Option(String),
    min_values: Option(Int),
    max_values: Option(Int),
    disabled: Option(Bool),
  )
  ResponseUserSelect(
    custom_id: String,
    placeholder: Option(String),
    min_values: Option(Int),
    max_values: Option(Int),
    disabled: Option(Bool),
  )
  ResponseRoleSelect(
    custom_id: String,
    placeholder: Option(String),
    min_values: Option(Int),
    max_values: Option(Int),
    disabled: Option(Bool),
  )
  ResponseChannelSelect(
    custom_id: String,
    channel_types: List(ChannelTypeFilter),
    placeholder: Option(String),
    min_values: Option(Int),
    max_values: Option(Int),
    disabled: Option(Bool),
  )
  ResponseTextInput(
    custom_id: String,
    label: String,
    style: TextInputStyle,
    placeholder: Option(String),
    value: Option(String),
    required: Option(Bool),
    min_length: Option(Int),
    max_length: Option(Int),
  )
}

/// Button Style
pub type ResponseButtonStyle {
  PrimaryButton
  SecondaryButton
  SuccessButton
  DangerButton
  LinkButton
}

/// Text Input Style for Modal fields
pub type TextInputStyle {
  /// Short text input (single line)
  ShortInput
  /// Paragraph text input (multi-line)
  ParagraphInput
}

/// Select Option
pub type ResponseSelectOption {
  ResponseSelectOption(
    label: String,
    value: String,
    description: Option(String),
    emoji: Option(ResponseEmoji),
    default: Option(Bool),
  )
}

/// Emoji
pub type ResponseEmoji {
  ResponseEmoji(
    id: Option(Snowflake),
    name: Option(String),
    animated: Option(Bool),
  )
}

// ============================================================================
// Types - Command Handler
// ============================================================================

/// Command handler function type
pub type CommandHandler =
  fn(InteractionPayload, InteractionPayloadData) -> InteractionResponse

/// Registered command handler entry
pub type CommandHandlerEntry {
  CommandHandlerEntry(
    command_name: String,
    handler: CommandHandler,
    guild_id: Option(Snowflake),
  )
}

// ============================================================================
// Types - Commands Actor
// ============================================================================

/// Commands actor state
pub type CommandsState {
  CommandsState(
    config: CommandsConfig,
    handlers: Dict(String, CommandHandlerEntry),
  )
}

/// Commands configuration
pub type CommandsConfig {
  CommandsConfig(
    bot_token: String,
    application_id: Snowflake,
    base_url: Option(String),
    timeout_ms: Int,
  )
}

/// Commands actor messages
pub type CommandsMessage {
  /// Register a global command
  RegisterGlobalCommand(
    reply_to: Subject(Result(RegisteredCommand, CommandsError)),
    command: SlashCommand,
  )
  /// Register a guild command
  RegisterGuildCommand(
    reply_to: Subject(Result(RegisteredCommand, CommandsError)),
    command: SlashCommand,
    guild_id: Snowflake,
  )
  /// Get registered commands
  GetGlobalCommands(
    reply_to: Subject(Result(List(RegisteredCommand), CommandsError)),
  )
  /// Delete a command
  DeleteCommand(
    reply_to: Subject(Result(Nil, CommandsError)),
    command_id: Snowflake,
    guild_id: Option(Snowflake),
  )
  /// Register a handler for a command
  RegisterHandler(
    reply_to: Subject(Nil),
    command_name: String,
    handler: CommandHandler,
    guild_id: Option(Snowflake),
  )
  /// Handle an interaction (dispatch to handler)
  HandleInteraction(
    reply_to: Subject(Option(InteractionResponse)),
    interaction: InteractionPayload,
  )
  /// Get handler count
  GetHandlerCount(reply_to: Subject(Int))
  /// Clear all handlers
  ClearHandlers(reply_to: Subject(Nil))
}

/// Commands client handle
pub type CommandsClient =
  Subject(CommandsMessage)

// ============================================================================
// Types - Errors
// ============================================================================

/// Commands module error
pub type CommandsError {
  /// HTTP request failed
  CommandsHttpError(message: String)
  /// Rate limited
  CommandsRateLimited(retry_after_ms: Int)
  /// Bad request
  CommandsBadRequest(message: String)
  /// Unauthorized
  CommandsUnauthorized
  /// Forbidden
  CommandsForbidden(message: String)
  /// Not found
  CommandsNotFound(message: String)
  /// Internal error
  CommandsInternalError(message: String)
  /// Unknown error
  CommandsUnknownError(status: Int, body: String)
  /// JSON error
  CommandsJsonError(message: String)
  /// Actor start error
  CommandsStartError(message: String)
  /// No handler registered
  NoHandlerRegistered(command_name: String)
}

// ============================================================================
// Types - Interaction Payload (for handler dispatch)
// ============================================================================

/// Interaction payload for handler dispatch
pub type InteractionPayload {
  InteractionPayload(
    id: Snowflake,
    application_id: Snowflake,
    interaction_type: InteractionPayloadType,
    data: Option(InteractionPayloadData),
    guild_id: Option(Snowflake),
    channel_id: Option(Snowflake),
    member: Option(MemberPayload),
    user: Option(UserPayload),
    token: String,
    version: Int,
  )
}

/// Interaction Type
pub type InteractionPayloadType {
  PingInteraction
  ApplicationCommandInteraction
  MessageComponentInteraction
  AutocompleteInteraction
  ModalSubmitInteraction
  UnknownInteraction(code: Int)
}

/// Interaction data
pub type InteractionPayloadData {
  CommandPayload(
    id: Snowflake,
    name: String,
    options: List(CommandOptionPayload),
    target_id: Option(Snowflake),
  )
  ComponentPayload(custom_id: String, values: Option(List(String)))
  ModalPayload(custom_id: String, components: List(ResponseActionRow))
}

/// Command option from interaction
pub type CommandOptionPayload {
  CommandOptionPayload(
    name: String,
    value: Option(OptionValue),
    options: List(CommandOptionPayload),
  )
}

/// Option value
pub type OptionValue {
  StringVal(value: String)
  IntVal(value: Int)
  BoolVal(value: Bool)
  UserVal(value: Snowflake)
  ChannelVal(value: Snowflake)
  RoleVal(value: Snowflake)
}

/// User payload
pub type UserPayload {
  UserPayload(
    id: Snowflake,
    username: String,
    discriminator: String,
    bot: Option(Bool),
    avatar: Option(String),
  )
}

/// Member payload
pub type MemberPayload {
  MemberPayload(
    user: Option(UserPayload),
    nick: Option(String),
    roles: List(Snowflake),
  )
}

// ============================================================================
// Public API - Configuration
// ============================================================================

/// Create new commands configuration
pub fn new_config(
  bot_token: String,
  application_id: Snowflake,
) -> CommandsConfig {
  CommandsConfig(
    bot_token: bot_token,
    application_id: application_id,
    base_url: None,
    timeout_ms: 30_000,
  )
}

/// Set custom base URL
pub fn with_base_url(config: CommandsConfig, url: String) -> CommandsConfig {
  CommandsConfig(..config, base_url: Some(url))
}

/// Set timeout
pub fn with_timeout(config: CommandsConfig, timeout_ms: Int) -> CommandsConfig {
  CommandsConfig(..config, timeout_ms: timeout_ms)
}

// ============================================================================
// Public API - Client Lifecycle
// ============================================================================

/// Start a new commands client
pub fn start(config: CommandsConfig) -> Result(CommandsClient, CommandsError) {
  let initial_state = CommandsState(config: config, handlers: dict.new())

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(CommandsStartError(string.inspect(error)))
  }
}

// ============================================================================
// Public API - Command Registration
// ============================================================================

/// Register a global command
pub fn register_global_command(
  client: CommandsClient,
  command: SlashCommand,
) -> Result(RegisteredCommand, CommandsError) {
  actor.call(client, waiting: 60_000, sending: RegisterGlobalCommand(_, command))
}

/// Register a guild command
pub fn register_guild_command(
  client: CommandsClient,
  command: SlashCommand,
  guild_id: Snowflake,
) -> Result(RegisteredCommand, CommandsError) {
  actor.call(client, waiting: 60_000, sending: RegisterGuildCommand(
    _,
    command,
    guild_id,
  ))
}

/// Get all registered global commands
pub fn get_global_commands(
  client: CommandsClient,
) -> Result(List(RegisteredCommand), CommandsError) {
  actor.call(client, waiting: 60_000, sending: GetGlobalCommands)
}

/// Delete a command
pub fn delete_command(
  client: CommandsClient,
  command_id: Snowflake,
  guild_id: Option(Snowflake),
) -> Result(Nil, CommandsError) {
  actor.call(client, waiting: 60_000, sending: DeleteCommand(
    _,
    command_id,
    guild_id,
  ))
}

// ============================================================================
// Public API - Handler Registration
// ============================================================================

/// Register a handler for a command
pub fn register_handler(
  client: CommandsClient,
  command_name: String,
  handler: CommandHandler,
) -> Nil {
  actor.call(client, waiting: 5000, sending: RegisterHandler(
    _,
    command_name,
    handler,
    None,
  ))
}

/// Register a handler for a guild-specific command
pub fn register_guild_handler(
  client: CommandsClient,
  command_name: String,
  handler: CommandHandler,
  guild_id: Snowflake,
) -> Nil {
  actor.call(client, waiting: 5000, sending: RegisterHandler(
    _,
    command_name,
    handler,
    Some(guild_id),
  ))
}

/// Handle an interaction (dispatches to registered handler)
pub fn handle_interaction(
  client: CommandsClient,
  interaction: InteractionPayload,
) -> Option(InteractionResponse) {
  actor.call(client, waiting: 5000, sending: HandleInteraction(_, interaction))
}

/// Get handler count
pub fn handler_count(client: CommandsClient) -> Int {
  actor.call(client, waiting: 5000, sending: GetHandlerCount)
}

/// Clear all handlers
pub fn clear_handlers(client: CommandsClient) -> Nil {
  actor.call(client, waiting: 5000, sending: ClearHandlers)
}

// ============================================================================
// Public API - Response Builders
// ============================================================================

/// Create a simple message response
pub fn message_response(content: String) -> InteractionResponse {
  InteractionResponse(
    response_type: ChannelMessageWithSource,
    data: Some(
      InteractionCallbackData(
        content: Some(content),
        ephemeral: False,
        embeds: [],
        allowed_mentions: None,
        flags: None,
        components: [],
        attachments: [],
        tts: None,
        custom_id: None,
        title: None,
        choices: [],
      ),
    ),
  )
}

/// Create an ephemeral message response (only visible to user)
pub fn ephemeral_response(content: String) -> InteractionResponse {
  InteractionResponse(
    response_type: ChannelMessageWithSource,
    data: Some(
      InteractionCallbackData(
        content: Some(content),
        ephemeral: True,
        embeds: [],
        allowed_mentions: None,
        flags: None,
        components: [],
        attachments: [],
        tts: None,
        custom_id: None,
        title: None,
        choices: [],
      ),
    ),
  )
}

/// Create a deferred response (shows loading state)
pub fn deferred_response() -> InteractionResponse {
  InteractionResponse(
    response_type: DeferredChannelMessageWithSource,
    data: Some(
      InteractionCallbackData(
        content: None,
        ephemeral: False,
        embeds: [],
        allowed_mentions: None,
        flags: None,
        components: [],
        attachments: [],
        tts: None,
        custom_id: None,
        title: None,
        choices: [],
      ),
    ),
  )
}

/// Create a deferred ephemeral response
pub fn deferred_ephemeral_response() -> InteractionResponse {
  InteractionResponse(
    response_type: DeferredChannelMessageWithSource,
    data: Some(
      InteractionCallbackData(
        content: None,
        ephemeral: True,
        embeds: [],
        allowed_mentions: None,
        flags: None,
        components: [],
        attachments: [],
        tts: None,
        custom_id: None,
        title: None,
        choices: [],
      ),
    ),
  )
}

/// Create a pong response (for ping interactions)
pub fn pong_response() -> InteractionResponse {
  InteractionResponse(response_type: PongResponse, data: None)
}

/// Add an embed to a response
pub fn with_embed(
  response: InteractionResponse,
  embed: ResponseEmbed,
) -> InteractionResponse {
  case response.data {
    Some(data) ->
      InteractionResponse(
        response_type: response.response_type,
        data: Some(
          InteractionCallbackData(..data, embeds: [embed, ..data.embeds]),
        ),
      )
    None -> response
  }
}

/// Add components to a response
pub fn with_components(
  response: InteractionResponse,
  components: List(ResponseActionRow),
) -> InteractionResponse {
  case response.data {
    Some(data) ->
      InteractionResponse(
        response_type: response.response_type,
        data: Some(InteractionCallbackData(..data, components: components)),
      )
    None -> response
  }
}

/// Set ephemeral flag on response
pub fn make_ephemeral(response: InteractionResponse) -> InteractionResponse {
  case response.data {
    Some(data) ->
      InteractionResponse(
        response_type: response.response_type,
        data: Some(InteractionCallbackData(..data, ephemeral: True)),
      )
    None -> response
  }
}

// ============================================================================
// Public API - Button Builders
// ============================================================================

/// Create a primary button (blurple)
pub fn primary_button(custom_id: String, label: String) -> ResponseComponent {
  ResponseButton(
    style: PrimaryButton,
    label: Some(label),
    emoji: None,
    custom_id: Some(custom_id),
    url: None,
    disabled: None,
  )
}

/// Create a secondary button (grey)
pub fn secondary_button(custom_id: String, label: String) -> ResponseComponent {
  ResponseButton(
    style: SecondaryButton,
    label: Some(label),
    emoji: None,
    custom_id: Some(custom_id),
    url: None,
    disabled: None,
  )
}

/// Create a success button (green)
pub fn success_button(custom_id: String, label: String) -> ResponseComponent {
  ResponseButton(
    style: SuccessButton,
    label: Some(label),
    emoji: None,
    custom_id: Some(custom_id),
    url: None,
    disabled: None,
  )
}

/// Create a danger button (red)
pub fn danger_button(custom_id: String, label: String) -> ResponseComponent {
  ResponseButton(
    style: DangerButton,
    label: Some(label),
    emoji: None,
    custom_id: Some(custom_id),
    url: None,
    disabled: None,
  )
}

/// Create a link button (grey, navigates to URL)
pub fn link_button(url: String, label: String) -> ResponseComponent {
  ResponseButton(
    style: LinkButton,
    label: Some(label),
    emoji: None,
    custom_id: None,
    url: Some(url),
    disabled: None,
  )
}

/// Add emoji to a button
pub fn button_with_emoji(
  button: ResponseComponent,
  emoji: ResponseEmoji,
) -> ResponseComponent {
  case button {
    ResponseButton(style, label, _, custom_id, url, disabled) ->
      ResponseButton(
        style: style,
        label: label,
        emoji: Some(emoji),
        custom_id: custom_id,
        url: url,
        disabled: disabled,
      )
    _ -> button
  }
}

/// Set button disabled state
pub fn button_disabled(
  button: ResponseComponent,
  disabled: Bool,
) -> ResponseComponent {
  case button {
    ResponseButton(style, label, emoji, custom_id, url, _) ->
      ResponseButton(
        style: style,
        label: label,
        emoji: emoji,
        custom_id: custom_id,
        url: url,
        disabled: Some(disabled),
      )
    _ -> button
  }
}

/// Create an action row with components
pub fn action_row(components: List(ResponseComponent)) -> ResponseActionRow {
  ResponseActionRow(components: components)
}

/// Create a button row (convenience for single row of buttons)
pub fn button_row(buttons: List(ResponseComponent)) -> ResponseActionRow {
  ResponseActionRow(components: buttons)
}

// ============================================================================
// Public API - Select Menu Builders
// ============================================================================

/// Create a string select menu
pub fn string_select(
  custom_id: String,
  options: List(ResponseSelectOption),
) -> ResponseComponent {
  ResponseStringSelect(
    custom_id: custom_id,
    options: options,
    placeholder: None,
    min_values: None,
    max_values: None,
    disabled: None,
  )
}

/// Create a select option
pub fn select_option(label: String, value: String) -> ResponseSelectOption {
  ResponseSelectOption(
    label: label,
    value: value,
    description: None,
    emoji: None,
    default: None,
  )
}

/// Add description to select option
pub fn option_with_description(
  option: ResponseSelectOption,
  description: String,
) -> ResponseSelectOption {
  ResponseSelectOption(..option, description: Some(description))
}

/// Add placeholder to select menu
pub fn select_with_placeholder(
  select: ResponseComponent,
  placeholder: String,
) -> ResponseComponent {
  case select {
    ResponseStringSelect(
      custom_id,
      options,
      _,
      min_values,
      max_values,
      disabled,
    ) ->
      ResponseStringSelect(
        custom_id: custom_id,
        options: options,
        placeholder: Some(placeholder),
        min_values: min_values,
        max_values: max_values,
        disabled: disabled,
      )
    _ -> select
  }
}

// ============================================================================
// Public API - Modal Builders
// ============================================================================

/// Create a modal response
pub fn modal_response(
  custom_id: String,
  title: String,
  components: List(ResponseActionRow),
) -> InteractionResponse {
  InteractionResponse(
    response_type: ModalResponse,
    data: Some(
      InteractionCallbackData(
        content: None,
        ephemeral: False,
        embeds: [],
        allowed_mentions: None,
        flags: None,
        components: components,
        attachments: [],
        tts: None,
        custom_id: Some(custom_id),
        title: Some(title),
        choices: [],
      ),
    ),
  )
}

/// Create a short text input field (single line)
pub fn short_input(custom_id: String, label: String) -> ResponseComponent {
  ResponseTextInput(
    custom_id: custom_id,
    label: label,
    style: ShortInput,
    placeholder: None,
    value: None,
    required: None,
    min_length: None,
    max_length: None,
  )
}

/// Create a paragraph text input field (multi-line)
pub fn paragraph_input(custom_id: String, label: String) -> ResponseComponent {
  ResponseTextInput(
    custom_id: custom_id,
    label: label,
    style: ParagraphInput,
    placeholder: None,
    value: None,
    required: None,
    min_length: None,
    max_length: None,
  )
}

/// Set input placeholder
pub fn input_with_placeholder(
  input: ResponseComponent,
  placeholder: String,
) -> ResponseComponent {
  case input {
    ResponseTextInput(
      custom_id,
      label,
      style,
      _,
      value,
      required,
      min_length,
      max_length,
    ) ->
      ResponseTextInput(
        custom_id: custom_id,
        label: label,
        style: style,
        placeholder: Some(placeholder),
        value: value,
        required: required,
        min_length: min_length,
        max_length: max_length,
      )
    _ -> input
  }
}

/// Set input default value
pub fn input_with_value(
  input: ResponseComponent,
  value: String,
) -> ResponseComponent {
  case input {
    ResponseTextInput(
      custom_id,
      label,
      style,
      placeholder,
      _,
      required,
      min_length,
      max_length,
    ) ->
      ResponseTextInput(
        custom_id: custom_id,
        label: label,
        style: style,
        placeholder: placeholder,
        value: Some(value),
        required: required,
        min_length: min_length,
        max_length: max_length,
      )
    _ -> input
  }
}

/// Set input as required
pub fn input_required(
  input: ResponseComponent,
  required: Bool,
) -> ResponseComponent {
  case input {
    ResponseTextInput(
      custom_id,
      label,
      style,
      placeholder,
      value,
      _,
      min_length,
      max_length,
    ) ->
      ResponseTextInput(
        custom_id: custom_id,
        label: label,
        style: style,
        placeholder: placeholder,
        value: value,
        required: Some(required),
        min_length: min_length,
        max_length: max_length,
      )
    _ -> input
  }
}

/// Set input minimum length
pub fn input_min_length(
  input: ResponseComponent,
  min: Int,
) -> ResponseComponent {
  case input {
    ResponseTextInput(
      custom_id,
      label,
      style,
      placeholder,
      value,
      required,
      _,
      max_length,
    ) ->
      ResponseTextInput(
        custom_id: custom_id,
        label: label,
        style: style,
        placeholder: placeholder,
        value: value,
        required: required,
        min_length: Some(min),
        max_length: max_length,
      )
    _ -> input
  }
}

/// Set input maximum length
pub fn input_max_length(
  input: ResponseComponent,
  max: Int,
) -> ResponseComponent {
  case input {
    ResponseTextInput(
      custom_id,
      label,
      style,
      placeholder,
      value,
      required,
      min_length,
      _,
    ) ->
      ResponseTextInput(
        custom_id: custom_id,
        label: label,
        style: style,
        placeholder: placeholder,
        value: value,
        required: required,
        min_length: min_length,
        max_length: Some(max),
      )
    _ -> input
  }
}

/// Create a modal input row (each text input must be in its own action row)
pub fn input_row(input: ResponseComponent) -> ResponseActionRow {
  ResponseActionRow(components: [input])
}

// ============================================================================
// Public API - Update Message Response (for button interactions)
// ============================================================================

/// Create an update message response (updates the message the button is on)
pub fn update_message_response() -> InteractionResponse {
  InteractionResponse(
    response_type: UpdateMessage,
    data: Some(
      InteractionCallbackData(
        content: None,
        ephemeral: False,
        embeds: [],
        allowed_mentions: None,
        flags: None,
        components: [],
        attachments: [],
        tts: None,
        custom_id: None,
        title: None,
        choices: [],
      ),
    ),
  )
}

/// Create a deferred update response (shows loading, then updates)
pub fn deferred_update_response() -> InteractionResponse {
  InteractionResponse(
    response_type: DeferredUpdateMessage,
    data: Some(
      InteractionCallbackData(
        content: None,
        ephemeral: False,
        embeds: [],
        allowed_mentions: None,
        flags: None,
        components: [],
        attachments: [],
        tts: None,
        custom_id: None,
        title: None,
        choices: [],
      ),
    ),
  )
}

/// Set content on update message response
pub fn update_with_content(
  response: InteractionResponse,
  content: String,
) -> InteractionResponse {
  case response.data {
    Some(data) ->
      InteractionResponse(
        response_type: response.response_type,
        data: Some(InteractionCallbackData(..data, content: Some(content))),
      )
    None -> response
  }
}

// ============================================================================
// Public API - Modal Field Value Extraction
// ============================================================================

/// Get text input value from modal submission
pub fn get_modal_value(
  data: InteractionPayloadData,
  custom_id: String,
) -> Option(String) {
  case data {
    ModalPayload(components: rows, ..) ->
      find_input_value_in_rows(rows, custom_id)
    _ -> None
  }
}

/// Get all text input values from modal submission as a dict
pub fn get_modal_values(data: InteractionPayloadData) -> Dict(String, String) {
  case data {
    ModalPayload(components: rows, ..) -> collect_input_values(rows)
    _ -> dict.new()
  }
}

/// Find input value in action rows
fn find_input_value_in_rows(
  rows: List(ResponseActionRow),
  custom_id: String,
) -> Option(String) {
  case
    rows
    |> list.find_map(fn(row) { find_input_value(row.components, custom_id) })
  {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

/// Find input value in components
fn find_input_value(
  components: List(ResponseComponent),
  custom_id: String,
) -> Result(String, Nil) {
  list.find_map(components, fn(comp) {
    case comp {
      ResponseTextInput(custom_id: id, value: Some(v), ..) ->
        case id == custom_id {
          True -> Ok(v)
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

/// Collect all input values from rows
fn collect_input_values(rows: List(ResponseActionRow)) -> Dict(String, String) {
  rows
  |> list.fold(dict.new(), fn(acc, row) {
    list.fold(row.components, acc, fn(dict_acc, comp) {
      case comp {
        ResponseTextInput(custom_id: id, value: Some(v), ..) ->
          dict.insert(dict_acc, id, v)
        _ -> dict_acc
      }
    })
  })
}

// ============================================================================
// Public API - Input Validation
// ============================================================================

/// Validation result
pub type ValidationResult {
  ValidInput
  InvalidInput(error: String)
}

/// Validate input is not empty
pub fn validate_required(
  value: Option(String),
  field_name: String,
) -> ValidationResult {
  case value {
    Some(v) ->
      case string.is_empty(v) {
        True -> InvalidInput(error: field_name <> " is required")
        False -> ValidInput
      }
    None -> InvalidInput(error: field_name <> " is required")
  }
}

/// Validate input minimum length
pub fn validate_min_length(
  value: Option(String),
  min: Int,
  field_name: String,
) -> ValidationResult {
  case value {
    Some(v) ->
      case string.length(v) < min {
        True ->
          InvalidInput(
            error: field_name
            <> " must be at least "
            <> int.to_string(min)
            <> " characters",
          )
        False -> ValidInput
      }
    None -> ValidInput
  }
}

/// Validate input maximum length
pub fn validate_max_length(
  value: Option(String),
  max: Int,
  field_name: String,
) -> ValidationResult {
  case value {
    Some(v) ->
      case string.length(v) > max {
        True ->
          InvalidInput(
            error: field_name
            <> " must be at most "
            <> int.to_string(max)
            <> " characters",
          )
        False -> ValidInput
      }
    None -> ValidInput
  }
}

/// Validate input matches a pattern (simple contains check)
pub fn validate_contains(
  value: Option(String),
  pattern: String,
  field_name: String,
) -> ValidationResult {
  case value {
    Some(v) ->
      case string.contains(v, pattern) {
        True -> ValidInput
        False ->
          InvalidInput(
            error: field_name <> " must contain \"" <> pattern <> "\"",
          )
      }
    None -> ValidInput
  }
}

/// Validate input is a valid number
pub fn validate_is_number(
  value: Option(String),
  field_name: String,
) -> ValidationResult {
  case value {
    Some(v) ->
      case int.parse(v) {
        Ok(_) -> ValidInput
        Error(_) -> InvalidInput(error: field_name <> " must be a number")
      }
    None -> ValidInput
  }
}

/// Validate input is within numeric range
pub fn validate_range(
  value: Option(String),
  min: Int,
  max: Int,
  field_name: String,
) -> ValidationResult {
  case value {
    Some(v) -> {
      case int.parse(v) {
        Ok(n) ->
          case n >= min && n <= max {
            True -> ValidInput
            False ->
              InvalidInput(
                error: field_name
                <> " must be between "
                <> int.to_string(min)
                <> " and "
                <> int.to_string(max),
              )
          }
        Error(_) -> InvalidInput(error: field_name <> " must be a number")
      }
    }
    None -> ValidInput
  }
}

/// Combine multiple validation results
pub fn combine_validations(
  results: List(ValidationResult),
) -> ValidationResult {
  case
    list.find(results, fn(r) {
      case r {
        InvalidInput(_) -> True
        ValidInput -> False
      }
    })
  {
    Ok(error) -> error
    Error(_) -> ValidInput
  }
}

/// Create error response for validation failure
pub fn validation_error_response(
  result: ValidationResult,
) -> InteractionResponse {
  case result {
    ValidInput -> ephemeral_response("Validation passed")
    InvalidInput(error) -> ephemeral_response("❌ " <> error)
  }
}

// ============================================================================
// Public API - Command Option Builders
// ============================================================================

/// Create a string option
pub fn string_option(
  name: String,
  description: String,
  required: Bool,
) -> CommandOption {
  CommandOption(
    option_type: CmdStringOption,
    name: name,
    description: description,
    required: required,
    choices: [],
    channel_types: [],
    min_value: None,
    max_value: None,
    min_length: None,
    max_length: None,
    autocomplete: False,
    options: [],
  )
}

/// Create an integer option
pub fn integer_option(
  name: String,
  description: String,
  required: Bool,
) -> CommandOption {
  CommandOption(
    option_type: CmdIntegerOption,
    name: name,
    description: description,
    required: required,
    choices: [],
    channel_types: [],
    min_value: None,
    max_value: None,
    min_length: None,
    max_length: None,
    autocomplete: False,
    options: [],
  )
}

/// Create a boolean option
pub fn boolean_option(
  name: String,
  description: String,
  required: Bool,
) -> CommandOption {
  CommandOption(
    option_type: CmdBooleanOption,
    name: name,
    description: description,
    required: required,
    choices: [],
    channel_types: [],
    min_value: None,
    max_value: None,
    min_length: None,
    max_length: None,
    autocomplete: False,
    options: [],
  )
}

/// Create a user option
pub fn user_option(
  name: String,
  description: String,
  required: Bool,
) -> CommandOption {
  CommandOption(
    option_type: CmdUserOption,
    name: name,
    description: description,
    required: required,
    choices: [],
    channel_types: [],
    min_value: None,
    max_value: None,
    min_length: None,
    max_length: None,
    autocomplete: False,
    options: [],
  )
}

/// Create a channel option
pub fn channel_option(
  name: String,
  description: String,
  required: Bool,
) -> CommandOption {
  CommandOption(
    option_type: CmdChannelOption,
    name: name,
    description: description,
    required: required,
    choices: [],
    channel_types: [],
    min_value: None,
    max_value: None,
    min_length: None,
    max_length: None,
    autocomplete: False,
    options: [],
  )
}

/// Create a role option
pub fn role_option(
  name: String,
  description: String,
  required: Bool,
) -> CommandOption {
  CommandOption(
    option_type: CmdRoleOption,
    name: name,
    description: description,
    required: required,
    choices: [],
    channel_types: [],
    min_value: None,
    max_value: None,
    min_length: None,
    max_length: None,
    autocomplete: False,
    options: [],
  )
}

/// Add choices to an option
pub fn with_choices(
  option: CommandOption,
  choices: List(CommandOptionChoice),
) -> CommandOption {
  CommandOption(..option, choices: choices)
}

/// Create a string choice
pub fn string_choice(name: String, value: String) -> CommandOptionChoice {
  CommandOptionChoice(name: name, value: StringChoiceValue(value))
}

/// Create an int choice
pub fn int_choice(name: String, value: Int) -> CommandOptionChoice {
  CommandOptionChoice(name: name, value: IntChoiceValue(value))
}

// ============================================================================
// Public API - Command Builder
// ============================================================================

/// Create a new slash command
pub fn new_command(name: String, description: String) -> SlashCommand {
  SlashCommand(
    name: name,
    description: description,
    command_type: ChatInputCommand,
    options: [],
    default_permission: None,
    default_member_permissions: None,
    dm_permission: Some(True),
    name_localizations: None,
    description_localizations: None,
    nsfw: Some(False),
  )
}

/// Add option to command
pub fn command_with_option(
  command: SlashCommand,
  option: CommandOption,
) -> SlashCommand {
  SlashCommand(..command, options: [option, ..command.options])
}

/// Set command options
pub fn command_with_options(
  command: SlashCommand,
  options: List(CommandOption),
) -> SlashCommand {
  SlashCommand(..command, options: options)
}

/// Set DM permission
pub fn command_with_dm_permission(
  command: SlashCommand,
  dm_permission: Bool,
) -> SlashCommand {
  SlashCommand(..command, dm_permission: Some(dm_permission))
}

/// Set NSFW flag
pub fn command_with_nsfw(command: SlashCommand, nsfw: Bool) -> SlashCommand {
  SlashCommand(..command, nsfw: Some(nsfw))
}

// ============================================================================
// Public API - Embed Builders
// ============================================================================

/// Create new embed
pub fn new_embed() -> ResponseEmbed {
  ResponseEmbed(
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
pub fn embed_title(embed: ResponseEmbed, title: String) -> ResponseEmbed {
  ResponseEmbed(..embed, title: Some(title))
}

/// Set embed description
pub fn embed_description(
  embed: ResponseEmbed,
  description: String,
) -> ResponseEmbed {
  ResponseEmbed(..embed, description: Some(description))
}

/// Set embed color
pub fn embed_color(embed: ResponseEmbed, color: Int) -> ResponseEmbed {
  ResponseEmbed(..embed, color: Some(color))
}

/// Add embed field
pub fn embed_field(
  embed: ResponseEmbed,
  field: ResponseEmbedField,
) -> ResponseEmbed {
  ResponseEmbed(..embed, fields: [field, ..embed.fields])
}

/// Create embed field
pub fn new_field(name: String, value: String) -> ResponseEmbedField {
  ResponseEmbedField(name: name, value: value, inline: None)
}

/// Set field inline
pub fn field_inline(
  field: ResponseEmbedField,
  inline: Bool,
) -> ResponseEmbedField {
  ResponseEmbedField(..field, inline: Some(inline))
}

// ============================================================================
// Public API - Option Value Extraction
// ============================================================================

/// Get string option value from interaction data
pub fn get_string_option(
  data: InteractionPayloadData,
  name: String,
) -> Option(String) {
  case data {
    CommandPayload(options: opts, ..) -> {
      find_option_value(opts, name, fn(v) {
        case v {
          StringVal(value) -> Some(value)
          _ -> None
        }
      })
    }
    _ -> None
  }
}

/// Get integer option value from interaction data
pub fn get_int_option(
  data: InteractionPayloadData,
  name: String,
) -> Option(Int) {
  case data {
    CommandPayload(options: opts, ..) -> {
      find_option_value(opts, name, fn(v) {
        case v {
          IntVal(value) -> Some(value)
          _ -> None
        }
      })
    }
    _ -> None
  }
}

/// Get boolean option value from interaction data
pub fn get_bool_option(
  data: InteractionPayloadData,
  name: String,
) -> Option(Bool) {
  case data {
    CommandPayload(options: opts, ..) -> {
      find_option_value(opts, name, fn(v) {
        case v {
          BoolVal(value) -> Some(value)
          _ -> None
        }
      })
    }
    _ -> None
  }
}

/// Get user option value from interaction data
pub fn get_user_option(
  data: InteractionPayloadData,
  name: String,
) -> Option(Snowflake) {
  case data {
    CommandPayload(options: opts, ..) -> {
      find_option_value(opts, name, fn(v) {
        case v {
          UserVal(value) -> Some(value)
          _ -> None
        }
      })
    }
    _ -> None
  }
}

/// Get channel option value from interaction data
pub fn get_channel_option(
  data: InteractionPayloadData,
  name: String,
) -> Option(Snowflake) {
  case data {
    CommandPayload(options: opts, ..) -> {
      find_option_value(opts, name, fn(v) {
        case v {
          ChannelVal(value) -> Some(value)
          _ -> None
        }
      })
    }
    _ -> None
  }
}

/// Get role option value from interaction data
pub fn get_role_option(
  data: InteractionPayloadData,
  name: String,
) -> Option(Snowflake) {
  case data {
    CommandPayload(options: opts, ..) -> {
      find_option_value(opts, name, fn(v) {
        case v {
          RoleVal(value) -> Some(value)
          _ -> None
        }
      })
    }
    _ -> None
  }
}

/// Find option value by name
fn find_option_value(
  options: List(CommandOptionPayload),
  name: String,
  extract: fn(OptionValue) -> Option(a),
) -> Option(a) {
  case list.find(options, fn(opt) { opt.name == name }) {
    Ok(opt) -> {
      case opt.value {
        Some(v) -> extract(v)
        None -> None
      }
    }
    Error(_) -> None
  }
}

// ============================================================================
// Actor Message Handler
// ============================================================================

fn handle_message(
  state: CommandsState,
  message: CommandsMessage,
) -> actor.Next(CommandsState, CommandsMessage) {
  case message {
    RegisterGlobalCommand(reply_to, command) -> {
      let result = do_register_command(state.config, command, None)
      process.send(reply_to, result)
      actor.continue(state)
    }

    RegisterGuildCommand(reply_to, command, guild_id) -> {
      let result = do_register_command(state.config, command, Some(guild_id))
      process.send(reply_to, result)
      actor.continue(state)
    }

    GetGlobalCommands(reply_to) -> {
      let result = do_get_commands(state.config, None)
      process.send(reply_to, result)
      actor.continue(state)
    }

    DeleteCommand(reply_to, command_id, guild_id) -> {
      let result = do_delete_command(state.config, command_id, guild_id)
      process.send(reply_to, result)
      actor.continue(state)
    }

    RegisterHandler(reply_to, command_name, handler, guild_id) -> {
      let key = handler_key(command_name, guild_id)
      let entry =
        CommandHandlerEntry(
          command_name: command_name,
          handler: handler,
          guild_id: guild_id,
        )
      let new_handlers = dict.insert(state.handlers, key, entry)
      process.send(reply_to, Nil)
      actor.continue(CommandsState(..state, handlers: new_handlers))
    }

    HandleInteraction(reply_to, interaction) -> {
      let response = dispatch_to_handler(state, interaction)
      process.send(reply_to, response)
      actor.continue(state)
    }

    GetHandlerCount(reply_to) -> {
      process.send(reply_to, dict.size(state.handlers))
      actor.continue(state)
    }

    ClearHandlers(reply_to) -> {
      process.send(reply_to, Nil)
      actor.continue(CommandsState(..state, handlers: dict.new()))
    }
  }
}

/// Generate handler key
fn handler_key(command_name: String, guild_id: Option(Snowflake)) -> String {
  case guild_id {
    Some(gid) -> command_name <> ":" <> gid
    None -> command_name
  }
}

/// Dispatch interaction to handler
fn dispatch_to_handler(
  state: CommandsState,
  interaction: InteractionPayload,
) -> Option(InteractionResponse) {
  case interaction.data {
    Some(data) -> {
      let command_name = case data {
        CommandPayload(name: n, ..) -> n
        ComponentPayload(custom_id: id, ..) -> id
        ModalPayload(custom_id: id, ..) -> id
      }

      // Try guild-specific handler first
      let guild_response = case interaction.guild_id {
        Some(guild_id) -> {
          let key = handler_key(command_name, Some(guild_id))
          case dict.get(state.handlers, key) {
            Ok(entry) -> Some(entry.handler(interaction, data))
            Error(_) -> None
          }
        }
        None -> None
      }

      case guild_response {
        Some(resp) -> Some(resp)
        None -> {
          // Try global handler
          let key = handler_key(command_name, None)
          case dict.get(state.handlers, key) {
            Ok(entry) -> Some(entry.handler(interaction, data))
            Error(_) -> None
          }
        }
      }
    }
    None -> None
  }
}

// ============================================================================
// Internal - REST API Calls
// ============================================================================

fn do_register_command(
  config: CommandsConfig,
  command: SlashCommand,
  guild_id: Option(Snowflake),
) -> Result(RegisteredCommand, CommandsError) {
  let url = case guild_id {
    Some(gid) ->
      get_base_url(config)
      <> "/applications/"
      <> config.application_id
      <> "/guilds/"
      <> gid
      <> "/commands"
    None ->
      get_base_url(config)
      <> "/applications/"
      <> config.application_id
      <> "/commands"
  }

  let body = encode_command(command)

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.prepend_header("Authorization", "Bot " <> config.bot_token)
    |> request.prepend_header("Content-Type", "application/json")
    |> request.prepend_header(
      "User-Agent",
      "SupernovaBot (https://supernova.bot, v1.0)",
    )

  let req_with_body = request.set_body(req, body)
  let req_with_url = request.set_host(req_with_body, url)

  execute_request(req_with_url)
  |> result.try(parse_command_response)
}

fn do_get_commands(
  config: CommandsConfig,
  guild_id: Option(Snowflake),
) -> Result(List(RegisteredCommand), CommandsError) {
  let url = case guild_id {
    Some(gid) ->
      get_base_url(config)
      <> "/applications/"
      <> config.application_id
      <> "/guilds/"
      <> gid
      <> "/commands"
    None ->
      get_base_url(config)
      <> "/applications/"
      <> config.application_id
      <> "/commands"
  }

  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.prepend_header("Authorization", "Bot " <> config.bot_token)
    |> request.prepend_header("Content-Type", "application/json")

  let req_with_url = request.set_host(req, url)

  execute_request(req_with_url)
  |> result.try(parse_commands_list_response)
}

fn do_delete_command(
  config: CommandsConfig,
  command_id: Snowflake,
  guild_id: Option(Snowflake),
) -> Result(Nil, CommandsError) {
  let url = case guild_id {
    Some(gid) ->
      get_base_url(config)
      <> "/applications/"
      <> config.application_id
      <> "/guilds/"
      <> gid
      <> "/commands/"
      <> command_id
    None ->
      get_base_url(config)
      <> "/applications/"
      <> config.application_id
      <> "/commands/"
      <> command_id
  }

  let req =
    request.new()
    |> request.set_method(http.Delete)
    |> request.prepend_header("Authorization", "Bot " <> config.bot_token)

  let req_with_url = request.set_host(req, url)

  case execute_request(req_with_url) {
    Ok(resp) -> {
      case resp.status {
        204 -> Ok(Nil)
        200 -> Ok(Nil)
        404 -> Error(CommandsNotFound("Command not found"))
        status -> Error(CommandsUnknownError(status, resp.body))
      }
    }
    Error(e) -> Error(e)
  }
}

// ============================================================================
// Internal - HTTP Execution
// ============================================================================

fn execute_request(
  req: Request(String),
) -> Result(Response(String), CommandsError) {
  case hackney.send(req) {
    Ok(resp) -> Ok(resp)
    Error(hackney.InvalidUtf8Response) ->
      Error(CommandsHttpError("Invalid UTF-8 response"))
    Error(hackney.Other(reason)) ->
      Error(CommandsHttpError("HTTP error: " <> string.inspect(reason)))
  }
}

fn parse_command_response(
  resp: Response(String),
) -> Result(RegisteredCommand, CommandsError) {
  case resp.status {
    200 -> parse_registered_command(resp.body)
    201 -> parse_registered_command(resp.body)
    400 -> {
      let message = extract_error_message(resp.body)
      Error(CommandsBadRequest(message))
    }
    401 -> Error(CommandsUnauthorized)
    403 -> {
      let message = extract_error_message(resp.body)
      Error(CommandsForbidden(message))
    }
    404 -> {
      let message = extract_error_message(resp.body)
      Error(CommandsNotFound(message))
    }
    429 -> {
      let retry_after = extract_retry_after(resp.body)
      Error(CommandsRateLimited(retry_after))
    }
    status -> Error(CommandsUnknownError(status, resp.body))
  }
}

fn parse_commands_list_response(
  resp: Response(String),
) -> Result(List(RegisteredCommand), CommandsError) {
  case resp.status {
    200 -> parse_registered_commands_list(resp.body)
    400 -> {
      let message = extract_error_message(resp.body)
      Error(CommandsBadRequest(message))
    }
    401 -> Error(CommandsUnauthorized)
    403 -> {
      let message = extract_error_message(resp.body)
      Error(CommandsForbidden(message))
    }
    status -> Error(CommandsUnknownError(status, resp.body))
  }
}

fn parse_registered_command(
  body: String,
) -> Result(RegisteredCommand, CommandsError) {
  let id = json_decode_string_field(body, "id")
  let app_id = json_decode_string_field(body, "application_id")
  let name = json_decode_string_field(body, "name")
  let description = json_decode_string_field(body, "description")
  let version = json_decode_string_field(body, "version")

  case id, app_id, name {
    Some(i), Some(a), Some(n) ->
      Ok(RegisteredCommand(
        id: i,
        application_id: a,
        name: n,
        description: option.unwrap(description, ""),
        command_type: ChatInputCommand,
        version: option.unwrap(version, ""),
        options: [],
        guild_id: json_decode_string_field(body, "guild_id"),
      ))
    _, _, _ -> Error(CommandsJsonError("Failed to parse command response"))
  }
}

fn parse_registered_commands_list(
  body: String,
) -> Result(List(RegisteredCommand), CommandsError) {
  case string.starts_with(body, "[") {
    True -> {
      let inner = string.drop_start(body, 1)
      let inner = string.drop_end(inner, 1)
      case string.is_empty(inner) {
        True -> Ok([])
        False -> {
          let parts = split_json_objects(inner)
          let commands =
            parts
            |> list.map(parse_registered_command)
            |> list.filter(fn(r) {
              case r {
                Ok(_) -> True
                Error(_) -> False
              }
            })
            |> list.map(fn(r) {
              case r {
                Ok(cmd) -> cmd
                Error(_) -> panic as "unreachable"
              }
            })
          Ok(commands)
        }
      }
    }
    False -> Ok([])
  }
}

fn extract_error_message(body: String) -> String {
  let decoder = {
    use message <- decode.field("message", decode.string)
    decode.success(message)
  }
  case json.parse(from: body, using: decoder) {
    Ok(msg) -> msg
    Error(_) -> "Unknown error"
  }
}

fn extract_retry_after(body: String) -> Int {
  let decoder = {
    use retry_after <- decode.field("retry_after", decode.int)
    decode.success(retry_after)
  }
  case json.parse(from: body, using: decoder) {
    Ok(ms) -> ms
    Error(_) -> 5000
  }
}

// ============================================================================
// Internal - JSON Encoding
// ============================================================================

fn encode_command(command: SlashCommand) -> String {
  let fields =
    [
      json_key_value("name", json_string(command.name)),
      json_key_value("description", json_string(command.description)),
      json_key_value(
        "type",
        int.to_string(command_type_to_int(command.command_type)),
      ),
    ]
    |> add_options_field("options", command.options)
    |> add_optional_bool_field("dm_permission", command.dm_permission)
    |> add_optional_bool_field("nsfw", command.nsfw)

  "{" <> string.join(fields, ",") <> "}"
}

fn add_options_field(
  fields: List(String),
  name: String,
  options: List(CommandOption),
) -> List(String) {
  case options {
    [] -> fields
    opts -> {
      let encoded =
        "[" <> string.join(list.map(opts, encode_option), ",") <> "]"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn encode_option(option: CommandOption) -> String {
  let fields =
    [
      json_key_value(
        "type",
        int.to_string(option_type_to_int(option.option_type)),
      ),
      json_key_value("name", json_string(option.name)),
      json_key_value("description", json_string(option.description)),
      json_key_value("required", json_bool(option.required)),
    ]
    |> add_choices_field("choices", option.choices)
    |> add_channel_types_field("channel_types", option.channel_types)
    |> add_optional_float_field("min_value", option.min_value)
    |> add_optional_float_field("max_value", option.max_value)
    |> add_optional_int_field("min_length", option.min_length)
    |> add_optional_int_field("max_length", option.max_length)
    |> add_autocomplete_field("autocomplete", option.autocomplete)
    |> add_options_field("options", option.options)

  "{" <> string.join(fields, ",") <> "}"
}

fn add_choices_field(
  fields: List(String),
  name: String,
  choices: List(CommandOptionChoice),
) -> List(String) {
  case choices {
    [] -> fields
    chs -> {
      let encoded = "[" <> string.join(list.map(chs, encode_choice), ",") <> "]"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn encode_choice(choice: CommandOptionChoice) -> String {
  let value = case choice.value {
    StringChoiceValue(v) -> json_string(v)
    IntChoiceValue(v) -> int.to_string(v)
    FloatChoiceValue(v) -> float_to_string(v)
  }
  "{\"name\":" <> json_string(choice.name) <> ",\"value\":" <> value <> "}"
}

fn add_channel_types_field(
  fields: List(String),
  name: String,
  channel_types: List(ChannelTypeFilter),
) -> List(String) {
  case channel_types {
    [] -> fields
    types -> {
      let encoded =
        "["
        <> string.join(
          list.map(types, fn(t) { int.to_string(channel_type_filter_to_int(t)) }),
          ",",
        )
        <> "]"
      [json_key_value(name, encoded), ..fields]
    }
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

fn add_optional_float_field(
  fields: List(String),
  name: String,
  value: Option(Float),
) -> List(String) {
  case value {
    Some(v) -> [json_key_value(name, float_to_string(v)), ..fields]
    None -> fields
  }
}

fn add_autocomplete_field(
  fields: List(String),
  name: String,
  autocomplete: Bool,
) -> List(String) {
  case autocomplete {
    True -> [json_key_value(name, "true"), ..fields]
    False -> fields
  }
}

// ============================================================================
// Internal - JSON Encoding for Responses
// ============================================================================

/// Encode interaction response to JSON
pub fn encode_response(response: InteractionResponse) -> String {
  let type_field =
    json_key_value(
      "type",
      int.to_string(response_type_to_int(response.response_type)),
    )

  let data_field = case response.data {
    Some(data) -> {
      let encoded = encode_callback_data(data)
      [json_key_value("data", encoded), type_field]
    }
    None -> [type_field]
  }

  "{" <> string.join(data_field, ",") <> "}"
}

fn encode_callback_data(data: InteractionCallbackData) -> String {
  let fields =
    []
    |> add_optional_string_field("content", data.content)
    |> add_embeds_field_for_response("embeds", data.embeds)
    |> add_components_field("components", data.components)
    |> add_allowed_mentions_field("allowed_mentions", data.allowed_mentions)
    |> add_attachments_field_for_response("attachments", data.attachments)
    |> add_optional_bool_field("tts", data.tts)
    |> add_optional_string_field("custom_id", data.custom_id)
    |> add_optional_string_field("title", data.title)
    |> add_choices_field("choices", data.choices)
    |> add_flags_field(data.ephemeral, data.flags)

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

fn add_embeds_field_for_response(
  fields: List(String),
  name: String,
  embeds: List(ResponseEmbed),
) -> List(String) {
  case embeds {
    [] -> fields
    es -> {
      let encoded = "[" <> string.join(list.map(es, encode_embed), ",") <> "]"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn encode_embed(embed: ResponseEmbed) -> String {
  let fields =
    []
    |> add_optional_string_field("title", embed.title)
    |> add_optional_string_field("description", embed.description)
    |> add_optional_string_field("url", embed.url)
    |> add_optional_string_field("timestamp", embed.timestamp)
    |> add_optional_int_field("color", embed.color)
    |> add_optional_footer_field("footer", embed.footer)
    |> add_embed_fields_field_for_response("fields", embed.fields)

  "{" <> string.join(fields, ",") <> "}"
}

fn add_optional_footer_field(
  fields: List(String),
  name: String,
  footer: Option(ResponseEmbedFooter),
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

fn add_embed_fields_field_for_response(
  fields: List(String),
  name: String,
  embed_fields: List(ResponseEmbedField),
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

fn encode_embed_field(field: ResponseEmbedField) -> String {
  let fields =
    [
      json_key_value("name", json_string(field.name)),
      json_key_value("value", json_string(field.value)),
    ]
    |> add_optional_bool_field("inline", field.inline)

  "{" <> string.join(fields, ",") <> "}"
}

fn add_components_field(
  fields: List(String),
  name: String,
  components: List(ResponseActionRow),
) -> List(String) {
  case components {
    [] -> fields
    comps -> {
      let encoded =
        "[" <> string.join(list.map(comps, encode_action_row), ",") <> "]"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn encode_action_row(row: ResponseActionRow) -> String {
  let components =
    "[" <> string.join(list.map(row.components, encode_component), ",") <> "]"
  "{\"type\":1,\"components\":" <> components <> "}"
}

fn encode_component(component: ResponseComponent) -> String {
  case component {
    ResponseButton(style, label, emoji, custom_id, url, disabled) -> {
      let fields =
        [
          json_key_value("type", "2"),
          json_key_value("style", int.to_string(button_style_to_int(style))),
        ]
        |> add_optional_string_field("label", label)
        |> add_optional_string_field("custom_id", custom_id)
        |> add_optional_string_field("url", url)
        |> add_optional_bool_field("disabled", disabled)
        |> add_emoji_field("emoji", emoji)

      "{" <> string.join(fields, ",") <> "}"
    }

    ResponseStringSelect(
      custom_id: custom_id,
      options: opts,
      placeholder: placeholder,
      min_values: min_values,
      max_values: max_values,
      disabled: disabled,
    ) -> {
      let options_encoded =
        "[" <> string.join(list.map(opts, encode_select_option), ",") <> "]"

      let fields =
        [
          json_key_value("type", "3"),
          json_key_value("custom_id", json_string(custom_id)),
          json_key_value("options", options_encoded),
        ]
        |> add_optional_string_field("placeholder", placeholder)
        |> add_optional_int_field("min_values", min_values)
        |> add_optional_int_field("max_values", max_values)
        |> add_optional_bool_field("disabled", disabled)

      "{" <> string.join(fields, ",") <> "}"
    }

    ResponseUserSelect(
      custom_id: custom_id,
      placeholder: placeholder,
      min_values: min_values,
      max_values: max_values,
      disabled: disabled,
    ) -> {
      let fields =
        [
          json_key_value("type", "5"),
          json_key_value("custom_id", json_string(custom_id)),
        ]
        |> add_optional_string_field("placeholder", placeholder)
        |> add_optional_int_field("min_values", min_values)
        |> add_optional_int_field("max_values", max_values)
        |> add_optional_bool_field("disabled", disabled)

      "{" <> string.join(fields, ",") <> "}"
    }

    ResponseRoleSelect(
      custom_id: custom_id,
      placeholder: placeholder,
      min_values: min_values,
      max_values: max_values,
      disabled: disabled,
    ) -> {
      let fields =
        [
          json_key_value("type", "6"),
          json_key_value("custom_id", json_string(custom_id)),
        ]
        |> add_optional_string_field("placeholder", placeholder)
        |> add_optional_int_field("min_values", min_values)
        |> add_optional_int_field("max_values", max_values)
        |> add_optional_bool_field("disabled", disabled)

      "{" <> string.join(fields, ",") <> "}"
    }

    ResponseChannelSelect(
      custom_id: custom_id,
      channel_types: channel_types,
      placeholder: placeholder,
      min_values: min_values,
      max_values: max_values,
      disabled: disabled,
    ) -> {
      let channel_types_encoded =
        "["
        <> string.join(
          list.map(channel_types, fn(t) {
            int.to_string(channel_type_filter_to_int(t))
          }),
          ",",
        )
        <> "]"

      let fields =
        [
          json_key_value("type", "8"),
          json_key_value("custom_id", json_string(custom_id)),
          json_key_value("channel_types", channel_types_encoded),
        ]
        |> add_optional_string_field("placeholder", placeholder)
        |> add_optional_int_field("min_values", min_values)
        |> add_optional_int_field("max_values", max_values)
        |> add_optional_bool_field("disabled", disabled)

      "{" <> string.join(fields, ",") <> "}"
    }

    ResponseTextInput(
      custom_id: custom_id,
      label: label,
      style: style,
      placeholder: placeholder,
      value: value,
      required: required,
      min_length: min_length,
      max_length: max_length,
    ) -> {
      let fields =
        [
          json_key_value("type", "4"),
          json_key_value("custom_id", json_string(custom_id)),
          json_key_value("label", json_string(label)),
          json_key_value("style", int.to_string(text_input_style_to_int(style))),
        ]
        |> add_optional_string_field("placeholder", placeholder)
        |> add_optional_string_field("value", value)
        |> add_optional_bool_field("required", required)
        |> add_optional_int_field("min_length", min_length)
        |> add_optional_int_field("max_length", max_length)

      "{" <> string.join(fields, ",") <> "}"
    }
  }
}

fn add_emoji_field(
  fields: List(String),
  name: String,
  emoji: Option(ResponseEmoji),
) -> List(String) {
  case emoji {
    None -> fields
    Some(e) -> {
      let emoji_fields =
        []
        |> add_optional_string_field("name", e.name)
        |> add_optional_string_field("id", e.id)
        |> add_optional_bool_field("animated", e.animated)

      let encoded = "{" <> string.join(emoji_fields, ",") <> "}"
      [json_key_value(name, encoded), ..fields]
    }
  }
}

fn encode_select_option(option: ResponseSelectOption) -> String {
  let fields =
    [
      json_key_value("label", json_string(option.label)),
      json_key_value("value", json_string(option.value)),
    ]
    |> add_optional_string_field("description", option.description)
    |> add_emoji_field("emoji", option.emoji)
    |> add_optional_bool_field("default", option.default)

  "{" <> string.join(fields, ",") <> "}"
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

fn add_attachments_field_for_response(
  fields: List(String),
  name: String,
  attachments: List(ResponseAttachment),
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

fn encode_attachment(attachment: ResponseAttachment) -> String {
  let fields =
    [
      json_key_value("id", json_string(attachment.id)),
      json_key_value("filename", json_string(attachment.filename)),
    ]
    |> add_optional_string_field("description", attachment.description)

  "{" <> string.join(fields, ",") <> "}"
}

fn add_flags_field(
  fields: List(String),
  ephemeral: Bool,
  flags: Option(Int),
) -> List(String) {
  let actual_flags = case flags {
    Some(f) -> f
    None ->
      case ephemeral {
        True -> 64
        // Ephemeral flag
        False -> 0
      }
  }

  case actual_flags == 0 {
    True -> fields
    False -> [json_key_value("flags", int.to_string(actual_flags)), ..fields]
  }
}

// ============================================================================
// Internal - Type Conversions
// ============================================================================

fn command_type_to_int(t: CommandType) -> Int {
  case t {
    ChatInputCommand -> 1
    UserContextMenu -> 2
    MessageContextMenu -> 3
  }
}

fn option_type_to_int(t: CommandOptionType) -> Int {
  case t {
    CmdSubCommand -> 1
    CmdSubCommandGroup -> 2
    CmdStringOption -> 3
    CmdIntegerOption -> 4
    CmdBooleanOption -> 5
    CmdUserOption -> 6
    CmdChannelOption -> 7
    CmdRoleOption -> 8
    CmdMentionableOption -> 9
    CmdNumberOption -> 10
    CmdAttachmentOption -> 11
  }
}

fn channel_type_filter_to_int(t: ChannelTypeFilter) -> Int {
  case t {
    GuildTextChannel -> 0
    DmChannel -> 1
    GuildVoiceChannel -> 2
    GroupDmChannel -> 3
    GuildCategoryChannel -> 4
    GuildAnnouncementChannel -> 5
    AnnouncementThreadChannel -> 10
    PublicThreadChannel -> 11
    PrivateThreadChannel -> 12
    GuildStageVoiceChannel -> 13
    GuildDirectoryChannel -> 14
    GuildForumChannel -> 15
    GuildMediaChannel -> 16
  }
}

fn response_type_to_int(t: InteractionResponseType) -> Int {
  case t {
    PongResponse -> 1
    ChannelMessageWithSource -> 4
    DeferredChannelMessageWithSource -> 5
    DeferredUpdateMessage -> 6
    UpdateMessage -> 7
    AutocompleteResult -> 8
    ModalResponse -> 9
  }
}

fn button_style_to_int(s: ResponseButtonStyle) -> Int {
  case s {
    PrimaryButton -> 1
    SecondaryButton -> 2
    SuccessButton -> 3
    DangerButton -> 4
    LinkButton -> 5
  }
}

fn text_input_style_to_int(s: TextInputStyle) -> Int {
  case s {
    ShortInput -> 1
    ParagraphInput -> 2
  }
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

fn float_to_string(f: Float) -> String {
  // Simple float to string conversion
  let int_part = float.truncate(f)
  let int_as_float = int.to_float(int_part)
  let frac = f -. int_as_float
  let frac_str = case frac == 0.0 {
    True -> ".0"
    False -> {
      // Multiply by 1000 and take integer part for 3 decimal places
      let frac_int = float.truncate(frac *. 1000.0)
      "." <> int.to_string(frac_int)
    }
  }
  int.to_string(int_part) <> frac_str
}

fn get_base_url(config: CommandsConfig) -> String {
  option.unwrap(config.base_url, api_base_url)
}

// ============================================================================
// Internal - JSON Parsing Helpers
// ============================================================================

fn json_decode_string_field(json_str: String, field: String) -> Option(String) {
  let pattern = "\"" <> field <> "\":\""
  case string.split_once(json_str, pattern) {
    Ok(#(_, rest)) -> {
      case string.split_once(rest, "\"") {
        Ok(#(value, _)) -> Some(value)
        Error(_) -> None
      }
    }
    Error(_) -> None
  }
}

/// Split JSON objects in array
fn split_json_objects(s: String) -> List(String) {
  do_split_objects(string.to_graphemes(s), 0, [], [])
}

fn do_split_objects(
  chars: List(String),
  depth: Int,
  current: List(String),
  result: List(String),
) -> List(String) {
  case chars {
    [] -> {
      case current {
        [] -> list.reverse(result)
        _ -> list.reverse([string.concat(list.reverse(current)), ..result])
      }
    }
    [",", ..rest] -> {
      case depth {
        0 -> {
          case current {
            [] -> do_split_objects(rest, 0, [], result)
            _ ->
              do_split_objects(rest, 0, [], [
                string.concat(list.reverse(current)),
                ..result
              ])
          }
        }
        _ -> do_split_objects(rest, depth, [",", ..current], result)
      }
    }
    ["{", ..rest] -> do_split_objects(rest, depth + 1, ["{", ..current], result)
    ["}", ..rest] -> do_split_objects(rest, depth - 1, ["}", ..current], result)
    ["[", ..rest] -> do_split_objects(rest, depth + 1, ["[", ..current], result)
    ["]", ..rest] -> do_split_objects(rest, depth - 1, ["]", ..current], result)
    [c, ..rest] -> do_split_objects(rest, depth, [c, ..current], result)
  }
}
