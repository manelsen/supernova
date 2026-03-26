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
////   ))
//// }
//// ```

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
    /// Optional interactive payload rendered as native buttons/selectors.
    interactive: Option(ChannelInteractiveReply),
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

/// The inbound callback that the core exposes to adapters.
///
/// Each adapter receives one `ChannelHandler` at startup and calls it for each
/// incoming message or interaction callback. The core processes the inbound
/// event synchronously and returns a `ChannelReply` (or an error), which the
/// adapter then delivers to the channel.
pub type ChannelHandler =
  fn(ChannelInbound) -> Result(ChannelReply, ChannelError)

/// The adapter contract — what every channel adapter must produce.
///
/// The core holds a registry of `ChannelAdapter` values, one per channel.
/// It uses `send` to push replies without knowing anything about the
/// underlying protocol.
pub type ChannelAdapter {
  ChannelAdapter(
    /// Unique adapter identifier ("telegram", "discord", "matrix", …).
    name: String,
    /// Deliver a reply through this channel.
    send: fn(ChannelReply) -> Result(Nil, ChannelError),
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
    interactive: None,
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
    interactive: None,
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
    interactive: Some(interactive),
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
    interactive: Some(interactive),
  )
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
  let ChannelSelectOption(label:, value:) = opt
  label
}

/// Get the value from a ChannelSelectOption.
pub fn select_option_value(opt: ChannelSelectOption) -> String {
  let ChannelSelectOption(label:, value:) = opt
  value
}

/// Get the label from a ChannelButton.
pub fn button_label(btn: ChannelButton) -> String {
  let ChannelButton(label:, action_id:, style:) = btn
  label
}

/// Get the action_id from a ChannelButton.
pub fn button_action_id(btn: ChannelButton) -> String {
  let ChannelButton(label:, action_id:, style:) = btn
  action_id
}

/// Get the style from a ChannelButton.
pub fn button_style(btn: ChannelButton) -> ChannelButtonStyle {
  let ChannelButton(label:, action_id:, style:) = btn
  style
}
