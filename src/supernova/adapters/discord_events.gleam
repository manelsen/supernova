//// Discord Gateway Event Handling Module
//// Provides:
//// - Typed event parsing for MESSAGE_CREATE, MESSAGE_UPDATE, INTERACTION_CREATE
//// - Handler registration and dispatching
//// - Event filtering by guild, channel, and user
//// - Event logging for debugging
////
//// This module works with the Discord Gateway to process events.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
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
pub fn filter_by_guild(filter: EventFilter, guild_id: Snowflake) -> EventFilter {
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
pub fn unregister_handler(dispatcher: EventDispatcher, handler_id: Int) -> Bool {
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

/// Parse a Discord event from raw JSON
pub fn parse_event(event_name: String, raw_data: String) -> ParsedEvent {
  case event_name {
    "MESSAGE_CREATE" -> {
      case parse_message(raw_data) {
        Ok(msg) -> EventMessageCreate(msg)
        Error(_) -> EventUnknown(event_name, raw_data)
      }
    }
    "MESSAGE_UPDATE" -> parse_message_update(raw_data)
    "MESSAGE_DELETE" -> parse_message_delete(raw_data)
    "INTERACTION_CREATE" -> {
      case parse_interaction(raw_data) {
        Ok(inter) -> EventInteractionCreate(inter)
        Error(_) -> EventUnknown(event_name, raw_data)
      }
    }
    "MESSAGE_REACTION_ADD" -> parse_reaction_add(raw_data)
    "MESSAGE_REACTION_REMOVE" -> parse_reaction_remove(raw_data)
    _ -> EventUnknown(event_name, raw_data)
  }
}

/// Parse a MESSAGE_CREATE event
pub fn parse_message(data: String) -> Result(Message, Nil) {
  case
    json_decode_string_field(data, "id"),
    json_decode_string_field(data, "channel_id"),
    json_decode_string_field(data, "content"),
    json_decode_string_field(data, "timestamp")
  {
    Some(id), Some(channel_id), Some(content), Some(timestamp) -> {
      let author_data = json_decode_object_field(data, "author")
      let author = parse_user(author_data)

      Ok(Message(
        id: id,
        channel_id: channel_id,
        guild_id: json_decode_string_field(data, "guild_id"),
        author: author,
        member: parse_optional_member(data),
        content: content,
        timestamp: timestamp,
        edited_timestamp: json_decode_string_field(data, "edited_timestamp"),
        tts: json_decode_bool_field(data, "tts") |> option.unwrap(False),
        mention_everyone: json_decode_bool_field(data, "mention_everyone")
          |> option.unwrap(False),
        mentions: parse_mentions(data),
        mention_roles: parse_mention_roles(data),
        attachments: [],
        embeds: [],
        reactions: [],
        pinned: json_decode_bool_field(data, "pinned") |> option.unwrap(False),
        webhook_id: json_decode_string_field(data, "webhook_id"),
        message_reference: parse_message_reference(data),
        flags: json_decode_int_field(data, "flags"),
      ))
    }
    _, _, _, _ -> Error(Nil)
  }
}

/// Parse a MESSAGE_UPDATE event (partial message data)
fn parse_message_update(data: String) -> ParsedEvent {
  let id = json_decode_string_field(data, "id") |> option.unwrap("unknown")
  let channel_id =
    json_decode_string_field(data, "channel_id") |> option.unwrap("unknown")
  let guild_id = json_decode_string_field(data, "guild_id")
  let content = json_decode_string_field(data, "content")
  let edited_timestamp = json_decode_string_field(data, "edited_timestamp")

  let author = case json_decode_string_field(data, "author") {
    Some(_) -> {
      let author_data = json_decode_object_field(data, "author")
      Some(parse_user(author_data))
    }
    None -> None
  }

  EventMessageUpdate(
    id: id,
    channel_id: channel_id,
    guild_id: guild_id,
    content: content,
    edited_timestamp: edited_timestamp,
    author: author,
  )
}

/// Parse a MESSAGE_DELETE event
fn parse_message_delete(data: String) -> ParsedEvent {
  let id = json_decode_string_field(data, "id") |> option.unwrap("unknown")
  let channel_id =
    json_decode_string_field(data, "channel_id") |> option.unwrap("unknown")
  let guild_id = json_decode_string_field(data, "guild_id")

  EventMessageDelete(id: id, channel_id: channel_id, guild_id: guild_id)
}

/// Parse an INTERACTION_CREATE event
pub fn parse_interaction(data: String) -> Result(Interaction, Nil) {
  case
    json_decode_string_field(data, "id"),
    json_decode_string_field(data, "application_id"),
    json_decode_int_field(data, "type"),
    json_decode_string_field(data, "token")
  {
    Some(id), Some(app_id), Some(type_code), Some(token) -> {
      let interaction_type = int_to_interaction_type(type_code)

      Ok(Interaction(
        id: id,
        application_id: app_id,
        interaction_type: interaction_type,
        data: parse_interaction_data(data),
        guild_id: json_decode_string_field(data, "guild_id"),
        channel_id: json_decode_string_field(data, "channel_id"),
        member: parse_optional_member(data),
        user: parse_optional_user(data),
        token: token,
        version: json_decode_int_field(data, "version") |> option.unwrap(1),
        app_permissions: json_decode_string_field(data, "app_permissions"),
        locale: json_decode_string_field(data, "locale"),
        guild_locale: json_decode_string_field(data, "guild_locale"),
      ))
    }
    _, _, _, _ -> Error(Nil)
  }
}

/// Parse a reaction add event
fn parse_reaction_add(data: String) -> ParsedEvent {
  let user_id =
    json_decode_string_field(data, "user_id") |> option.unwrap("unknown")
  let channel_id =
    json_decode_string_field(data, "channel_id") |> option.unwrap("unknown")
  let message_id =
    json_decode_string_field(data, "message_id") |> option.unwrap("unknown")
  let guild_id = json_decode_string_field(data, "guild_id")
  let emoji_data = json_decode_object_field(data, "emoji")
  let emoji = parse_emoji(emoji_data)
  let member = parse_optional_member(data)

  EventReactionAdd(
    user_id: user_id,
    channel_id: channel_id,
    message_id: message_id,
    guild_id: guild_id,
    emoji: emoji,
    member: member,
  )
}

/// Parse a reaction remove event
fn parse_reaction_remove(data: String) -> ParsedEvent {
  let user_id =
    json_decode_string_field(data, "user_id") |> option.unwrap("unknown")
  let channel_id =
    json_decode_string_field(data, "channel_id") |> option.unwrap("unknown")
  let message_id =
    json_decode_string_field(data, "message_id") |> option.unwrap("unknown")
  let guild_id = json_decode_string_field(data, "guild_id")
  let emoji_data = json_decode_object_field(data, "emoji")
  let emoji = parse_emoji(emoji_data)

  EventReactionRemove(
    user_id: user_id,
    channel_id: channel_id,
    message_id: message_id,
    guild_id: guild_id,
    emoji: emoji,
  )
}

// ============================================================================
// Entity Parsing Helpers
// ============================================================================

/// Parse user from JSON
fn parse_user(data: String) -> User {
  User(
    id: json_decode_string_field(data, "id") |> option.unwrap("unknown"),
    username: json_decode_string_field(data, "username")
      |> option.unwrap("unknown"),
    discriminator: json_decode_string_field(data, "discriminator")
      |> option.unwrap("0000"),
    bot: json_decode_bool_field(data, "bot"),
    avatar: json_decode_string_field(data, "avatar"),
  )
}

/// Parse optional user from data
fn parse_optional_user(data: String) -> Option(User) {
  let user_data = json_decode_object_field(data, "user")
  case string.is_empty(user_data) {
    True -> None
    False -> Some(parse_user(user_data))
  }
}

/// Parse optional member from data
fn parse_optional_member(data: String) -> Option(Member) {
  let member_data = json_decode_object_field(data, "member")
  case string.is_empty(member_data) || member_data == "{}" {
    True -> None
    False -> Some(parse_member(member_data))
  }
}

/// Parse member from JSON
fn parse_member(data: String) -> Member {
  let user_data = json_decode_object_field(data, "user")
  Member(
    user: case string.is_empty(user_data) {
      True -> None
      False -> Some(parse_user(user_data))
    },
    nick: json_decode_string_field(data, "nick"),
    roles: parse_string_list_field(data, "roles"),
    joined_at: json_decode_string_field(data, "joined_at"),
  )
}

/// Parse emoji from JSON
fn parse_emoji(data: String) -> Emoji {
  Emoji(
    id: json_decode_string_field(data, "id"),
    name: json_decode_string_field(data, "name"),
    animated: json_decode_bool_field(data, "animated"),
  )
}

/// Parse message reference
fn parse_message_reference(data: String) -> Option(MessageReference) {
  let ref_data = json_decode_object_field(data, "message_reference")
  case string.is_empty(ref_data) || ref_data == "{}" {
    True -> None
    False ->
      Some(MessageReference(
        message_id: json_decode_string_field(ref_data, "message_id"),
        channel_id: json_decode_string_field(ref_data, "channel_id"),
        guild_id: json_decode_string_field(ref_data, "guild_id"),
      ))
  }
}

/// Parse mentions list
fn parse_mentions(data: String) -> List(User) {
  let mentions_data = json_decode_array_field(data, "mentions")
  parse_user_list(mentions_data)
}

/// Parse list of users from array string
fn parse_user_list(data: String) -> List(User) {
  // Simple array parsing - split by }, { and parse each
  case string.starts_with(data, "[") {
    True -> {
      let inner = string.drop_start(data, 1)
      let inner = string.drop_end(inner, 1)
      case string.is_empty(inner) {
        True -> []
        False -> {
          // Split by },{ for rough object boundaries
          let parts = string.split(inner, "},{")
          parts
          |> list.map(fn(part) {
            let part = case string.starts_with(part, "{") {
              True -> part
              False -> "{" <> part
            }
            let part = case string.ends_with(part, "}") {
              True -> part
              False -> part <> "}"
            }
            parse_user(part)
          })
        }
      }
    }
    False -> []
  }
}

/// Parse mention roles list
fn parse_mention_roles(data: String) -> List(Snowflake) {
  parse_string_list_field(data, "mention_roles")
}

/// Parse string list field
fn parse_string_list_field(data: String, field: String) -> List(String) {
  let array_data = json_decode_array_field(data, field)
  case string.starts_with(array_data, "[") {
    True -> {
      let inner = string.drop_start(array_data, 1)
      let inner = string.drop_end(inner, 1)
      case string.is_empty(inner) {
        True -> []
        False -> {
          inner
          |> string.split(",")
          |> list.map(fn(s) {
            s
            |> string.trim()
            |> string.replace("\"", "")
          })
          |> list.filter(fn(s) { !string.is_empty(s) })
        }
      }
    }
    False -> []
  }
}

/// Parse interaction data
fn parse_interaction_data(data: String) -> Option(InteractionData) {
  let int_data = json_decode_object_field(data, "data")
  case string.is_empty(int_data) || int_data == "{}" {
    True -> None
    False -> {
      case json_decode_int_field(int_data, "type") {
        Some(2) | Some(3) | Some(4) -> {
          // Application command
          Some(ApplicationCommandData(
            id: json_decode_string_field(int_data, "id")
              |> option.unwrap("unknown"),
            name: json_decode_string_field(int_data, "name")
              |> option.unwrap("unknown"),
            command_type: int_to_command_type(
              json_decode_int_field(int_data, "type") |> option.unwrap(1),
            ),
            options: parse_command_options(int_data),
            resolved: None,
            target_id: json_decode_string_field(int_data, "target_id"),
          ))
        }
        _ -> None
      }
    }
  }
}

/// Parse command options
fn parse_command_options(data: String) -> List(ApplicationCommandOption) {
  let options_data = json_decode_array_field(data, "options")
  case string.starts_with(options_data, "[") {
    True -> {
      let inner = string.drop_start(options_data, 1)
      let inner = string.drop_end(inner, 1)
      case string.is_empty(inner) {
        True -> []
        False -> {
          let parts = split_json_objects(inner)
          parts
          |> list.map(parse_command_option)
        }
      }
    }
    False -> []
  }
}

/// Parse single command option
fn parse_command_option(data: String) -> ApplicationCommandOption {
  let opt_type =
    json_decode_int_field(data, "type")
    |> option.unwrap(3)
    |> int_to_option_type

  ApplicationCommandOption(
    name: json_decode_string_field(data, "name") |> option.unwrap("unknown"),
    option_type: opt_type,
    value: parse_option_value(data, opt_type),
    options: parse_command_options(data),
    focused: json_decode_bool_field(data, "focused"),
  )
}

/// Parse option value based on type
fn parse_option_value(data: String, opt_type: ApplicationCommandOptionType) {
  case opt_type {
    StringOption -> {
      case json_decode_string_field(data, "value") {
        Some(v) -> Some(StringValue(v))
        None -> None
      }
    }
    IntegerOption -> {
      case json_decode_int_field(data, "value") {
        Some(v) -> Some(IntValue(v))
        None -> None
      }
    }
    BooleanOption -> {
      case json_decode_bool_field(data, "value") {
        Some(v) -> Some(BoolValue(v))
        None -> None
      }
    }
    UserOption -> {
      case json_decode_string_field(data, "value") {
        Some(v) -> Some(UserValue(v))
        None -> None
      }
    }
    ChannelOption -> {
      case json_decode_string_field(data, "value") {
        Some(v) -> Some(ChannelValue(v))
        None -> None
      }
    }
    RoleOption -> {
      case json_decode_string_field(data, "value") {
        Some(v) -> Some(RoleValue(v))
        None -> None
      }
    }
    _ -> None
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

// ============================================================================
// JSON Parsing Helpers
// ============================================================================

/// Decode a string field from JSON string
fn json_decode_string_field(json: String, field: String) -> Option(String) {
  let pattern = "\"" <> field <> "\":\""
  case string.split_once(json, pattern) {
    Ok(#(_, rest)) -> {
      case string.split_once(rest, "\"") {
        Ok(#(value, _)) -> Some(value)
        Error(_) -> None
      }
    }
    Error(_) -> None
  }
}

/// Decode an integer field from JSON string
fn json_decode_int_field(json: String, field: String) -> Option(Int) {
  let pattern = "\"" <> field <> "\":"
  case string.split_once(json, pattern) {
    Ok(#(_, rest)) -> {
      let trimmed = string.trim_start(rest)
      case string.split_once(trimmed, ",") {
        Ok(#(value_str, _)) ->
          int.parse(string.trim(value_str)) |> option.from_result
        Error(_) -> {
          // Try splitting by }
          case string.split_once(trimmed, "}") {
            Ok(#(value_str, _)) ->
              int.parse(string.trim(value_str)) |> option.from_result
            Error(_) -> int.parse(string.trim(trimmed)) |> option.from_result
          }
        }
      }
    }
    Error(_) -> None
  }
}

/// Decode a boolean field from JSON string
fn json_decode_bool_field(json: String, field: String) -> Option(Bool) {
  let pattern = "\"" <> field <> "\":"
  case string.split_once(json, pattern) {
    Ok(#(_, rest)) -> {
      let trimmed = string.trim_start(rest)
      case string.starts_with(trimmed, "true") {
        True -> Some(True)
        False ->
          case string.starts_with(trimmed, "false") {
            True -> Some(False)
            False -> None
          }
      }
    }
    Error(_) -> None
  }
}

/// Decode an object field from JSON string
fn json_decode_object_field(json: String, field: String) -> String {
  let pattern = "\"" <> field <> "\":"
  case string.split_once(json, pattern) {
    Ok(#(_, rest)) -> {
      let trimmed = string.trim_start(rest)
      case string.starts_with(trimmed, "{") {
        True -> extract_json_object(trimmed)
        False ->
          case string.starts_with(trimmed, "[") {
            True -> extract_json_array(trimmed)
            False -> "{}"
          }
      }
    }
    Error(_) -> "{}"
  }
}

/// Decode an array field from JSON string
fn json_decode_array_field(json: String, field: String) -> String {
  let pattern = "\"" <> field <> "\":"
  case string.split_once(json, pattern) {
    Ok(#(_, rest)) -> {
      let trimmed = string.trim_start(rest)
      case string.starts_with(trimmed, "[") {
        True -> extract_json_array(trimmed)
        False -> "[]"
      }
    }
    Error(_) -> "[]"
  }
}

/// Extract a JSON object string (balanced braces)
fn extract_json_object(s: String) -> String {
  extract_balanced(s, "{", "}")
}

/// Extract a JSON array string (balanced brackets)
fn extract_json_array(s: String) -> String {
  extract_balanced(s, "[", "]")
}

/// Extract balanced delimited string
fn extract_balanced(s: String, open: String, close: String) -> String {
  let chars = string.to_graphemes(s)
  do_extract_balanced(chars, open, close, 0, [])
}

fn do_extract_balanced(
  chars: List(String),
  open: String,
  close: String,
  depth: Int,
  acc: List(String),
) -> String {
  case chars {
    [] -> string.concat(list.reverse(acc))
    [first, ..rest] -> {
      let new_depth = case first == open {
        True -> depth + 1
        False ->
          case first == close {
            True -> depth - 1
            False -> depth
          }
      }
      case depth == 0 && new_depth == 1 {
        True -> do_extract_balanced(rest, open, close, 1, [first])
        False ->
          case new_depth == 0 && depth == 1 {
            True -> {
              let final_acc = list.reverse([first, ..acc])
              string.concat(final_acc)
            }
            False ->
              do_extract_balanced(rest, open, close, new_depth, [first, ..acc])
          }
      }
    }
  }
}

/// Split JSON objects in array
fn split_json_objects(s: String) -> List(String) {
  // Split by top-level commas (not inside nested objects)
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
