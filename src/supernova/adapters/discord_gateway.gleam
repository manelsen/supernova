//// Discord Gateway client.
////
//// One actor holds the session: status, sequence, session id, heartbeat and
//// subscribers. The WebSocket itself (`stratus`) runs under a connection
//// process that is not linked to the actor: a dropped socket ends that
//// process, never the actor. Every connection carries a generation number,
//// and messages from an older connection are ignored.
////
//// ```
//// connect ─► WebSocket ◄─ op 10 Hello
////                      ─► op 1 Heartbeat (jitter first, then every interval)
////                      ─► op 2 Identify, or op 6 Resume when a session exists
////                      ◄─ op 0 READY / RESUMED ─► Connected
////                      ◄─ op 0 events ─► subscribers
//// ```
////
//// Reconnection (PRD-D, 6.1): resume after a drop, a missed heartbeat ACK,
//// op 7 or a resumable op 9; identify again after a non-resumable op 9 or
//// close codes 4007 and 4009; stop for good on the fatal close codes (bad
//// token, bad intents, intents not enabled in the Developer Portal).

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/float
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import stratus

// ============================================================================
// Opcodes and intents
// ============================================================================

pub type Opcode {
  OpDispatch
  OpHeartbeat
  OpIdentify
  OpResume
  OpReconnect
  OpInvalidSession
  OpHello
  OpHeartbeatACK
}

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

pub type GatewayIntent {
  Guilds
  GuildMembers
  GuildBans
  GuildEmojis
  GuildIntegrations
  GuildWebhooks
  GuildInvites
  GuildVoiceStates
  GuildPresences
  GuildMessages
  GuildMessageReactions
  GuildMessageTyping
  DirectMessages
  DirectMessageReactions
  DirectMessageTyping
  MessageContent
  AutoModerationConfig
  AutoModerationExecution
}

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

pub fn combine_intents(intents: List(GatewayIntent)) -> Int {
  list.fold(intents, 0, fn(acc, intent) {
    int.bitwise_or(acc, intent_to_value(intent))
  })
}

pub fn basic_intents() -> Int {
  combine_intents([Guilds, GuildMessages])
}

/// What the Supernova needs: server messages with their text, and direct
/// messages. Without `DirectMessages`, nothing sent in private arrives.
pub fn message_content_intents() -> Int {
  combine_intents([Guilds, GuildMessages, DirectMessages, MessageContent])
}

// ============================================================================
// Types
// ============================================================================

pub type ConnectionStatus {
  Connecting
  Handshaking
  Identifying
  Connected
  Resuming
  Disconnected
  ConnectionError(reason: String)
}

pub type EventSubscription {
  EventSubscription(
    subscriber: Subject(DiscordEvent),
    event_filter: Option(String),
  )
}

pub type DiscordEvent {
  Ready(data: ReadyData)
  GuildCreate(data: JsonData)
  GuildDelete(data: JsonData)
  MessageCreate(data: JsonData)
  MessageUpdate(data: JsonData)
  MessageDelete(data: JsonData)
  RawEvent(event_name: String, data: JsonData)
}

pub type ReadyData {
  ReadyData(
    session_id: String,
    resume_gateway_url: String,
    user: UserData,
    guilds: List(JsonData),
  )
}

pub type UserData {
  UserData(id: String, username: String, discriminator: String, bot: Bool)
}

/// The `d` of a dispatch, as JSON text.
pub type JsonData =
  String

/// What the connection process can be asked to do.
pub opaque type Outbound {
  SendText(String)
  CloseWith(Int)
}

type Connection =
  Subject(stratus.InternalMessage(Outbound))

pub type Message {
  GetStatus(reply_to: Subject(ConnectionStatus))
  ConnectGateway(reply_to: Subject(Result(Nil, GatewayError)))
  DisconnectGateway(reply_to: Subject(Nil))
  ReconnectGateway(reply_to: Subject(Result(Nil, GatewayError)))
  Subscribe(
    reply_to: Subject(Int),
    subscriber: Subject(DiscordEvent),
    event_filter: Option(String),
  )
  Unsubscribe(reply_to: Subject(Bool), subscription_id: Int)
  GetSessionInfo(reply_to: Subject(Option(SessionInfo)))
  /// Runs one heartbeat check now (tests; the timer sends `HeartbeatDue`).
  HeartbeatTick(reply_to: Subject(Nil))
  /// A frame for the current connection (tests inject frames this way).
  WsMessage(data: String)
  Stop(reply_to: Subject(Nil))
  ConnUp(generation: Int, connection: Connection)
  ConnFrame(generation: Int, data: String)
  ConnClosed(generation: Int, code: Option(Int))
  ConnDown(generation: Int)
  HeartbeatDue(generation: Int)
  RetryConnect(generation: Int)
}

pub type SessionInfo {
  SessionInfo(session_id: String, sequence: Int, resume_gateway_url: String)
}

pub type Gateway =
  Subject(Message)

pub type GatewayError {
  ConfigError(message: String)
  WsError(message: String)
  AuthError(message: String)
  TimeoutError(message: String)
  RateLimitError(retry_after_ms: Int)
  SessionInvalid(resumable: Bool)
  MaxReconnectError(attempts: Int)
}

pub type GatewayConfig {
  GatewayConfig(
    token: String,
    intents: Int,
    app_id: Option(String),
    /// First wait before reconnecting; it doubles up to `max_backoff_ms`.
    reconnect_delay_ms: Int,
    /// Where to connect when there is no session to resume.
    url: String,
    /// Called on every status change, and on every heartbeat ACK while
    /// connected (the channel's liveness).
    on_status: fn(ConnectionStatus) -> Nil,
  )
}

pub const gateway_url = "wss://gateway.discord.gg/?v=10&encoding=json"

const default_heartbeat_interval = 45_000

const max_backoff_ms = 60_000

pub fn default_config(token: String) -> GatewayConfig {
  GatewayConfig(
    token: token,
    intents: basic_intents(),
    app_id: None,
    reconnect_delay_ms: 1000,
    url: gateway_url,
    on_status: fn(_) { Nil },
  )
}

pub fn config_with_intents(
  token: String,
  intents: List(GatewayIntent),
) -> GatewayConfig {
  GatewayConfig(..default_config(token), intents: combine_intents(intents))
}

type State {
  State(
    config: GatewayConfig,
    self: Subject(Message),
    status: ConnectionStatus,
    session_id: Option(String),
    sequence: Option(Int),
    resume_gateway_url: Option(String),
    heartbeat_interval_ms: Int,
    heartbeat_ack_received: Bool,
    reconnect_attempts: Int,
    subscribers: Dict(Int, EventSubscription),
    subscriber_counter: Int,
    connection: Option(Connection),
    generation: Int,
    /// The current connection should send Resume instead of Identify.
    resuming: Bool,
    /// Close code of the current connection, when the server sent one.
    close_code: Option(Int),
    /// False after `disconnect`, `stop` or a fatal close code.
    wanted: Bool,
  )
}

// ============================================================================
// Actor
// ============================================================================

pub fn start(config: GatewayConfig) -> Result(Gateway, actor.StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    State(
      config: config,
      self: self,
      status: Disconnected,
      session_id: None,
      sequence: None,
      resume_gateway_url: None,
      heartbeat_interval_ms: default_heartbeat_interval,
      heartbeat_ack_received: True,
      reconnect_attempts: 0,
      subscribers: dict.new(),
      subscriber_counter: 0,
      connection: None,
      generation: 0,
      resuming: False,
      close_code: None,
      wanted: False,
    )
    |> actor.initialised
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    GetStatus(reply_to) -> {
      process.send(reply_to, state.status)
      actor.continue(state)
    }

    ConnectGateway(reply_to) -> {
      process.send(reply_to, Ok(Nil))
      case state.connection {
        Some(_) -> actor.continue(state)
        None -> actor.continue(open(State(..state, wanted: True), False))
      }
    }

    ReconnectGateway(reply_to) -> {
      process.send(reply_to, Ok(Nil))
      let state = drop_connection(State(..state, wanted: True), 4000)
      actor.continue(open(state, has_session(state)))
    }

    DisconnectGateway(reply_to) -> {
      let state = drop_connection(State(..state, wanted: False), 1000)
      process.send(reply_to, Nil)
      actor.continue(set_status(state, Disconnected))
    }

    Subscribe(reply_to, subscriber, filter) -> {
      let id = state.subscriber_counter + 1
      process.send(reply_to, id)
      actor.continue(
        State(
          ..state,
          subscribers: dict.insert(
            state.subscribers,
            id,
            EventSubscription(subscriber, filter),
          ),
          subscriber_counter: id,
        ),
      )
    }

    Unsubscribe(reply_to, id) -> {
      process.send(reply_to, dict.has_key(state.subscribers, id))
      actor.continue(
        State(..state, subscribers: dict.delete(state.subscribers, id)),
      )
    }

    GetSessionInfo(reply_to) -> {
      let info = case
        state.session_id,
        state.sequence,
        state.resume_gateway_url
      {
        Some(session_id), Some(sequence), Some(url) ->
          Some(SessionInfo(session_id, sequence, url))
        _, _, _ -> None
      }
      process.send(reply_to, info)
      actor.continue(state)
    }

    HeartbeatTick(reply_to) -> {
      let state = heartbeat_check(state)
      process.send(reply_to, Nil)
      actor.continue(state)
    }

    HeartbeatDue(generation) ->
      case generation == state.generation && state.connection != None {
        False -> actor.continue(state)
        True -> {
          let state = heartbeat_check(state)
          case state.connection, generation == state.generation {
            Some(_), True -> {
              process.send_after(
                state.self,
                state.heartbeat_interval_ms,
                HeartbeatDue(generation),
              )
              Nil
            }
            _, _ -> Nil
          }
          actor.continue(state)
        }
      }

    WsMessage(data) -> actor.continue(handle_frame(state, data))

    ConnFrame(generation, data) ->
      case generation == state.generation {
        True -> actor.continue(handle_frame(state, data))
        False -> actor.continue(state)
      }

    ConnUp(generation, connection) ->
      case generation == state.generation && state.wanted {
        True -> actor.continue(State(..state, connection: Some(connection)))
        // An older connection, or one nobody wants anymore.
        False -> {
          process.send(connection, stratus.to_user_message(CloseWith(1000)))
          actor.continue(state)
        }
      }

    ConnClosed(generation, code) ->
      case generation == state.generation {
        True -> actor.continue(State(..state, close_code: code))
        False -> actor.continue(state)
      }

    ConnDown(generation) ->
      case generation == state.generation {
        True -> actor.continue(connection_lost(state))
        False -> actor.continue(state)
      }

    RetryConnect(generation) ->
      case
        generation == state.generation
        && state.wanted
        && state.connection == None
      {
        True -> actor.continue(open(state, has_session(state)))
        False -> actor.continue(state)
      }

    Stop(reply_to) -> {
      let _ = drop_connection(State(..state, wanted: False), 1000)
      process.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Connection lifecycle
// ============================================================================

fn has_session(state: State) -> Bool {
  option.is_some(state.session_id) && option.is_some(state.sequence)
}

/// Starts a new connection, resuming when asked and a session exists.
fn open(state: State, resume: Bool) -> State {
  let generation = state.generation + 1
  let resume = resume && has_session(state)
  let url = case resume, state.resume_gateway_url {
    True, Some(url) -> with_query(url)
    _, _ -> state.config.url
  }
  spawn_connection(state.self, generation, url)
  let state =
    State(
      ..state,
      generation: generation,
      connection: None,
      resuming: resume,
      close_code: None,
      heartbeat_ack_received: True,
    )
  case resume {
    True -> set_status(state, Resuming)
    False -> set_status(state, Connecting)
  }
}

/// `resume_gateway_url` comes without the version and encoding.
fn with_query(url: String) -> String {
  case string.contains(url, "?") {
    True -> url
    False ->
      case string.ends_with(url, "/") {
        True -> url <> "?v=10&encoding=json"
        False -> url <> "/?v=10&encoding=json"
      }
  }
}

/// Closes the current connection, if any, and forgets it. A code other than
/// 1000 and 1001 keeps the session resumable on Discord's side.
fn drop_connection(state: State, code: Int) -> State {
  case state.connection {
    Some(connection) ->
      process.send(connection, stratus.to_user_message(CloseWith(code)))
    None -> Nil
  }
  // A new generation makes the old connection's messages stale.
  State(..state, connection: None, generation: state.generation + 1)
}

/// The current connection ended. Decide, from the close code, whether to
/// resume, identify again or give up.
fn connection_lost(state: State) -> State {
  let state = State(..state, connection: None)
  case state.wanted, state.close_code {
    False, _ -> set_status(state, Disconnected)
    True, Some(code) ->
      case fatal_close_reason(code) {
        Some(reason) ->
          set_status(State(..state, wanted: False), ConnectionError(reason))
        None ->
          case code == 4007 || code == 4009 {
            True -> schedule_retry(forget_session(state))
            False -> schedule_retry(state)
          }
      }
    True, None -> schedule_retry(state)
  }
}

fn forget_session(state: State) -> State {
  State(..state, session_id: None, sequence: None, resume_gateway_url: None)
}

/// The close codes after which reconnecting cannot help.
pub fn fatal_close_reason(code: Int) -> Option(String) {
  case code {
    4004 -> Some("Discord recusou o token (4004)")
    4010 -> Some("shard inválido (4010)")
    4011 -> Some("o bot precisa de sharding (4011)")
    4012 -> Some("versão do gateway inválida (4012)")
    4013 -> Some("intents inválidas (4013)")
    4014 ->
      Some(
        "intents não autorizadas (4014): ligue a Message Content Intent no Developer Portal",
      )
    _ -> None
  }
}

fn schedule_retry(state: State) -> State {
  let delay =
    backoff_ms(state.config.reconnect_delay_ms, state.reconnect_attempts)
  process.send_after(state.self, delay, RetryConnect(state.generation))
  State(..state, reconnect_attempts: state.reconnect_attempts + 1)
  |> set_status(Disconnected)
}

/// The wait before reconnection attempt `attempts` (0-based): the base,
/// doubled each time, up to a minute.
pub fn backoff_ms(base: Int, attempts: Int) -> Int {
  let doubled =
    list.fold(list.repeat(Nil, int.min(attempts, 16)), base, fn(acc, _) {
      acc * 2
    })
  int.min(doubled, max_backoff_ms)
}

fn set_status(state: State, status: ConnectionStatus) -> State {
  case status == state.status {
    True -> state
    False -> {
      state.config.on_status(status)
      State(..state, status: status)
    }
  }
}

// ============================================================================
// Heartbeat
// ============================================================================

/// A heartbeat is due. Without an ACK for the previous one, the connection
/// is a zombie: drop it and resume.
fn heartbeat_check(state: State) -> State {
  case state.heartbeat_ack_received {
    True -> {
      send(state, heartbeat_payload_for(state.sequence))
      State(..state, heartbeat_ack_received: False)
    }
    False ->
      state
      |> drop_connection(4000)
      |> fn(state) { State(..state, close_code: None) }
      |> connection_lost
  }
}

fn send(state: State, payload: String) -> Nil {
  case state.connection {
    Some(connection) ->
      process.send(connection, stratus.to_user_message(SendText(payload)))
    None -> Nil
  }
}

// ============================================================================
// Frames
// ============================================================================

type Frame {
  Frame(op: Int, d: Dynamic, s: Option(Int), t: Option(String))
}

fn frame_decoder() -> decode.Decoder(Frame) {
  use op <- decode.field("op", decode.int)
  use d <- decode.optional_field("d", dynamic.nil(), decode.dynamic)
  use s <- decode.optional_field("s", None, decode.optional(decode.int))
  use t <- decode.optional_field("t", None, decode.optional(decode.string))
  decode.success(Frame(op: op, d: d, s: s, t: t))
}

fn handle_frame(state: State, data: String) -> State {
  case json.parse(data, frame_decoder()) {
    Error(_) -> state
    Ok(frame) -> {
      // Only dispatches (op 0) carry the sequence that heartbeats and
      // Resume must echo.
      let state = case frame.op, frame.s {
        0, Some(sequence) -> State(..state, sequence: Some(sequence))
        _, _ -> state
      }
      case int_to_opcode(frame.op) {
        Some(OpHello) -> hello(state, frame.d)
        Some(OpHeartbeat) -> {
          send(state, heartbeat_payload_for(state.sequence))
          state
        }
        Some(OpHeartbeatACK) -> {
          case state.status {
            Connected -> state.config.on_status(Connected)
            _ -> Nil
          }
          State(..state, heartbeat_ack_received: True)
        }
        Some(OpDispatch) -> dispatch(state, frame.t, frame.d)
        Some(OpReconnect) -> {
          let state = drop_connection(state, 4000)
          case state.wanted {
            True -> open(state, True)
            False -> set_status(state, Disconnected)
          }
        }
        Some(OpInvalidSession) -> invalid_session(state, frame.d)
        _ -> state
      }
    }
  }
}

fn hello(state: State, d: Dynamic) -> State {
  let interval =
    decode.run(d, decode.at(["heartbeat_interval"], decode.int))
    |> result.unwrap(default_heartbeat_interval)
  // The first heartbeat waits a random fraction of the interval.
  let first = float.truncate(float.random() *. int.to_float(interval))
  process.send_after(state.self, first, HeartbeatDue(state.generation))
  let state =
    State(
      ..state,
      heartbeat_interval_ms: interval,
      heartbeat_ack_received: True,
    )
  case state.resuming, state.session_id, state.sequence {
    True, Some(session_id), Some(sequence) -> {
      send(state, resume_payload(state.config.token, session_id, sequence))
      set_status(state, Resuming)
    }
    _, _, _ -> {
      send(state, identify_payload(state.config.token, state.config.intents))
      set_status(state, Identifying)
    }
  }
}

fn invalid_session(state: State, d: Dynamic) -> State {
  let resumable = decode.run(d, decode.bool) |> result.unwrap(False)
  let state = drop_connection(state, 4000)
  case resumable, state.wanted {
    _, False ->
      case resumable {
        True -> set_status(state, Disconnected)
        False -> set_status(forget_session(state), Disconnected)
      }
    True, True -> open(state, True)
    False, True -> {
      // Discord asks for a wait of 1 to 5 seconds before identifying again
      // (with the default base of 1 s).
      let state = forget_session(state)
      let base = state.config.reconnect_delay_ms
      process.send_after(
        state.self,
        base + int.random(4 * base + 1),
        RetryConnect(state.generation),
      )
      set_status(state, Disconnected)
    }
  }
}

fn dispatch(state: State, event: Option(String), d: Dynamic) -> State {
  let data = encode_json(d)
  case event {
    Some("READY") ->
      case decode.run(d, ready_decoder()) {
        Ok(ready) -> {
          notify(state, Ready(ready))
          State(
            ..state,
            session_id: Some(ready.session_id),
            resume_gateway_url: Some(ready.resume_gateway_url),
            reconnect_attempts: 0,
          )
          |> set_status(Connected)
        }
        Error(_) -> state
      }
    Some("RESUMED") ->
      State(..state, reconnect_attempts: 0) |> set_status(Connected)
    Some("GUILD_CREATE") -> notify_and_keep(state, GuildCreate(data))
    Some("GUILD_DELETE") -> notify_and_keep(state, GuildDelete(data))
    Some("MESSAGE_CREATE") -> notify_and_keep(state, MessageCreate(data))
    Some("MESSAGE_UPDATE") -> notify_and_keep(state, MessageUpdate(data))
    Some("MESSAGE_DELETE") -> notify_and_keep(state, MessageDelete(data))
    Some(name) -> notify_and_keep(state, RawEvent(name, data))
    None -> state
  }
}

fn notify_and_keep(state: State, event: DiscordEvent) -> State {
  notify(state, event)
  state
}

fn ready_decoder() -> decode.Decoder(ReadyData) {
  use session_id <- decode.field("session_id", decode.string)
  use resume_gateway_url <- decode.optional_field(
    "resume_gateway_url",
    "",
    decode.string,
  )
  use user <- decode.field("user", user_decoder())
  use guilds <- decode.optional_field(
    "guilds",
    [],
    decode.list(decode.map(decode.dynamic, encode_json)),
  )
  decode.success(ReadyData(
    session_id: session_id,
    resume_gateway_url: resume_gateway_url,
    user: user,
    guilds: guilds,
  ))
}

fn user_decoder() -> decode.Decoder(UserData) {
  use id <- decode.field("id", decode.string)
  use username <- decode.optional_field("username", "", decode.string)
  use discriminator <- decode.optional_field(
    "discriminator",
    "0",
    decode.string,
  )
  use bot <- decode.optional_field("bot", False, decode.bool)
  decode.success(UserData(
    id: id,
    username: username,
    discriminator: discriminator,
    bot: bot,
  ))
}

@external(erlang, "supernova_discord_ffi", "encode_json")
fn encode_json(term: Dynamic) -> String

fn notify(state: State, event: DiscordEvent) -> Nil {
  let name = event_to_name(event)
  dict.values(state.subscribers)
  |> list.each(fn(subscription) {
    case subscription.event_filter {
      None -> process.send(subscription.subscriber, event)
      Some(filter) if filter == name ->
        process.send(subscription.subscriber, event)
      Some(_) -> Nil
    }
  })
}

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
// Payloads
// ============================================================================

pub fn identify_payload(token: String, intents: Int) -> String {
  json.object([
    #("op", json.int(2)),
    #(
      "d",
      json.object([
        #("token", json.string(token)),
        #("intents", json.int(intents)),
        #(
          "properties",
          json.object([
            #("os", json.string("linux")),
            #("browser", json.string("supernova")),
            #("device", json.string("supernova")),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

pub fn heartbeat_payload(sequence: Int) -> String {
  heartbeat_payload_for(Some(sequence))
}

/// Before the first dispatch there is no sequence, and Discord expects null.
fn heartbeat_payload_for(sequence: Option(Int)) -> String {
  json.object([#("op", json.int(1)), #("d", json.nullable(sequence, json.int))])
  |> json.to_string
}

pub fn resume_payload(
  token: String,
  session_id: String,
  sequence: Int,
) -> String {
  json.object([
    #("op", json.int(6)),
    #(
      "d",
      json.object([
        #("token", json.string(token)),
        #("session_id", json.string(session_id)),
        #("seq", json.int(sequence)),
      ]),
    ),
  ])
  |> json.to_string
}

// ============================================================================
// Connection process
// ============================================================================

type Watch {
  SocketExited(Pid)
  GatewayGone
}

/// Runs one WebSocket under a process not linked to the gateway actor. It
/// reports `ConnUp`, every text frame, the close code and the end
/// (`ConnDown`). If the gateway actor dies, the socket is closed.
fn spawn_connection(gateway: Gateway, generation: Int, url: String) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      case websocket_request(url) {
        Error(_) -> process.send(gateway, ConnDown(generation))
        Ok(req) -> {
          let builder =
            stratus.new(request: req, state: Nil)
            |> stratus.with_connect_timeout(10_000)
            |> stratus.on_message(fn(state, message, connection) {
              case message {
                stratus.Text(text) -> {
                  process.send(gateway, ConnFrame(generation, text))
                  stratus.continue(state)
                }
                stratus.Binary(_) -> stratus.continue(state)
                stratus.User(SendText(text)) -> {
                  let _ = stratus.send_text_message(connection, text)
                  stratus.continue(state)
                }
                stratus.User(CloseWith(code)) -> {
                  let _ = stratus.close_custom(connection, code, <<>>)
                  stratus.stop()
                }
              }
            })
            |> stratus.on_close(fn(_state, reason) {
              process.send(gateway, ConnClosed(generation, close_code(reason)))
            })
          case stratus.start(builder) {
            Error(_) -> process.send(gateway, ConnDown(generation))
            Ok(started) -> {
              process.send(gateway, ConnUp(generation, started.data))
              watch(gateway, started.pid, started.data)
              process.send(gateway, ConnDown(generation))
            }
          }
        }
      }
    })
  Nil
}

fn watch(gateway: Gateway, socket: Pid, connection: Connection) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_trapped_exits(fn(exit) { SocketExited(exit.pid) })
  let selector = case process.subject_owner(gateway) {
    Ok(owner) ->
      process.select_specific_monitor(selector, process.monitor(owner), fn(_) {
        GatewayGone
      })
    Error(_) -> selector
  }
  wait(selector, socket, connection)
}

fn wait(
  selector: process.Selector(Watch),
  socket: Pid,
  connection: Connection,
) -> Nil {
  case process.selector_receive_forever(selector) {
    SocketExited(pid) if pid == socket -> Nil
    SocketExited(_) -> wait(selector, socket, connection)
    GatewayGone -> {
      process.send(connection, stratus.to_user_message(CloseWith(1000)))
      wait(selector, socket, connection)
    }
  }
}

/// `stratus` speaks http(s) URLs: wss becomes https, ws becomes http.
fn websocket_request(url: String) -> Result(request.Request(String), Nil) {
  let url = case url {
    "wss://" <> rest -> "https://" <> rest
    "ws://" <> rest -> "http://" <> rest
    other -> other
  }
  request.to(url)
}

fn close_code(reason: stratus.CloseReason) -> Option(Int) {
  case reason {
    stratus.Custom(custom) -> Some(stratus.get_custom_code(custom))
    stratus.Normal(_) -> Some(1000)
    stratus.GoingAway(_) -> Some(1001)
    stratus.ProtocolError(_) -> Some(1002)
    stratus.UnexpectedDataType(_) -> Some(1003)
    stratus.InconsistentDataType(_) -> Some(1007)
    stratus.PolicyViolation(_) -> Some(1008)
    stratus.MessageTooBig(_) -> Some(1009)
    stratus.MissingExtensions(_) -> Some(1010)
    stratus.UnexpectedCondition(_) -> Some(1011)
    stratus.NotProvided -> None
  }
}

// ============================================================================
// Public API
// ============================================================================

pub fn get_status(gateway: Gateway) -> ConnectionStatus {
  actor.call(gateway, waiting: 5000, sending: GetStatus)
}

/// Starts connecting in the background. The result says only that the
/// request was taken: readiness comes through `on_status`.
pub fn connect(gateway: Gateway) -> Result(Nil, GatewayError) {
  actor.call(gateway, waiting: 10_000, sending: ConnectGateway)
}

pub fn disconnect(gateway: Gateway) -> Nil {
  actor.call(gateway, waiting: 5000, sending: DisconnectGateway)
}

pub fn reconnect(gateway: Gateway) -> Result(Nil, GatewayError) {
  actor.call(gateway, waiting: 10_000, sending: ReconnectGateway)
}

pub fn subscribe(gateway: Gateway, subscriber: Subject(DiscordEvent)) -> Int {
  actor.call(gateway, waiting: 5000, sending: Subscribe(_, subscriber, None))
}

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

pub fn unsubscribe(gateway: Gateway, subscription_id: Int) -> Bool {
  actor.call(gateway, waiting: 5000, sending: Unsubscribe(_, subscription_id))
}

pub fn get_session_info(gateway: Gateway) -> Option(SessionInfo) {
  actor.call(gateway, waiting: 5000, sending: GetSessionInfo)
}

pub fn stop(gateway: Gateway) -> Nil {
  actor.call(gateway, waiting: 5000, sending: Stop)
}

// ============================================================================
// Utility Functions
// ============================================================================

pub fn is_connected(status: ConnectionStatus) -> Bool {
  status == Connected
}

pub fn is_error(status: ConnectionStatus) -> Bool {
  case status {
    ConnectionError(_) -> True
    _ -> False
  }
}

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
