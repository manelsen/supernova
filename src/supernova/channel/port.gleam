//// Channel Port — boundary contract between channel adapters and the core.
////
//// Every channel adapter (Telegram, Discord, Matrix, Lark, …) must:
////
////   1. Normalise raw protocol messages into `ChannelMessage` values.
////
////   2. Accept a `ChannelHandler` callback from the core at startup and
////      call it for every incoming `ChannelMessage`.
////
////   3. Return a `ChannelAdapter` value so the core can send replies back
////      through that channel without depending on any adapter module.
////
//// The core must never import any adapter module. It only ever sees the
//// types defined here.
////
//// ## Adapter contract (skeleton)
////
//// ```gleam
//// pub fn start(
////   handler: port.ChannelHandler,
//// ) -> Result(port.ChannelAdapter, StartError) {
////   // … start polling / webhooks / WebSocket …
////   Ok(port.ChannelAdapter(
////     name: "myapp",
////     send: fn(reply) { do_send(reply) },
////     stop: fn() { Nil },
////   ))
//// }
//// ```

import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}

// ============================================================================
// Inbound — adapter → core
// ============================================================================

/// A normalised message produced by any channel adapter.
pub type ChannelMessage {
  ChannelMessage(
    /// Opaque message ID assigned by the originating channel.
    /// Used for threading (reply_to_id) and deduplication.
    /// Adapters that have no per-message ID should synthesise one.
    id: String,
    /// Adapter name: "telegram", "discord", "matrix", "lark", …
    channel: String,
    /// Conversation identifier, scoped to the channel.
    /// Telegram: chat_id.  Discord: channel_id.
    /// Matrix: room_id.    Lark: chat_id.
    channel_id: String,
    /// Sender identifier, scoped to the channel.
    user_id: String,
    /// Display name of the sender (best-effort; may be empty).
    username: String,
    /// Plain-text content. Empty string for media-only messages.
    content: String,
    /// True when the sender is a bot or automated account.
    /// Adapters should filter bots out before calling the handler, but the
    /// flag is kept so the core can apply its own policy if needed.
    is_bot: Bool,
    /// ID of the message being replied to, if any.
    reply_to_id: Option(String),
  )
}

/// An interaction callback triggered by a channel UI component.
///
/// Examples:
/// - Telegram callback query (`callback_data`)
/// - Discord component interaction (`custom_id`, select values)
pub type ChannelInteractionEvent {
  ChannelInteractionEvent(
    /// Opaque callback interaction ID assigned by the channel, when available.
    id: String,
    /// Canonical action ID to dispatch in core policy.
    action_id: String,
    /// Values selected by the user (for select menus), if any.
    values: List(String),
    /// Message ID that originated the interactive component, if any.
    source_message_id: Option(String),
  )
}

/// A normalised interaction payload produced by a channel adapter.
pub type ChannelInteractionMessage {
  ChannelInteractionMessage(
    /// Adapter name: "telegram", "discord", "matrix", "lark", …
    channel: String,
    /// Conversation identifier, scoped to the channel.
    channel_id: String,
    /// Sender identifier, scoped to the channel.
    user_id: String,
    /// Display name of the sender (best-effort; may be empty).
    username: String,
    /// True when the sender is a bot or automated account.
    is_bot: Bool,
    /// The interaction callback event.
    event: ChannelInteractionEvent,
  )
}

/// Unified inbound envelope received by core handlers.
pub type ChannelInbound {
  InboundMessage(ChannelMessage)
  InboundInteraction(ChannelInteractionMessage)
}

// ============================================================================
// Outbound — core → adapter
// ============================================================================

/// Standardized button styles across channel adapters.
pub type ChannelButtonStyle {
  ButtonPrimary
  ButtonSecondary
  ButtonSuccess
  ButtonDanger
}

/// A channel-agnostic button action.
pub type ChannelButton {
  ChannelButton(label: String, action_id: String, style: ChannelButtonStyle)
}

/// A channel-agnostic select option.
pub type ChannelSelectOption {
  ChannelSelectOption(label: String, value: String)
}

/// A channel-agnostic interactive block.
pub type ChannelInteractionBlock {
  InteractionText(text: String)
  InteractionButtons(buttons: List(ChannelButton))
  InteractionSelect(
    action_id: String,
    placeholder: Option(String),
    options: List(ChannelSelectOption),
  )
}

/// A structured interaction payload that adapters render natively.
pub type ChannelInteractiveReply {
  ChannelInteractiveReply(blocks: List(ChannelInteractionBlock))
}

/// Media attachments rendered natively when the adapter supports them.
pub type ChannelMedia {
  ImageMedia(url: String, alt_text: Option(String))
  AudioMedia(url: String, mime_type: Option(String))
  DocumentMedia(url: String, filename: String, mime_type: Option(String))
}

/// A reply produced by the core and delivered through a channel adapter.
pub type ChannelReply {
  ChannelReply(
    /// Must match the `channel_id` of the originating `ChannelMessage`.
    channel_id: String,
    /// Text to deliver. The adapter is responsible for any channel-specific
    /// formatting (Markdown escaping, mention syntax, length limits, etc.).
    content: String,
    /// If set, the reply should thread / quote this message ID.
    reply_to_id: Option(String),
    /// If set, send into this explicit thread / topic when the channel supports it.
    thread_id: Option(String),
    /// When true, the adapter should emit a typing indicator before delivery.
    typing: Bool,
    /// If set, the adapter should edit this message instead of sending a new one.
    edit_message_id: Option(String),
    /// Optional interactive payload rendered as native buttons/selectors.
    interactive: Option(ChannelInteractiveReply),
    /// Optional media attachments associated with the reply.
    media: List(ChannelMedia),
  )
}

// ============================================================================
// Errors
// ============================================================================

pub type ChannelError {
  /// Delivery failed for a transient or permanent reason.
  SendFailed(reason: String)
  /// The adapter is not currently connected to the channel.
  NotConnected
  /// The channel is rate-limiting outbound messages.
  /// Caller should retry after the given number of seconds.
  RateLimited(retry_after_seconds: Int)
  /// An incoming message was intentionally skipped (bot, empty, filtered).
  Ignored(reason: String)
  /// The adapter/core does not support this interaction yet.
  UnsupportedInteraction(reason: String)
}

// ============================================================================
// Contract
// ============================================================================

/// Stream event emitted by the core while building a channel reply.
pub type ChannelStreamEvent {
  StreamUpdate(reply: ChannelReply)
  StreamComplete(reply: ChannelReply)
  StreamFailure(error: ChannelError)
}

/// Result returned by the core inbound handler.
pub type ChannelHandlerResult {
  ImmediateReply(reply: ChannelReply)
  StreamReply(base_reply: ChannelReply)
}

/// The inbound callback that the core exposes to adapters.
///
/// Each adapter receives one `ChannelHandler` at startup and calls it for each
/// incoming message or interaction callback. The core may either return an
/// immediate reply or a stream of progressive reply updates, which the adapter
/// runtime delivers to the channel.
pub type ChannelHandler =
  fn(ChannelInbound, Subject(ChannelStreamEvent)) ->
    Result(ChannelHandlerResult, ChannelError)

/// The adapter contract — what every channel adapter must produce.
///
/// The core holds a registry of `ChannelAdapter` values, one per channel.
/// It uses `send` to push replies and `stop` to shut adapters down without
/// knowing anything about the underlying protocol.
pub type ChannelAdapter {
  ChannelAdapter(
    /// Unique adapter identifier ("telegram", "discord", "matrix", …).
    name: String,
    /// Deliver a reply through this channel.
    send: fn(ChannelReply) -> Result(Nil, ChannelError),
    /// Stop receiving new inbound events without closing the send path.
    stop_ingress: fn() -> Nil,
    /// Shut the adapter down and release any associated resources.
    stop: fn() -> Nil,
  )
}

// ============================================================================
// Builders
// ============================================================================

/// Build a plain reply to a `ChannelMessage`.
pub fn reply(to msg: ChannelMessage, content content: String) -> ChannelReply {
  ChannelReply(
    channel_id: msg.channel_id,
    content: content,
    reply_to_id: None,
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: None,
    media: [],
  )
}

/// Build a threaded reply that quotes the original message.
pub fn reply_thread(
  to msg: ChannelMessage,
  content content: String,
) -> ChannelReply {
  ChannelReply(
    channel_id: msg.channel_id,
    content: content,
    reply_to_id: Some(msg.id),
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: None,
    media: [],
  )
}

/// Build a plain reply that includes interactive blocks.
pub fn reply_with_interactions(
  to msg: ChannelMessage,
  content content: String,
  interactive interactive: ChannelInteractiveReply,
) -> ChannelReply {
  ChannelReply(
    channel_id: msg.channel_id,
    content: content,
    reply_to_id: None,
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: Some(interactive),
    media: [],
  )
}

/// Build a threaded reply that includes interactive blocks.
pub fn reply_thread_with_interactions(
  to msg: ChannelMessage,
  content content: String,
  interactive interactive: ChannelInteractiveReply,
) -> ChannelReply {
  ChannelReply(
    channel_id: msg.channel_id,
    content: content,
    reply_to_id: Some(msg.id),
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: Some(interactive),
    media: [],
  )
}

/// Attach an explicit thread / topic target to a reply.
pub fn with_thread(reply: ChannelReply, thread_id: String) -> ChannelReply {
  ChannelReply(..reply, thread_id: Some(thread_id))
}

/// Request a typing indicator before the adapter sends the reply.
pub fn with_typing(reply: ChannelReply, typing: Bool) -> ChannelReply {
  ChannelReply(..reply, typing: typing)
}

/// Request that the adapter edits an existing message.
pub fn with_edit_message(
  reply: ChannelReply,
  message_id: String,
) -> ChannelReply {
  ChannelReply(..reply, edit_message_id: Some(message_id))
}

/// Attach media payloads to a reply.
pub fn with_media(
  reply: ChannelReply,
  media: List(ChannelMedia),
) -> ChannelReply {
  ChannelReply(..reply, media: media)
}

/// Build an inbound wrapper for plain message events.
pub fn inbound_message(msg: ChannelMessage) -> ChannelInbound {
  InboundMessage(msg)
}

/// Build an inbound wrapper for interaction callback events.
pub fn inbound_interaction(msg: ChannelInteractionMessage) -> ChannelInbound {
  InboundInteraction(msg)
}

/// Build a channel-interactive reply payload from blocks.
pub fn interactive_reply(
  blocks: List(ChannelInteractionBlock),
) -> ChannelInteractiveReply {
  ChannelInteractiveReply(blocks: blocks)
}

/// Build an image attachment.
pub fn image_media(
  url url: String,
  alt_text alt_text: Option(String),
) -> ChannelMedia {
  ImageMedia(url: url, alt_text: alt_text)
}

/// Build an audio attachment.
pub fn audio_media(
  url url: String,
  mime_type mime_type: Option(String),
) -> ChannelMedia {
  AudioMedia(url: url, mime_type: mime_type)
}

/// Build a document attachment.
pub fn document_media(
  url url: String,
  filename filename: String,
  mime_type mime_type: Option(String),
) -> ChannelMedia {
  DocumentMedia(url: url, filename: filename, mime_type: mime_type)
}

/// Build a standardized interaction button.
pub fn button(
  label label: String,
  action_id action_id: String,
  style style: ChannelButtonStyle,
) -> ChannelButton {
  ChannelButton(label: label, action_id: action_id, style: style)
}

/// Build a standardized select option.
pub fn select_option(
  label label: String,
  value value: String,
) -> ChannelSelectOption {
  ChannelSelectOption(label: label, value: value)
}

/// Build a plain text interaction block.
pub fn text_block(text text: String) -> ChannelInteractionBlock {
  InteractionText(text: text)
}

/// Build a button-row interaction block.
pub fn buttons_block(
  buttons buttons: List(ChannelButton),
) -> ChannelInteractionBlock {
  InteractionButtons(buttons: buttons)
}

/// Build a select interaction block.
pub fn select_block(
  action_id action_id: String,
  placeholder placeholder: Option(String),
  options options: List(ChannelSelectOption),
) -> ChannelInteractionBlock {
  InteractionSelect(
    action_id: action_id,
    placeholder: placeholder,
    options: options,
  )
}

// ============================================================================
// Accessors for opaque types
// ============================================================================

/// Get the label from a ChannelSelectOption.
pub fn select_option_label(opt: ChannelSelectOption) -> String {
  let ChannelSelectOption(label:, value: _) = opt
  label
}

/// Get the value from a ChannelSelectOption.
pub fn select_option_value(opt: ChannelSelectOption) -> String {
  let ChannelSelectOption(label: _, value:) = opt
  value
}

/// Get the label from a ChannelButton.
pub fn button_label(btn: ChannelButton) -> String {
  let ChannelButton(label:, action_id: _, style: _) = btn
  label
}

/// Get the action_id from a ChannelButton.
pub fn button_action_id(btn: ChannelButton) -> String {
  let ChannelButton(label: _, action_id:, style: _) = btn
  action_id
}

/// Get the style from a ChannelButton.
pub fn button_style(btn: ChannelButton) -> ChannelButtonStyle {
  let ChannelButton(label: _, action_id: _, style:) = btn
  style
}

/// Resolve the effective thread target for a reply.
pub fn thread_target(reply: ChannelReply) -> Option(String) {
  case reply.thread_id {
    Some(thread_id) -> Some(thread_id)
    None -> reply.reply_to_id
  }
}
