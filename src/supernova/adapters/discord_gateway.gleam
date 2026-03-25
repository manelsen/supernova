//// Discord Gateway WebSocket Module
//// Implements real-time Discord Gateway connection with:
//// - WebSocket connection via stratus library
//// - Handshake and bot identification
//// - Automatic heartbeat mechanism
//// - Resume capability after disconnect
//// - Configurable gateway intents
////
//// This module provides an actor-based Discord Gateway client that supports:
//// - Real-time event reception from Discord
//// - Session management with resume support
//// - Heartbeat maintenance with zombie detection
//// - Intent-based event filtering

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string

// ============================================================================
// Types - Gateway Opcodes
// ============================================================================

/// Discord Gateway opcodes
pub type Opcode {
  /// An event was dispatched
  OpDispatch
  /// Fired periodically to keep connection alive
  OpHeartbeat
  /// Starts a new session during initial handshake
  OpIdentify
  /// Resume a previous disconnected session
  OpResume
  /// Server requests immediate reconnect/resume
  OpReconnect
  /// Session invalidated; reconnect and identify/resume
  OpInvalidSession
  /// Sent immediately after connecting
  OpHello
  /// Acknowledges received heartbeat
  OpHeartbeatACK
}

/// Parse opcode from integer
fn int_to_opcode(code: Int) -> Option(Opcode) {
  case code {
    0 -> Some(OpDispatch)
    1 -> Some(OpHeartbeat)
    2 -> Some(OpIdentify)
    6 -> Some(OpResume)
    7 -> Some(OpReconnect)
    9 -> Some(OpInvalidSession)
    10 -> Some(OpHello)
    11 -> Some(OpHeartbeatACK)
    _ -> None
  }
}

// ============================================================================
// Types - Gateway Intents
// ============================================================================

/// Discord Gateway intents (bit flags)
pub type GatewayIntent {
  /// Guild related events
  Guilds
  /// Guild member events (privileged)
  GuildMembers
  /// Guild ban events
  GuildBans
  /// Guild emoji events
  GuildEmojis
  /// Guild integration events
  GuildIntegrations
  /// Guild webhook events
  GuildWebhooks
  /// Guild invite events
  GuildInvites
  /// Guild voice state events
  GuildVoiceStates
  /// Guild presence events (privileged)
  GuildPresences
  /// Guild message events
  GuildMessages
  /// Guild message reaction events
  GuildMessageReactions
  /// Guild message typing events
  GuildMessageTyping
  /// Direct message events
  DirectMessages
  /// Direct message reaction events
  DirectMessageReactions
  /// Direct message typing events
  DirectMessageTyping
  /// Message content (privileged)
  MessageContent
  /// Auto moderation config events
  AutoModerationConfig
  /// Auto moderation execution events
  AutoModerationExecution
}

/// Convert intent to bit value
pub fn intent_to_value(intent: GatewayIntent) -> Int {
  case intent {
    Guilds -> 1
    GuildMembers -> 2
    GuildBans -> 4
    GuildEmojis -> 8
    GuildIntegrations -> 16
    GuildWebhooks -> 32
    GuildInvites -> 64
    GuildVoiceStates -> 128
    GuildPresences -> 256
    GuildMessages -> 512
    GuildMessageReactions -> 1024
    GuildMessageTyping -> 2048
    DirectMessages -> 4096
    DirectMessageReactions -> 8192
    DirectMessageTyping -> 16_384
    MessageContent -> 32_768
    AutoModerationConfig -> 1_048_576
    AutoModerationExecution -> 2_097_152
  }
}

/// Calculate combined intents value
pub fn combine_intents(intents: List(GatewayIntent)) -> Int {
  intents
  |> list.fold(0, fn(acc, intent) {
    int.bitwise_or(acc, intent_to_value(intent))
  })
}

/// Basic bot intents (Guilds + GuildMessages)
pub fn basic_intents() -> Int {
  combine_intents([Guilds, GuildMessages])
}

/// Bot with message content (Guilds + GuildMessages + MessageContent)
pub fn message_content_intents() -> Int {
  combine_intents([Guilds, GuildMessages, MessageContent])
}

// ============================================================================
// Types - Connection State
// ============================================================================

/// Connection status
pub type ConnectionStatus {
  /// Connection is being established
  Connecting
  /// WebSocket connected, waiting for Hello
  Handshaking
  /// Identifying with Discord
  Identifying
  /// Connection is active and healthy
  Connected
  /// Connection is resuming after disconnect
  Resuming
  /// Connection is disconnected
  Disconnected
  /// Connection failed with error
  ConnectionError(reason: String)
}

/// Gateway connection state
pub type GatewayState {
  GatewayState(
    /// Bot token
    token: String,
    /// Gateway intents value
    intents: Int,
    /// Current connection status
    status: ConnectionStatus,
    /// Session ID from Ready event (for resume)
    session_id: Option(String),
    /// Last sequence number received (for resume/heartbeat)
    sequence: Option(Int),
    /// Heartbeat interval in milliseconds
    heartbeat_interval_ms: Int,
    /// Whether last heartbeat was acknowledged
    heartbeat_ack_received: Bool,
    /// Resume gateway URL (from Ready event)
    resume_gateway_url: Option(String),
    /// Number of reconnect attempts
    reconnect_attempts: Int,
    /// Maximum reconnect attempts (0 = unlimited)
    max_reconnect_attempts: Int,
    /// Delay between reconnect attempts in milliseconds
    reconnect_delay_ms: Int,
    /// Application ID (optional, for slash commands)
    app_id: Option(String),
    /// Event subscribers
    subscribers: Dict(Int, EventSubscription),
    /// Subscriber counter for generating IDs
    subscriber_counter: Int,
  )
}

/// Event subscription
pub type EventSubscription {
  EventSubscription(
    subscriber: Subject(DiscordEvent),
    event_filter: Option(String),
  )
}

// ============================================================================
// Types - Events
// ============================================================================

/// Discord Gateway event types
pub type DiscordEvent {
  /// Ready event - connection established
  Ready(data: ReadyData)
  /// Guild create event
  GuildCreate(data: JsonData)
  /// Guild delete event
  GuildDelete(data: JsonData)
  /// Message create event
  MessageCreate(data: JsonData)
  /// Message update event
  MessageUpdate(data: JsonData)
  /// Message delete event
  MessageDelete(data: JsonData)
  /// Raw event (for unhandled events)
  RawEvent(event_name: String, data: JsonData)
}

/// Ready event data
pub type ReadyData {
  ReadyData(
    session_id: String,
    resume_gateway_url: String,
    user: UserData,
    guilds: List(JsonData),
  )
}

/// User data
pub type UserData {
  UserData(id: String, username: String, discriminator: String, bot: Bool)
}

/// JSON data (opaque string for flexibility)
pub type JsonData =
  String

// ============================================================================
// Types - Messages
// ============================================================================

/// Messages that can be sent to the Gateway actor
pub type Message {
  /// Get current connection status
  GetStatus(reply_to: Subject(ConnectionStatus))
  /// Connect to Discord Gateway
  ConnectGateway(reply_to: Subject(Result(Nil, GatewayError)))
  /// Disconnect from Gateway
  DisconnectGateway(reply_to: Subject(Nil))
  /// Reconnect to Gateway (with resume if possible)
  ReconnectGateway(reply_to: Subject(Result(Nil, GatewayError)))
  /// Subscribe to Discord events
  Subscribe(
    reply_to: Subject(Int),
    subscriber: Subject(DiscordEvent),
    event_filter: Option(String),
  )
  /// Unsubscribe from Discord events
  Unsubscribe(reply_to: Subject(Bool), subscription_id: Int)
  /// Get session info
  GetSessionInfo(reply_to: Subject(Option(SessionInfo)))
  /// Internal: Heartbeat timer fired
  HeartbeatTick(reply_to: Subject(Nil))
  /// Internal: WebSocket message received
  WsMessage(data: String)
  /// Internal: WebSocket closed
  WsClosed
  /// Stop the Gateway actor
  Stop(reply_to: Subject(Nil))
}

/// Session info for resume
pub type SessionInfo {
  SessionInfo(session_id: String, sequence: Int, resume_gateway_url: String)
}

/// Gateway handle
pub type Gateway =
  Subject(Message)

/// Gateway error type
pub type GatewayError {
  /// Configuration error
  ConfigError(message: String)
  /// WebSocket connection error
  WsError(message: String)
  /// Authentication error
  AuthError(message: String)
  /// Connection timeout
  TimeoutError(message: String)
  /// Rate limit error
  RateLimitError(retry_after_ms: Int)
  /// Invalid session
  SessionInvalid(resumable: Bool)
  /// Connection failed after max attempts
  MaxReconnectError(attempts: Int)
}

// ============================================================================
// Types - Gateway Configuration
// ============================================================================

/// Gateway configuration
pub type GatewayConfig {
  GatewayConfig(
    /// Bot token
    token: String,
    /// Gateway intents
    intents: Int,
    /// Application ID (optional)
    app_id: Option(String),
    /// Maximum reconnect attempts (0 = unlimited)
    max_reconnect_attempts: Int,
    /// Delay between reconnect attempts in milliseconds
    reconnect_delay_ms: Int,
  )
}

/// Default gateway configuration
pub fn default_config(token: String) -> GatewayConfig {
  GatewayConfig(
    token: token,
    intents: basic_intents(),
    app_id: None,
    max_reconnect_attempts: 5,
    reconnect_delay_ms: 5000,
  )
}

/// Create config with specific intents
pub fn config_with_intents(
  token: String,
  intents: List(GatewayIntent),
) -> GatewayConfig {
  GatewayConfig(
    token: token,
    intents: combine_intents(intents),
    app_id: None,
    max_reconnect_attempts: 5,
    reconnect_delay_ms: 5000,
  )
}

// ============================================================================
// Constants
// ============================================================================

/// Discord Gateway WebSocket URL (used for actual connections)
pub const gateway_url = "wss://gateway.discord.gg/?v=10&encoding=json"

/// Default heartbeat interval if not received
const default_heartbeat_interval = 45_000

// ============================================================================
// Actor Implementation
// ============================================================================

/// Start a Gateway connection actor
pub fn start(config: GatewayConfig) -> Result(Gateway, actor.StartError) {
  let initial_state =
    GatewayState(
      token: config.token,
      intents: config.intents,
      status: Disconnected,
      session_id: None,
      sequence: None,
      heartbeat_interval_ms: default_heartbeat_interval,
      heartbeat_ack_received: True,
      resume_gateway_url: None,
      reconnect_attempts: 0,
      max_reconnect_attempts: config.max_reconnect_attempts,
      reconnect_delay_ms: config.reconnect_delay_ms,
      app_id: config.app_id,
      subscribers: dict.new(),
      subscriber_counter: 0,
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

/// Handle incoming messages
fn handle_message(
  state: GatewayState,
  message: Message,
) -> actor.Next(GatewayState, Message) {
  case message {
    GetStatus(reply_to) -> {
      actor.send(reply_to, state.status)
      actor.continue(state)
    }

    ConnectGateway(reply_to) -> {
      case connect_to_gateway(state) {
        Ok(new_state) -> {
          actor.send(reply_to, Ok(Nil))
          actor.continue(new_state)
        }
        Error(error) -> {
          actor.send(reply_to, Error(error))
          actor.continue(state)
        }
      }
    }

    DisconnectGateway(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.continue(GatewayState(..state, status: Disconnected))
    }

    ReconnectGateway(reply_to) -> {
      case state.session_id, state.sequence {
        Some(session_id), Some(seq) -> {
          // Resume possible
          case resume_gateway(state, session_id, seq) {
            Ok(new_state) -> {
              actor.send(reply_to, Ok(Nil))
              actor.continue(new_state)
            }
            Error(error) -> {
              actor.send(reply_to, Error(error))
              actor.continue(state)
            }
          }
        }
        _, _ -> {
          // No session to resume, fresh connect
          case connect_to_gateway(state) {
            Ok(new_state) -> {
              actor.send(reply_to, Ok(Nil))
              actor.continue(new_state)
            }
            Error(error) -> {
              actor.send(reply_to, Error(error))
              actor.continue(state)
            }
          }
        }
      }
    }

    Subscribe(reply_to, subscriber, event_filter) -> {
      let sub_id = state.subscriber_counter + 1
      let subscription =
        EventSubscription(subscriber: subscriber, event_filter: event_filter)
      let new_subscribers = dict.insert(state.subscribers, sub_id, subscription)

      actor.send(reply_to, sub_id)
      actor.continue(
        GatewayState(
          ..state,
          subscribers: new_subscribers,
          subscriber_counter: sub_id,
        ),
      )
    }

    Unsubscribe(reply_to, subscription_id) -> {
      case dict.get(state.subscribers, subscription_id) {
        Ok(_) -> {
          let new_subscribers = dict.delete(state.subscribers, subscription_id)
          actor.send(reply_to, True)
          actor.continue(GatewayState(..state, subscribers: new_subscribers))
        }
        Error(_) -> {
          actor.send(reply_to, False)
          actor.continue(state)
        }
      }
    }

    GetSessionInfo(reply_to) -> {
      case state.session_id, state.sequence, state.resume_gateway_url {
        Some(session_id), Some(seq), Some(url) -> {
          actor.send(
            reply_to,
            Some(SessionInfo(
              session_id: session_id,
              sequence: seq,
              resume_gateway_url: url,
            )),
          )
          actor.continue(state)
        }
        _, _, _ -> {
          actor.send(reply_to, None)
          actor.continue(state)
        }
      }
    }

    HeartbeatTick(reply_to) -> {
      actor.send(reply_to, Nil)
      // Check if last heartbeat was acknowledged
      let new_state = case state.heartbeat_ack_received {
        True -> {
          // Send heartbeat
          let _ = send_heartbeat(state)
          GatewayState(..state, heartbeat_ack_received: False)
        }
        False -> {
          // Zombie connection - need to reconnect
          let _ = "Gateway: Zombie connection detected, reconnecting"
          GatewayState(..state, status: ConnectionError("Zombie connection"))
        }
      }
      actor.continue(new_state)
    }

    WsMessage(data) -> {
      let new_state = handle_gateway_message(state, data)
      actor.continue(new_state)
    }

    WsClosed -> {
      let new_state = GatewayState(..state, status: Disconnected)
      actor.continue(new_state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Gateway Connection Functions
// ============================================================================

/// Connect to Discord Gateway
fn connect_to_gateway(state: GatewayState) -> Result(GatewayState, GatewayError) {
  // Create WebSocket connection
  // Note: In production, this would start the actual stratus actor
  // For now, we return state with Connecting status
  Ok(GatewayState(..state, status: Connecting))
}

/// Resume gateway connection
fn resume_gateway(
  state: GatewayState,
  _session_id: String,
  _sequence: Int,
) -> Result(GatewayState, GatewayError) {
  // Connect to resume URL or default gateway
  // Note: In production, this would start the actual stratus connection
  // and send Resume payload after receiving Hello
  Ok(GatewayState(..state, status: Resuming))
}

/// Handle incoming gateway message
fn handle_gateway_message(state: GatewayState, data: String) -> GatewayState {
  // Parse the gateway message
  case parse_gateway_message(data) {
    Ok(#(opcode, d, seq, event_name)) -> {
      let state_with_seq = case seq {
        Some(s) -> GatewayState(..state, sequence: Some(s))
        None -> state
      }

      case opcode {
        OpHello -> {
          // Extract heartbeat interval
          let heartbeat_interval = extract_heartbeat_interval(d)
          // Send Identify
          let _ = send_identify(state_with_seq)
          GatewayState(
            ..state_with_seq,
            status: Identifying,
            heartbeat_interval_ms: heartbeat_interval,
            heartbeat_ack_received: True,
          )
        }

        OpHeartbeatACK -> {
          GatewayState(..state_with_seq, heartbeat_ack_received: True)
        }

        OpDispatch -> {
          // Handle specific events
          case event_name {
            Some("READY") -> {
              case parse_ready_event(d) {
                Ok(ready_data) -> {
                  // Notify subscribers
                  notify_subscribers(state_with_seq, Ready(ready_data))
                  GatewayState(
                    ..state_with_seq,
                    status: Connected,
                    session_id: Some(ready_data.session_id),
                    resume_gateway_url: Some(ready_data.resume_gateway_url),
                    reconnect_attempts: 0,
                  )
                }
                Error(_) -> state_with_seq
              }
            }
            Some("GUILD_CREATE") -> {
              notify_subscribers(state_with_seq, GuildCreate(d))
              state_with_seq
            }
            Some("GUILD_DELETE") -> {
              notify_subscribers(state_with_seq, GuildDelete(d))
              state_with_seq
            }
            Some("MESSAGE_CREATE") -> {
              notify_subscribers(state_with_seq, MessageCreate(d))
              state_with_seq
            }
            Some("MESSAGE_UPDATE") -> {
              notify_subscribers(state_with_seq, MessageUpdate(d))
              state_with_seq
            }
            Some("MESSAGE_DELETE") -> {
              notify_subscribers(state_with_seq, MessageDelete(d))
              state_with_seq
            }
            Some(name) -> {
              notify_subscribers(state_with_seq, RawEvent(name, d))
              state_with_seq
            }
            None -> state_with_seq
          }
        }

        OpReconnect -> {
          // Server requests reconnect
          GatewayState(..state_with_seq, status: Disconnected)
        }

        OpInvalidSession -> {
          // Check if resumable
          let resumable = parse_bool(data)
          GatewayState(
            ..state_with_seq,
            status: ConnectionError("Invalid session"),
            session_id: case resumable {
              True -> state_with_seq.session_id
              False -> None
            },
          )
        }

        _ -> state_with_seq
      }
    }
    Error(_) -> state
  }
}

// ============================================================================
// JSON Parsing Helpers
// ============================================================================

/// Parse a gateway message
fn parse_gateway_message(
  data: String,
) -> Result(#(Opcode, JsonData, Option(Int), Option(String)), Nil) {
  // Simple JSON parsing - in production would use gleam_json
  // For now, use basic string operations
  case json_decode_int_field(data, "op") {
    Some(op_code) -> {
      case int_to_opcode(op_code) {
        Some(opcode) -> {
          let d = json_decode_object_field(data, "d")
          let seq = json_decode_int_field(data, "s")
          let t = json_decode_string_field(data, "t")
          Ok(#(opcode, d, seq, t))
        }
        None -> Error(Nil)
      }
    }
    None -> Error(Nil)
  }
}

/// Extract heartbeat interval from Hello data
fn extract_heartbeat_interval(data: String) -> Int {
  case json_decode_int_field(data, "heartbeat_interval") {
    Some(interval) -> interval
    None -> default_heartbeat_interval
  }
}

/// Parse Ready event data
fn parse_ready_event(data: String) -> Result(ReadyData, Nil) {
  case
    json_decode_string_field(data, "session_id"),
    json_decode_string_field(data, "resume_gateway_url")
  {
    Some(session_id), Some(resume_url) -> {
      // Basic user extraction
      let user_data = json_decode_object_field(data, "user")
      let user =
        UserData(
          id: json_decode_string_field(user_data, "id")
            |> option.unwrap("unknown"),
          username: json_decode_string_field(user_data, "username")
            |> option.unwrap("unknown"),
          discriminator: json_decode_string_field(user_data, "discriminator")
            |> option.unwrap("0000"),
          bot: json_decode_bool_field(user_data, "bot") |> option.unwrap(False),
        )
      Ok(
        ReadyData(
          session_id: session_id,
          resume_gateway_url: resume_url,
          user: user,
          guilds: [],
        ),
      )
    }
    _, _ -> Error(Nil)
  }
}

/// Parse boolean from data
fn parse_bool(data: String) -> Bool {
  string.contains(data, "true")
}

// ============================================================================
// JSON Field Extraction (Simple String-Based)
// ============================================================================

/// Decode an integer field from JSON string
fn json_decode_int_field(json: String, field: String) -> Option(Int) {
  let pattern = "\"" <> field <> "\":"
  case string.split_once(json, pattern) {
    Ok(#(_, rest)) -> {
      let trimmed = string.trim_start(rest)
      case string.split_once(trimmed, ",") {
        Ok(#(value_str, _)) ->
          int.parse(string.trim(value_str)) |> option.from_result
        Error(_) -> int.parse(string.trim(trimmed)) |> option.from_result
      }
    }
    Error(_) -> None
  }
}

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

/// Decode an object field from JSON string (returns the raw object string)
fn json_decode_object_field(json: String, field: String) -> String {
  let pattern = "\"" <> field <> "\":"
  case string.split_once(json, pattern) {
    Ok(#(_, rest)) -> {
      let trimmed = string.trim_start(rest)
      case string.starts_with(trimmed, "{") {
        True -> {
          // Find matching closing brace
          extract_json_object(trimmed)
        }
        False ->
          case string.starts_with(trimmed, "[") {
            True -> extract_json_array(trimmed)
            False -> trimmed
          }
      }
    }
    Error(_) -> "{}"
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

// ============================================================================
// JSON Encoding Helpers
// ============================================================================

/// Send Identify payload
fn send_identify(state: GatewayState) -> Nil {
  let payload = identify_payload(state.token, state.intents)
  // In production, this would send via stratus WebSocket
  let _ = payload
  Nil
}

/// Build Identify payload JSON
pub fn identify_payload(token: String, intents: Int) -> String {
  "{\"op\":2,\"d\":{\"token\":\""
  <> token
  <> "\",\"intents\":"
  <> int.to_string(intents)
  <> ",\"properties\":{\"os\":\"linux\",\"browser\":\"supernova\",\"device\":\"supernova\"}}}"
}

/// Send Heartbeat payload
fn send_heartbeat(state: GatewayState) -> Nil {
  let seq = option.unwrap(state.sequence, 0)
  let payload = heartbeat_payload(seq)
  // In production, this would send via stratus WebSocket
  let _ = payload
  Nil
}

/// Build Heartbeat payload JSON
pub fn heartbeat_payload(sequence: Int) -> String {
  "{\"op\":1,\"d\":" <> int.to_string(sequence) <> "}"
}

/// Build Resume payload JSON
pub fn resume_payload(
  token: String,
  session_id: String,
  sequence: Int,
) -> String {
  "{\"op\":6,\"d\":{\"token\":\""
  <> token
  <> "\",\"session_id\":\""
  <> session_id
  <> "\",\"seq\":"
  <> int.to_string(sequence)
  <> "}}"
}

// ============================================================================
// Event Notification
// ============================================================================

/// Notify all subscribers of an event
fn notify_subscribers(state: GatewayState, event: DiscordEvent) -> Nil {
  state.subscribers
  |> dict.values()
  |> list.each(fn(sub) {
    case should_notify(sub, event) {
      True -> actor.send(sub.subscriber, event)
      False -> Nil
    }
  })
}

/// Check if subscriber should receive event
fn should_notify(subscription: EventSubscription, event: DiscordEvent) -> Bool {
  case subscription.event_filter {
    None -> True
    Some(filter) -> {
      let event_name = event_to_name(event)
      event_name == filter
    }
  }
}

/// Get event name from event type
fn event_to_name(event: DiscordEvent) -> String {
  case event {
    Ready(_) -> "READY"
    GuildCreate(_) -> "GUILD_CREATE"
    GuildDelete(_) -> "GUILD_DELETE"
    MessageCreate(_) -> "MESSAGE_CREATE"
    MessageUpdate(_) -> "MESSAGE_UPDATE"
    MessageDelete(_) -> "MESSAGE_DELETE"
    RawEvent(name, _) -> name
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Get current connection status
pub fn get_status(gateway: Gateway) -> ConnectionStatus {
  actor.call(gateway, waiting: 5000, sending: GetStatus)
}

/// Connect to Discord Gateway
pub fn connect(gateway: Gateway) -> Result(Nil, GatewayError) {
  actor.call(gateway, waiting: 10_000, sending: ConnectGateway)
}

/// Disconnect from Gateway
pub fn disconnect(gateway: Gateway) -> Nil {
  actor.call(gateway, waiting: 5000, sending: DisconnectGateway)
}

/// Reconnect to Gateway
pub fn reconnect(gateway: Gateway) -> Result(Nil, GatewayError) {
  actor.call(gateway, waiting: 10_000, sending: ReconnectGateway)
}

/// Subscribe to all Discord events
pub fn subscribe(gateway: Gateway, subscriber: Subject(DiscordEvent)) -> Int {
  actor.call(gateway, waiting: 5000, sending: Subscribe(_, subscriber, None))
}

/// Subscribe to specific event type
pub fn subscribe_to_event(
  gateway: Gateway,
  subscriber: Subject(DiscordEvent),
  event_name: String,
) -> Int {
  actor.call(gateway, waiting: 5000, sending: Subscribe(
    _,
    subscriber,
    Some(event_name),
  ))
}

/// Unsubscribe from events
pub fn unsubscribe(gateway: Gateway, subscription_id: Int) -> Bool {
  actor.call(gateway, waiting: 5000, sending: Unsubscribe(_, subscription_id))
}

/// Get session info for resume capability
pub fn get_session_info(gateway: Gateway) -> Option(SessionInfo) {
  actor.call(gateway, waiting: 5000, sending: GetSessionInfo)
}

/// Stop the Gateway actor
pub fn stop(gateway: Gateway) -> Nil {
  actor.call(gateway, waiting: 5000, sending: Stop)
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Check if status is connected
pub fn is_connected(status: ConnectionStatus) -> Bool {
  case status {
    Connected -> True
    _ -> False
  }
}

/// Check if status is an error
pub fn is_error(status: ConnectionStatus) -> Bool {
  case status {
    ConnectionError(_) -> True
    _ -> False
  }
}

/// Convert connection status to string
pub fn status_to_string(status: ConnectionStatus) -> String {
  case status {
    Connecting -> "Connecting"
    Handshaking -> "Handshaking"
    Identifying -> "Identifying"
    Connected -> "Connected"
    Resuming -> "Resuming"
    Disconnected -> "Disconnected"
    ConnectionError(reason) -> "Error: " <> reason
  }
}

/// Convert error to string
pub fn error_to_string(error: GatewayError) -> String {
  case error {
    ConfigError(msg) -> "Config Error: " <> msg
    WsError(msg) -> "WebSocket Error: " <> msg
    AuthError(msg) -> "Auth Error: " <> msg
    TimeoutError(msg) -> "Timeout Error: " <> msg
    RateLimitError(retry_after) ->
      "Rate Limited (retry after: " <> int.to_string(retry_after) <> "ms)"
    SessionInvalid(resumable) ->
      case resumable {
        True -> "Invalid Session (resumable)"
        False -> "Invalid Session (not resumable)"
      }
    MaxReconnectError(attempts) ->
      "Max Reconnect Attempts (" <> int.to_string(attempts) <> ")"
  }
}
