//// Discord Gateway Event Handling Module
//// Provides:
//// - Typed event parsing for MESSAGE_CREATE, MESSAGE_UPDATE, INTERACTION_CREATE
//// - Handler registration and dispatching
//// - Event filtering by guild, channel, and user
//// - Event logging for debugging
////
//// This module works with the Discord Gateway to process events.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

// ============================================================================
// Types - Discord Entities
// ============================================================================

/// Discord Snowflake ID
pub type Snowflake =
  String

/// Discord User
pub type User {
  User(
    id: Snowflake,
    username: String,
    discriminator: String,
    bot: Option(Bool),
    avatar: Option(String),
  )
}

/// Discord Member (Guild Member)
pub type Member {
  Member(
    user: Option(User),
    nick: Option(String),
    roles: List(Snowflake),
    joined_at: Option(String),
  )
}

/// Discord Channel
pub type ChannelType {
  GuildText
  Dm
  GuildVoice
  GroupDm
  GuildCategory
  GuildAnnouncement
  AnnouncementThread
  PublicThread
  PrivateThread
  GuildStageVoice
  GuildDirectory
  GuildForum
  GuildMedia
  UnknownChannelType(code: Int)
}

/// Discord Message
pub type Message {
  Message(
    id: Snowflake,
    channel_id: Snowflake,
    guild_id: Option(Snowflake),
    author: User,
    member: Option(Member),
    content: String,
    timestamp: String,
    edited_timestamp: Option(String),
    tts: Bool,
    mention_everyone: Bool,
    mentions: List(User),
    mention_roles: List(Snowflake),
    attachments: List(Attachment),
    embeds: List(Embed),
    reactions: List(Reaction),
    pinned: Bool,
    webhook_id: Option(Snowflake),
    message_reference: Option(MessageReference),
    flags: Option(Int),
  )
}

/// Message Attachment
pub type Attachment {
  Attachment(
    id: Snowflake,
    filename: String,
    description: Option(String),
    content_type: Option(String),
    size: Int,
    url: String,
    proxy_url: String,
  )
}

/// Message Embed
pub type Embed {
  Embed(
    title: Option(String),
    description: Option(String),
    url: Option(String),
    timestamp: Option(String),
    color: Option(Int),
  )
}

/// Message Reaction
pub type Reaction {
  Reaction(count: Int, me: Bool, emoji: Emoji)
}

/// Emoji
pub type Emoji {
  Emoji(id: Option(Snowflake), name: Option(String), animated: Option(Bool))
}

/// Message Reference (for replies)
pub type MessageReference {
  MessageReference(
    message_id: Option(Snowflake),
    channel_id: Option(Snowflake),
    guild_id: Option(Snowflake),
  )
}

// ============================================================================
// Types - Interactions
// ============================================================================

/// Discord Interaction
pub type Interaction {
  Interaction(
    id: Snowflake,
    application_id: Snowflake,
    interaction_type: InteractionType,
    data: Option(InteractionData),
    guild_id: Option(Snowflake),
    channel_id: Option(Snowflake),
    member: Option(Member),
    user: Option(User),
    token: String,
    version: Int,
    app_permissions: Option(String),
    locale: Option(String),
    guild_locale: Option(String),
    /// The message that held the button or menu (component interactions).
    message_id: Option(Snowflake),
  )
}

/// Interaction Type
pub type InteractionType {
  Ping
  ApplicationCommand
  MessageComponent
  ApplicationCommandAutocomplete
  ModalSubmit
  UnknownInteractionType(code: Int)
}

/// Interaction Data
pub type InteractionData {
  ApplicationCommandData(
    id: Snowflake,
    name: String,
    command_type: ApplicationCommandType,
    options: List(ApplicationCommandOption),
    resolved: Option(ResolvedData),
    target_id: Option(Snowflake),
  )
  MessageComponentData(
    custom_id: String,
    component_type: ComponentType,
    values: Option(List(String)),
    resolved: Option(ResolvedData),
  )
  ModalSubmitData(custom_id: String, components: List(ActionRow))
}

/// Application Command Type
pub type ApplicationCommandType {
  ChatInput
  UserCommand
  MessageCommand
  UnknownCommandType(code: Int)
}

/// Application Command Option
pub type ApplicationCommandOption {
  ApplicationCommandOption(
    name: String,
    option_type: ApplicationCommandOptionType,
    value: Option(CommandOptionValue),
    options: List(ApplicationCommandOption),
    focused: Option(Bool),
  )
}

/// Command Option Value
pub type CommandOptionValue {
  StringValue(value: String)
  IntValue(value: Int)
  BoolValue(value: Bool)
  UserValue(value: Snowflake)
  ChannelValue(value: Snowflake)
  RoleValue(value: Snowflake)
}

/// Application Command Option Type
pub type ApplicationCommandOptionType {
  SubCommand
  SubCommandGroup
  StringOption
  IntegerOption
  BooleanOption
  UserOption
  ChannelOption
  RoleOption
  MentionableOption
  NumberOption
  AttachmentOption
  UnknownOptionType(code: Int)
}

/// Component Type
pub type ComponentType {
  ActionRowType
  ButtonType
  StringSelectType
  TextInputType
  UserSelectType
  RoleSelectType
  MentionableSelectType
  ChannelSelectType
  UnknownComponentType(code: Int)
}

/// Action Row
pub type ActionRow {
  ActionRow(components: List(Component))
}

/// Component
pub type Component {
  Button(
    style: ButtonStyle,
    label: Option(String),
    emoji: Option(Emoji),
    custom_id: Option(String),
    url: Option(String),
    disabled: Option(Bool),
  )
  StringSelect(
    custom_id: String,
    options: List(SelectOption),
    placeholder: Option(String),
    min_values: Option(Int),
    max_values: Option(Int),
    disabled: Option(Bool),
  )
  TextInput(
    custom_id: String,
    style: Option(TextInputStyle),
    label: String,
    min_length: Option(Int),
    max_length: Option(Int),
    required: Option(Bool),
    value: Option(String),
    placeholder: Option(String),
  )
}

/// Button Style
pub type ButtonStyle {
  Primary
  Secondary
  Success
  Danger
  Link
  UnknownButtonStyle(code: Int)
}

/// Text Input Style
pub type TextInputStyle {
  Short
  Paragraph
  UnknownTextInputStyle(code: Int)
}

/// Select Option
pub type SelectOption {
  SelectOption(
    label: String,
    value: String,
    description: Option(String),
    emoji: Option(Emoji),
    default: Option(Bool),
  )
}

/// Resolved Data (contains entities referenced in interaction)
pub type ResolvedData {
  ResolvedData(
    users: Option(Dict(Snowflake, User)),
    members: Option(Dict(Snowflake, Member)),
    roles: Option(Dict(Snowflake, Role)),
    channels: Option(Dict(Snowflake, Channel)),
    messages: Option(Dict(Snowflake, Message)),
  )
}

/// Discord Role
pub type Role {
  Role(
    id: Snowflake,
    name: String,
    color: Int,
    hoist: Bool,
    position: Int,
    permissions: String,
    managed: Bool,
    mentionable: Bool,
  )
}

/// Discord Channel (minimal)
pub type Channel {
  Channel(
    id: Snowflake,
    channel_type: ChannelType,
    guild_id: Option(Snowflake),
    name: Option(String),
  )
}

// ============================================================================
// Types - Event Types
// ============================================================================

/// Parsed Discord event
pub type ParsedEvent {
  /// Message created event
  EventMessageCreate(message: Message)
  /// Message updated event
  EventMessageUpdate(
    id: Snowflake,
    channel_id: Snowflake,
    guild_id: Option(Snowflake),
    content: Option(String),
    edited_timestamp: Option(String),
    author: Option(User),
  )
  /// Message deleted event
  EventMessageDelete(
    id: Snowflake,
    channel_id: Snowflake,
    guild_id: Option(Snowflake),
  )
  /// Interaction created event
  EventInteractionCreate(interaction: Interaction)
  /// Reaction added event
  EventReactionAdd(
    user_id: Snowflake,
    channel_id: Snowflake,
    message_id: Snowflake,
    guild_id: Option(Snowflake),
    emoji: Emoji,
    member: Option(Member),
  )
  /// Reaction removed event
  EventReactionRemove(
    user_id: Snowflake,
    channel_id: Snowflake,
    message_id: Snowflake,
    guild_id: Option(Snowflake),
    emoji: Emoji,
  )
  /// Unknown/unparsed event
  EventUnknown(event_name: String, raw_data: String)
}

// ============================================================================
// Types - Event Filter
// ============================================================================

/// Event filter for filtering events by criteria
pub type EventFilter {
  EventFilter(
    /// Filter by guild ID
    guild_id: Option(Snowflake),
    /// Filter by channel ID
    channel_id: Option(Snowflake),
    /// Filter by user ID
    user_id: Option(Snowflake),
    /// Filter by event types
    event_types: Option(List(String)),
  )
}

/// Create an empty filter (matches all events)
pub fn new_filter() -> EventFilter {
  EventFilter(
    guild_id: None,
    channel_id: None,
    user_id: None,
    event_types: None,
  )
}

/// Add guild filter
pub fn filter_by_guild(
  filter: EventFilter,
  guild_id: Snowflake,
) -> EventFilter {
  EventFilter(..filter, guild_id: Some(guild_id))
}

/// Add channel filter
pub fn filter_by_channel(
  filter: EventFilter,
  channel_id: Snowflake,
) -> EventFilter {
  EventFilter(..filter, channel_id: Some(channel_id))
}

/// Add user filter
pub fn filter_by_user(filter: EventFilter, user_id: Snowflake) -> EventFilter {
  EventFilter(..filter, user_id: Some(user_id))
}

/// Add event type filter
pub fn filter_by_event_types(
  filter: EventFilter,
  event_types: List(String),
) -> EventFilter {
  EventFilter(..filter, event_types: Some(event_types))
}

/// Check if event matches filter
pub fn matches_filter(event: ParsedEvent, filter: EventFilter) -> Bool {
  let guild_match = case filter.guild_id {
    None -> True
    Some(guild_id) -> event_has_guild(event, guild_id)
  }

  let channel_match = case filter.channel_id {
    None -> True
    Some(channel_id) -> event_has_channel(event, channel_id)
  }

  let user_match = case filter.user_id {
    None -> True
    Some(user_id) -> event_has_user(event, user_id)
  }

  let type_match = case filter.event_types {
    None -> True
    Some(types) -> event_type_in_list(event, types)
  }

  guild_match && channel_match && user_match && type_match
}

/// Check if event involves a specific guild
fn event_has_guild(event: ParsedEvent, guild_id: Snowflake) -> Bool {
  case event {
    EventMessageCreate(msg) -> msg.guild_id == Some(guild_id)
    EventMessageUpdate(_, _, guild, _, _, _) -> guild == Some(guild_id)
    EventMessageDelete(_, _, guild) -> guild == Some(guild_id)
    EventInteractionCreate(inter) -> inter.guild_id == Some(guild_id)
    EventReactionAdd(_, _, _, guild, _, _) -> guild == Some(guild_id)
    EventReactionRemove(_, _, _, guild, _) -> guild == Some(guild_id)
    EventUnknown(_, _) -> False
  }
}

/// Check if event involves a specific channel
fn event_has_channel(event: ParsedEvent, channel_id: Snowflake) -> Bool {
  case event {
    EventMessageCreate(msg) -> msg.channel_id == channel_id
    EventMessageUpdate(_, ch, _, _, _, _) -> ch == channel_id
    EventMessageDelete(_, ch, _) -> ch == channel_id
    EventInteractionCreate(inter) -> inter.channel_id == Some(channel_id)
    EventReactionAdd(_, ch, _, _, _, _) -> ch == channel_id
    EventReactionRemove(_, ch, _, _, _) -> ch == channel_id
    EventUnknown(_, _) -> False
  }
}

/// Check if event involves a specific user
fn event_has_user(event: ParsedEvent, user_id: Snowflake) -> Bool {
  case event {
    EventMessageCreate(msg) -> msg.author.id == user_id
    EventMessageUpdate(_, _, _, _, _, Some(author)) -> author.id == user_id
    EventMessageUpdate(_, _, _, _, _, None) -> False
    EventMessageDelete(_, _, _) -> False
    EventInteractionCreate(inter) -> {
      case inter.user, inter.member {
        Some(user), _ -> user.id == user_id
        _, Some(member) -> {
          case member.user {
            Some(user) -> user.id == user_id
            None -> False
          }
        }
        _, _ -> False
      }
    }
    EventReactionAdd(user, _, _, _, _, _) -> user == user_id
    EventReactionRemove(user, _, _, _, _) -> user == user_id
    EventUnknown(_, _) -> False
  }
}

/// Check if event type is in list
fn event_type_in_list(event: ParsedEvent, types: List(String)) -> Bool {
  let event_name = event_to_type_name(event)
  list.contains(types, event_name)
}

/// Get event type name
pub fn event_to_type_name(event: ParsedEvent) -> String {
  case event {
    EventMessageCreate(_) -> "MESSAGE_CREATE"
    EventMessageUpdate(_, _, _, _, _, _) -> "MESSAGE_UPDATE"
    EventMessageDelete(_, _, _) -> "MESSAGE_DELETE"
    EventInteractionCreate(_) -> "INTERACTION_CREATE"
    EventReactionAdd(_, _, _, _, _, _) -> "MESSAGE_REACTION_ADD"
    EventReactionRemove(_, _, _, _, _) -> "MESSAGE_REACTION_REMOVE"
    EventUnknown(name, _) -> name
  }
}

// ============================================================================
// Types - Event Handler
// ============================================================================

/// Event handler function type
pub type EventHandler =
  fn(ParsedEvent) -> Nil

/// Registered handler entry
pub type HandlerEntry {
  HandlerEntry(id: Int, handler: EventHandler, filter: EventFilter)
}

/// Event dispatcher state
pub type DispatcherState {
  DispatcherState(
    handlers: Dict(Int, HandlerEntry),
    handler_counter: Int,
    log_events: Bool,
  )
}

/// Dispatcher messages
pub type DispatcherMessage {
  /// Register a new handler
  RegisterHandler(
    reply_to: Subject(Int),
    handler: EventHandler,
    filter: EventFilter,
  )
  /// Unregister a handler
  UnregisterHandler(reply_to: Subject(Bool), handler_id: Int)
  /// Dispatch an event to handlers
  DispatchEvent(event: ParsedEvent)
  /// Set logging enabled
  SetLogging(reply_to: Subject(Nil), enabled: Bool)
  /// Get handler count
  GetHandlerCount(reply_to: Subject(Int))
  /// Stop the dispatcher
  StopDispatcher(reply_to: Subject(Nil))
}

/// Event dispatcher handle
pub type EventDispatcher =
  Subject(DispatcherMessage)

// ============================================================================
// Event Dispatcher Actor
// ============================================================================

/// Start an event dispatcher
pub fn start_dispatcher() -> Result(EventDispatcher, actor.StartError) {
  let initial_state =
    DispatcherState(handlers: dict.new(), handler_counter: 0, log_events: False)

  case
    actor.new(initial_state)
    |> actor.on_message(handle_dispatcher_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Handle dispatcher messages
fn handle_dispatcher_message(
  state: DispatcherState,
  message: DispatcherMessage,
) -> actor.Next(DispatcherState, DispatcherMessage) {
  case message {
    RegisterHandler(reply_to, handler, filter) -> {
      let handler_id = state.handler_counter + 1
      let entry = HandlerEntry(id: handler_id, handler: handler, filter: filter)
      let new_handlers = dict.insert(state.handlers, handler_id, entry)

      actor.send(reply_to, handler_id)
      actor.continue(
        DispatcherState(
          ..state,
          handlers: new_handlers,
          handler_counter: handler_id,
        ),
      )
    }

    UnregisterHandler(reply_to, handler_id) -> {
      case dict.get(state.handlers, handler_id) {
        Ok(_) -> {
          let new_handlers = dict.delete(state.handlers, handler_id)
          actor.send(reply_to, True)
          actor.continue(DispatcherState(..state, handlers: new_handlers))
        }
        Error(_) -> {
          actor.send(reply_to, False)
          actor.continue(state)
        }
      }
    }

    DispatchEvent(event) -> {
      // Log event if enabled
      let _ = case state.log_events {
        True -> log_event(event)
        False -> Nil
      }

      // Dispatch to matching handlers
      state.handlers
      |> dict.values()
      |> list.each(fn(entry) {
        case matches_filter(event, entry.filter) {
          True -> entry.handler(event)
          False -> Nil
        }
      })

      actor.continue(state)
    }

    SetLogging(reply_to, enabled) -> {
      actor.send(reply_to, Nil)
      actor.continue(DispatcherState(..state, log_events: enabled))
    }

    GetHandlerCount(reply_to) -> {
      actor.send(reply_to, dict.size(state.handlers))
      actor.continue(state)
    }

    StopDispatcher(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Event Dispatcher Public API
// ============================================================================

/// Register an event handler
pub fn register_handler(
  dispatcher: EventDispatcher,
  handler: EventHandler,
) -> Int {
  actor.call(dispatcher, waiting: 5000, sending: RegisterHandler(
    _,
    handler,
    new_filter(),
  ))
}

/// Register an event handler with filter
pub fn register_handler_with_filter(
  dispatcher: EventDispatcher,
  handler: EventHandler,
  filter: EventFilter,
) -> Int {
  actor.call(dispatcher, waiting: 5000, sending: RegisterHandler(
    _,
    handler,
    filter,
  ))
}

/// Unregister an event handler
pub fn unregister_handler(
  dispatcher: EventDispatcher,
  handler_id: Int,
) -> Bool {
  actor.call(dispatcher, waiting: 5000, sending: UnregisterHandler(
    _,
    handler_id,
  ))
}

/// Dispatch an event to all matching handlers
pub fn dispatch(dispatcher: EventDispatcher, event: ParsedEvent) -> Nil {
  actor.send(dispatcher, DispatchEvent(event))
}

/// Enable or disable event logging
pub fn set_logging(dispatcher: EventDispatcher, enabled: Bool) -> Nil {
  actor.call(dispatcher, waiting: 5000, sending: SetLogging(_, enabled))
}

/// Get number of registered handlers
pub fn handler_count(dispatcher: EventDispatcher) -> Int {
  actor.call(dispatcher, waiting: 5000, sending: GetHandlerCount)
}

/// Stop the dispatcher
pub fn stop_dispatcher(dispatcher: EventDispatcher) -> Nil {
  actor.call(dispatcher, waiting: 5000, sending: StopDispatcher)
}

// ============================================================================
// Event Logging
// ============================================================================

/// Log an event for debugging
fn log_event(event: ParsedEvent) -> Nil {
  let log_line = format_event_for_log(event)
  // In production, this would use a proper logging library
  let _ = log_line
  Nil
}

/// Format event for logging
pub fn format_event_for_log(event: ParsedEvent) -> String {
  let event_type = event_to_type_name(event)
  let details = case event {
    EventMessageCreate(msg) ->
      "id="
      <> msg.id
      <> " channel="
      <> msg.channel_id
      <> " author="
      <> msg.author.id
    EventMessageUpdate(id, ch, guild, _, _, author) -> {
      let guild_str = case guild {
        Some(g) -> " guild=" <> g
        None -> ""
      }
      let author_str = case author {
        Some(a) -> " author=" <> a.id
        None -> ""
      }
      "id=" <> id <> " channel=" <> ch <> guild_str <> author_str
    }
    EventMessageDelete(id, ch, guild) -> {
      let guild_str = case guild {
        Some(g) -> " guild=" <> g
        None -> ""
      }
      "id=" <> id <> " channel=" <> ch <> guild_str
    }
    EventInteractionCreate(inter) -> {
      let guild_str = case inter.guild_id {
        Some(g) -> " guild=" <> g
        None -> ""
      }
      "id="
      <> inter.id
      <> guild_str
      <> " type="
      <> interaction_type_to_string(inter.interaction_type)
    }
    EventReactionAdd(user, ch, msg, guild, emoji, _) -> {
      let guild_str = case guild {
        Some(g) -> " guild=" <> g
        None -> ""
      }
      let emoji_str = case emoji.name {
        Some(n) -> n
        None -> "unknown"
      }
      "user="
      <> user
      <> " channel="
      <> ch
      <> " message="
      <> msg
      <> guild_str
      <> " emoji="
      <> emoji_str
    }
    EventReactionRemove(user, ch, msg, guild, emoji) -> {
      let guild_str = case guild {
        Some(g) -> " guild=" <> g
        None -> ""
      }
      let emoji_str = case emoji.name {
        Some(n) -> n
        None -> "unknown"
      }
      "user="
      <> user
      <> " channel="
      <> ch
      <> " message="
      <> msg
      <> guild_str
      <> " emoji="
      <> emoji_str
    }
    EventUnknown(_, raw) -> "raw_data=" <> string.slice(raw, 0, 100)
  }

  "[Discord Event] " <> event_type <> " " <> details
}

/// Convert interaction type to string
pub fn interaction_type_to_string(t: InteractionType) -> String {
  case t {
    Ping -> "Ping"
    ApplicationCommand -> "ApplicationCommand"
    MessageComponent -> "MessageComponent"
    ApplicationCommandAutocomplete -> "ApplicationCommandAutocomplete"
    ModalSubmit -> "ModalSubmit"
    UnknownInteractionType(code) -> "Unknown(" <> int.to_string(code) <> ")"
  }
}

// ============================================================================
// Event Parsing
// ============================================================================

pub fn parse_event(event_name: String, raw_data: String) -> ParsedEvent {
  let parsed = case event_name {
    "MESSAGE_CREATE" ->
      json.parse(raw_data, message_decoder()) |> result.map(EventMessageCreate)
    "MESSAGE_UPDATE" -> json.parse(raw_data, message_update_decoder())
    "MESSAGE_DELETE" -> json.parse(raw_data, message_delete_decoder())
    "INTERACTION_CREATE" ->
      json.parse(raw_data, interaction_decoder())
      |> result.map(EventInteractionCreate)
    "MESSAGE_REACTION_ADD" -> json.parse(raw_data, reaction_add_decoder())
    "MESSAGE_REACTION_REMOVE" -> json.parse(raw_data, reaction_remove_decoder())
    _ -> Error(json.UnexpectedEndOfInput)
  }
  case parsed {
    Ok(event) -> event
    Error(_) -> EventUnknown(event_name, raw_data)
  }
}

/// Parse a MESSAGE_CREATE payload.
pub fn parse_message(data: String) -> Result(Message, Nil) {
  json.parse(data, message_decoder()) |> result.replace_error(Nil)
}

/// Parse an INTERACTION_CREATE payload.
pub fn parse_interaction(data: String) -> Result(Interaction, Nil) {
  json.parse(data, interaction_decoder()) |> result.replace_error(Nil)
}

// ============================================================================
// Decoders
// ============================================================================

/// A field that may be missing or `null`.
fn optional(
  name: String,
  inner: decode.Decoder(a),
  next: fn(Option(a)) -> decode.Decoder(b),
) -> decode.Decoder(b) {
  decode.optional_field(name, None, decode.optional(inner), next)
}

/// A field that may be missing or `null`, with a default.
fn with_default(
  name: String,
  default: a,
  inner: decode.Decoder(a),
  next: fn(a) -> decode.Decoder(b),
) -> decode.Decoder(b) {
  use value <- optional(name, inner)
  next(option.unwrap(value, default))
}

fn user_decoder() -> decode.Decoder(User) {
  use id <- decode.field("id", decode.string)
  use username <- with_default("username", "unknown", decode.string)
  use discriminator <- with_default("discriminator", "0000", decode.string)
  use bot <- optional("bot", decode.bool)
  use avatar <- optional("avatar", decode.string)
  decode.success(User(
    id: id,
    username: username,
    discriminator: discriminator,
    bot: bot,
    avatar: avatar,
  ))
}

fn member_decoder() -> decode.Decoder(Member) {
  use user <- optional("user", user_decoder())
  use nick <- optional("nick", decode.string)
  use roles <- with_default("roles", [], decode.list(decode.string))
  use joined_at <- optional("joined_at", decode.string)
  decode.success(Member(
    user: user,
    nick: nick,
    roles: roles,
    joined_at: joined_at,
  ))
}

fn emoji_decoder() -> decode.Decoder(Emoji) {
  use id <- optional("id", decode.string)
  use name <- optional("name", decode.string)
  use animated <- optional("animated", decode.bool)
  decode.success(Emoji(id: id, name: name, animated: animated))
}

fn attachment_decoder() -> decode.Decoder(Attachment) {
  use id <- decode.field("id", decode.string)
  use filename <- with_default("filename", "", decode.string)
  use description <- optional("description", decode.string)
  use content_type <- optional("content_type", decode.string)
  use size <- with_default("size", 0, decode.int)
  use url <- with_default("url", "", decode.string)
  use proxy_url <- with_default("proxy_url", "", decode.string)
  decode.success(Attachment(
    id: id,
    filename: filename,
    description: description,
    content_type: content_type,
    size: size,
    url: url,
    proxy_url: proxy_url,
  ))
}

fn message_reference_decoder() -> decode.Decoder(MessageReference) {
  use message_id <- optional("message_id", decode.string)
  use channel_id <- optional("channel_id", decode.string)
  use guild_id <- optional("guild_id", decode.string)
  decode.success(MessageReference(
    message_id: message_id,
    channel_id: channel_id,
    guild_id: guild_id,
  ))
}

fn message_decoder() -> decode.Decoder(Message) {
  use id <- decode.field("id", decode.string)
  use channel_id <- decode.field("channel_id", decode.string)
  use guild_id <- optional("guild_id", decode.string)
  use author <- decode.field("author", user_decoder())
  use member <- optional("member", member_decoder())
  // Always sent; empty when the Message Content intent is missing.
  use content <- decode.field("content", decode.string)
  use timestamp <- decode.field("timestamp", decode.string)
  use edited_timestamp <- optional("edited_timestamp", decode.string)
  use tts <- with_default("tts", False, decode.bool)
  use mention_everyone <- with_default("mention_everyone", False, decode.bool)
  use mentions <- with_default("mentions", [], decode.list(user_decoder()))
  use mention_roles <- with_default(
    "mention_roles",
    [],
    decode.list(decode.string),
  )
  use attachments <- with_default(
    "attachments",
    [],
    decode.list(attachment_decoder()),
  )
  use pinned <- with_default("pinned", False, decode.bool)
  use webhook_id <- optional("webhook_id", decode.string)
  use message_reference <- optional(
    "message_reference",
    message_reference_decoder(),
  )
  use flags <- optional("flags", decode.int)
  decode.success(Message(
    id: id,
    channel_id: channel_id,
    guild_id: guild_id,
    author: author,
    member: member,
    content: content,
    timestamp: timestamp,
    edited_timestamp: edited_timestamp,
    tts: tts,
    mention_everyone: mention_everyone,
    mentions: mentions,
    mention_roles: mention_roles,
    attachments: attachments,
    embeds: [],
    reactions: [],
    pinned: pinned,
    webhook_id: webhook_id,
    message_reference: message_reference,
    flags: flags,
  ))
}

fn message_update_decoder() -> decode.Decoder(ParsedEvent) {
  use id <- decode.field("id", decode.string)
  use channel_id <- decode.field("channel_id", decode.string)
  use guild_id <- optional("guild_id", decode.string)
  use content <- optional("content", decode.string)
  use edited_timestamp <- optional("edited_timestamp", decode.string)
  use author <- optional("author", user_decoder())
  decode.success(EventMessageUpdate(
    id: id,
    channel_id: channel_id,
    guild_id: guild_id,
    content: content,
    edited_timestamp: edited_timestamp,
    author: author,
  ))
}

fn message_delete_decoder() -> decode.Decoder(ParsedEvent) {
  use id <- decode.field("id", decode.string)
  use channel_id <- decode.field("channel_id", decode.string)
  use guild_id <- optional("guild_id", decode.string)
  decode.success(EventMessageDelete(
    id: id,
    channel_id: channel_id,
    guild_id: guild_id,
  ))
}

fn reaction_add_decoder() -> decode.Decoder(ParsedEvent) {
  use user_id <- decode.field("user_id", decode.string)
  use channel_id <- decode.field("channel_id", decode.string)
  use message_id <- decode.field("message_id", decode.string)
  use guild_id <- optional("guild_id", decode.string)
  use emoji <- decode.field("emoji", emoji_decoder())
  use member <- optional("member", member_decoder())
  decode.success(EventReactionAdd(
    user_id: user_id,
    channel_id: channel_id,
    message_id: message_id,
    guild_id: guild_id,
    emoji: emoji,
    member: member,
  ))
}

fn reaction_remove_decoder() -> decode.Decoder(ParsedEvent) {
  use user_id <- decode.field("user_id", decode.string)
  use channel_id <- decode.field("channel_id", decode.string)
  use message_id <- decode.field("message_id", decode.string)
  use guild_id <- optional("guild_id", decode.string)
  use emoji <- decode.field("emoji", emoji_decoder())
  decode.success(EventReactionRemove(
    user_id: user_id,
    channel_id: channel_id,
    message_id: message_id,
    guild_id: guild_id,
    emoji: emoji,
  ))
}

fn interaction_decoder() -> decode.Decoder(Interaction) {
  use id <- decode.field("id", decode.string)
  use application_id <- decode.field("application_id", decode.string)
  use type_code <- decode.field("type", decode.int)
  let interaction_type = int_to_interaction_type(type_code)
  use data <- optional("data", interaction_data_decoder(interaction_type))
  use guild_id <- optional("guild_id", decode.string)
  use channel_id <- optional("channel_id", decode.string)
  use member <- optional("member", member_decoder())
  use user <- optional("user", user_decoder())
  use token <- decode.field("token", decode.string)
  use version <- with_default("version", 1, decode.int)
  use app_permissions <- optional("app_permissions", decode.string)
  use locale <- optional("locale", decode.string)
  use guild_locale <- optional("guild_locale", decode.string)
  use message_id <- optional("message", decode.at(["id"], decode.string))
  decode.success(Interaction(
    id: id,
    application_id: application_id,
    interaction_type: interaction_type,
    data: option.flatten(data),
    guild_id: guild_id,
    channel_id: channel_id,
    member: member,
    user: user,
    token: token,
    version: version,
    app_permissions: app_permissions,
    locale: locale,
    guild_locale: guild_locale,
    message_id: message_id,
  ))
}

fn interaction_data_decoder(
  interaction_type: InteractionType,
) -> decode.Decoder(Option(InteractionData)) {
  case interaction_type {
    ApplicationCommand | ApplicationCommandAutocomplete -> {
      use id <- with_default("id", "unknown", decode.string)
      use name <- with_default("name", "unknown", decode.string)
      use command_type <- with_default("type", 1, decode.int)
      use options <- with_default(
        "options",
        [],
        decode.list(command_option_decoder()),
      )
      use target_id <- optional("target_id", decode.string)
      decode.success(
        Some(ApplicationCommandData(
          id: id,
          name: name,
          command_type: int_to_command_type(command_type),
          options: options,
          resolved: None,
          target_id: target_id,
        )),
      )
    }
    MessageComponent -> {
      use custom_id <- with_default("custom_id", "unknown", decode.string)
      use component_type <- with_default("component_type", 2, decode.int)
      use values <- optional("values", decode.list(decode.string))
      decode.success(
        Some(MessageComponentData(
          custom_id: custom_id,
          component_type: int_to_component_type(component_type),
          values: case values {
            Some([]) -> None
            other -> other
          },
          resolved: None,
        )),
      )
    }
    ModalSubmit -> {
      use custom_id <- with_default("custom_id", "unknown", decode.string)
      decode.success(
        Some(ModalSubmitData(custom_id: custom_id, components: [])),
      )
    }
    _ -> decode.success(None)
  }
}

fn command_option_decoder() -> decode.Decoder(ApplicationCommandOption) {
  use name <- with_default("name", "unknown", decode.string)
  use type_code <- with_default("type", 3, decode.int)
  let option_type = int_to_option_type(type_code)
  use value <- optional("value", option_value_decoder(option_type))
  use options <- with_default(
    "options",
    [],
    decode.list(decode.recursive(command_option_decoder)),
  )
  use focused <- optional("focused", decode.bool)
  decode.success(ApplicationCommandOption(
    name: name,
    option_type: option_type,
    value: option.flatten(value),
    options: options,
    focused: focused,
  ))
}

fn option_value_decoder(
  option_type: ApplicationCommandOptionType,
) -> decode.Decoder(Option(CommandOptionValue)) {
  case option_type {
    StringOption -> decode.map(decode.string, fn(v) { Some(StringValue(v)) })
    IntegerOption -> decode.map(decode.int, fn(v) { Some(IntValue(v)) })
    BooleanOption -> decode.map(decode.bool, fn(v) { Some(BoolValue(v)) })
    UserOption -> decode.map(decode.string, fn(v) { Some(UserValue(v)) })
    ChannelOption -> decode.map(decode.string, fn(v) { Some(ChannelValue(v)) })
    RoleOption -> decode.map(decode.string, fn(v) { Some(RoleValue(v)) })
    _ -> decode.success(None)
  }
}

// ============================================================================
// Type Conversion Helpers
// ============================================================================

/// Convert int to interaction type
fn int_to_interaction_type(code: Int) -> InteractionType {
  case code {
    1 -> Ping
    2 -> ApplicationCommand
    3 -> MessageComponent
    4 -> ApplicationCommandAutocomplete
    5 -> ModalSubmit
    _ -> UnknownInteractionType(code)
  }
}

/// Convert int to application command type
fn int_to_command_type(code: Int) -> ApplicationCommandType {
  case code {
    1 -> ChatInput
    2 -> UserCommand
    3 -> MessageCommand
    _ -> UnknownCommandType(code)
  }
}

/// Convert int to option type
fn int_to_option_type(code: Int) -> ApplicationCommandOptionType {
  case code {
    1 -> SubCommand
    2 -> SubCommandGroup
    3 -> StringOption
    4 -> IntegerOption
    5 -> BooleanOption
    6 -> UserOption
    7 -> ChannelOption
    8 -> RoleOption
    9 -> MentionableOption
    10 -> NumberOption
    11 -> AttachmentOption
    _ -> UnknownOptionType(code)
  }
}

fn int_to_component_type(code: Int) -> ComponentType {
  case code {
    1 -> ActionRowType
    2 -> ButtonType
    3 -> StringSelectType
    4 -> TextInputType
    5 -> UserSelectType
    6 -> RoleSelectType
    7 -> MentionableSelectType
    8 -> ChannelSelectType
    _ -> UnknownComponentType(code)
  }
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Check if event is a message event
pub fn is_message_event(event: ParsedEvent) -> Bool {
  case event {
    EventMessageCreate(_) -> True
    EventMessageUpdate(_, _, _, _, _, _) -> True
    EventMessageDelete(_, _, _) -> True
    _ -> False
  }
}

/// Check if event is an interaction event
pub fn is_interaction_event(event: ParsedEvent) -> Bool {
  case event {
    EventInteractionCreate(_) -> True
    _ -> False
  }
}

/// Check if event is a reaction event
pub fn is_reaction_event(event: ParsedEvent) -> Bool {
  case event {
    EventReactionAdd(_, _, _, _, _, _) -> True
    EventReactionRemove(_, _, _, _, _) -> True
    _ -> False
  }
}

/// Get message from event if applicable
pub fn get_message(event: ParsedEvent) -> Option(Message) {
  case event {
    EventMessageCreate(msg) -> Some(msg)
    _ -> None
  }
}

/// Get interaction from event if applicable
pub fn get_interaction(event: ParsedEvent) -> Option(Interaction) {
  case event {
    EventInteractionCreate(inter) -> Some(inter)
    _ -> None
  }
}
