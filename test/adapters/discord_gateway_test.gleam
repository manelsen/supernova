//// Tests for Discord Gateway module

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/adapters/discord_gateway as gateway

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Intent Tests
// ============================================================================

pub fn intent_to_value_guilds_test() {
  gateway.intent_to_value(gateway.Guilds)
  |> should.equal(1)
}

pub fn intent_to_value_guild_messages_test() {
  gateway.intent_to_value(gateway.GuildMessages)
  |> should.equal(512)
}

pub fn intent_to_value_message_content_test() {
  gateway.intent_to_value(gateway.MessageContent)
  |> should.equal(32_768)
}

pub fn intent_to_value_guild_members_test() {
  gateway.intent_to_value(gateway.GuildMembers)
  |> should.equal(2)
}

pub fn combine_intents_single_test() {
  gateway.combine_intents([gateway.Guilds])
  |> should.equal(1)
}

pub fn combine_intents_multiple_test() {
  gateway.combine_intents([gateway.Guilds, gateway.GuildMessages])
  |> should.equal(513)
}

pub fn combine_intents_three_test() {
  gateway.combine_intents([
    gateway.Guilds,
    gateway.GuildMessages,
    gateway.MessageContent,
  ])
  |> should.equal(33_281)
}

pub fn basic_intents_value_test() {
  gateway.basic_intents()
  |> should.equal(513)
}

pub fn message_content_intents_value_test() {
  gateway.message_content_intents()
  |> should.equal(33_281)
}

// ============================================================================
// Configuration Tests
// ============================================================================

pub fn default_config_test() {
  let config = gateway.default_config("test_token")

  config.token
  |> should.equal("test_token")

  config.intents
  |> should.equal(513)

  config.max_reconnect_attempts
  |> should.equal(5)

  config.reconnect_delay_ms
  |> should.equal(5000)
}

pub fn config_with_intents_test() {
  let config =
    gateway.config_with_intents("test_token", [
      gateway.Guilds,
      gateway.GuildMessages,
      gateway.DirectMessages,
    ])

  config.token
  |> should.equal("test_token")

  config.intents
  |> should.equal(4609)
  // 1 + 512 + 4096
}

// ============================================================================
// Status Tests
// ============================================================================

pub fn is_connected_when_connected_test() {
  gateway.is_connected(gateway.Connected)
  |> should.equal(True)
}

pub fn is_connected_when_disconnected_test() {
  gateway.is_connected(gateway.Disconnected)
  |> should.equal(False)
}

pub fn is_connected_when_connecting_test() {
  gateway.is_connected(gateway.Connecting)
  |> should.equal(False)
}

pub fn is_connected_when_error_test() {
  gateway.is_connected(gateway.ConnectionError("test"))
  |> should.equal(False)
}

pub fn is_error_when_error_test() {
  gateway.is_error(gateway.ConnectionError("test"))
  |> should.equal(True)
}

pub fn is_error_when_connected_test() {
  gateway.is_error(gateway.Connected)
  |> should.equal(False)
}

pub fn status_to_string_connected_test() {
  gateway.status_to_string(gateway.Connected)
  |> should.equal("Connected")
}

pub fn status_to_string_disconnected_test() {
  gateway.status_to_string(gateway.Disconnected)
  |> should.equal("Disconnected")
}

pub fn status_to_string_connecting_test() {
  gateway.status_to_string(gateway.Connecting)
  |> should.equal("Connecting")
}

pub fn status_to_string_error_test() {
  gateway.status_to_string(gateway.ConnectionError("test error"))
  |> should.equal("Error: test error")
}

pub fn status_to_string_resuming_test() {
  gateway.status_to_string(gateway.Resuming)
  |> should.equal("Resuming")
}

pub fn status_to_string_identifying_test() {
  gateway.status_to_string(gateway.Identifying)
  |> should.equal("Identifying")
}

pub fn status_to_string_handshaking_test() {
  gateway.status_to_string(gateway.Handshaking)
  |> should.equal("Handshaking")
}

// ============================================================================
// Error Tests
// ============================================================================

pub fn error_to_string_config_error_test() {
  gateway.error_to_string(gateway.ConfigError("bad config"))
  |> should.equal("Config Error: bad config")
}

pub fn error_to_string_ws_error_test() {
  gateway.error_to_string(gateway.WsError("connection failed"))
  |> should.equal("WebSocket Error: connection failed")
}

pub fn error_to_string_auth_error_test() {
  gateway.error_to_string(gateway.AuthError("invalid token"))
  |> should.equal("Auth Error: invalid token")
}

pub fn error_to_string_timeout_error_test() {
  gateway.error_to_string(gateway.TimeoutError("timed out"))
  |> should.equal("Timeout Error: timed out")
}

pub fn error_to_string_rate_limit_error_test() {
  gateway.error_to_string(gateway.RateLimitError(5000))
  |> should.equal("Rate Limited (retry after: 5000ms)")
}

pub fn error_to_string_invalid_session_resumable_test() {
  gateway.error_to_string(gateway.SessionInvalid(True))
  |> should.equal("Invalid Session (resumable)")
}

pub fn error_to_string_invalid_session_not_resumable_test() {
  gateway.error_to_string(gateway.SessionInvalid(False))
  |> should.equal("Invalid Session (not resumable)")
}

pub fn error_to_string_max_reconnect_error_test() {
  gateway.error_to_string(gateway.MaxReconnectError(5))
  |> should.equal("Max Reconnect Attempts (5)")
}

// ============================================================================
// Actor Tests
// ============================================================================

pub fn start_gateway_actor_test() {
  let config = gateway.default_config("test_token")
  let result = gateway.start(config)

  result
  |> should.be_ok()

  case result {
    Ok(gw) -> {
      gateway.stop(gw)
    }
    Error(_) -> Nil
  }
}

pub fn get_status_initial_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  let status = gateway.get_status(gw)
  status
  |> should.equal(gateway.Disconnected)

  gateway.stop(gw)
}

pub fn disconnect_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  gateway.disconnect(gw)

  let status = gateway.get_status(gw)
  status
  |> should.equal(gateway.Disconnected)

  gateway.stop(gw)
}

pub fn get_session_info_initial_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  let info = gateway.get_session_info(gw)
  info
  |> should.equal(None)

  gateway.stop(gw)
}

pub fn subscribe_returns_id_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  let subject = process.new_subject()
  let sub_id = gateway.subscribe(gw, subject)

  should.equal(sub_id >= 1, True)

  gateway.stop(gw)
}

pub fn subscribe_multiple_returns_incrementing_ids_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  let subject1 = process.new_subject()
  let subject2 = process.new_subject()
  let subject3 = process.new_subject()

  let id1 = gateway.subscribe(gw, subject1)
  let id2 = gateway.subscribe(gw, subject2)
  let id3 = gateway.subscribe(gw, subject3)

  should.equal(id1 >= 1, True)
  should.equal(id2 > id1, True)
  should.equal(id3 > id2, True)

  gateway.stop(gw)
}

pub fn unsubscribe_existing_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  let subject = process.new_subject()
  let sub_id = gateway.subscribe(gw, subject)

  let result = gateway.unsubscribe(gw, sub_id)
  result
  |> should.equal(True)

  gateway.stop(gw)
}

pub fn unsubscribe_nonexistent_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  let result = gateway.unsubscribe(gw, 999)
  result
  |> should.equal(False)

  gateway.stop(gw)
}

pub fn subscribe_to_event_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  let subject = process.new_subject()
  let sub_id = gateway.subscribe_to_event(gw, subject, "MESSAGE_CREATE")

  should.equal(sub_id >= 1, True)

  gateway.stop(gw)
}

pub fn connect_sets_status_to_connecting_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  gateway.connect(gw)
  |> should.equal(Ok(Nil))
  gateway.get_status(gw)
  |> should.equal(gateway.Connecting)

  gateway.stop(gw)
}

pub fn reconnect_without_session_starts_fresh_connect_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  gateway.reconnect(gw)
  |> should.equal(Ok(Nil))
  gateway.get_status(gw)
  |> should.equal(gateway.Connecting)

  gateway.stop(gw)
}

pub fn ws_hello_moves_gateway_to_identifying_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  process.send(
    gw,
    gateway.WsMessage("{\"op\":10,\"d\":{\"heartbeat_interval\":12345}}"),
  )

  gateway.get_status(gw)
  |> should.equal(gateway.Identifying)

  gateway.stop(gw)
}

pub fn ws_ready_dispatch_sets_connected_and_session_info_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)
  let subscriber = process.new_subject()
  let _ = gateway.subscribe(gw, subscriber)

  process.send(
    gw,
    gateway.WsMessage(
      "{\"op\":0,\"d\":{\"session_id\":\"sess-1\",\"resume_gateway_url\":\"wss://resume.gateway\",\"user\":{\"id\":\"u1\",\"username\":\"alice\",\"discriminator\":\"1234\",\"bot\":true}},\"s\":7,\"t\":\"READY\"}",
    ),
  )

  gateway.get_status(gw)
  |> should.equal(gateway.Connected)
  gateway.get_session_info(gw)
  |> should.equal(
    Some(gateway.SessionInfo(
      session_id: "sess-1",
      sequence: 7,
      resume_gateway_url: "wss://resume.gateway",
    )),
  )

  let assert Ok(event) = process.receive(subscriber, within: 1000)
  case event {
    gateway.Ready(data) -> {
      data.session_id |> should.equal("sess-1")
      data.user.username |> should.equal("alice")
    }
    _ -> should.fail()
  }

  gateway.stop(gw)
}

pub fn ws_dispatch_notifies_filtered_subscriber_only_for_matching_event_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)
  let subscriber = process.new_subject()
  let _ = gateway.subscribe_to_event(gw, subscriber, "MESSAGE_CREATE")

  process.send(
    gw,
    gateway.WsMessage(
      "{\"op\":0,\"d\":{\"id\":\"m1\",\"content\":\"hello\"},\"s\":9,\"t\":\"MESSAGE_CREATE\"}",
    ),
  )

  let assert Ok(event) = process.receive(subscriber, within: 1000)
  case event {
    gateway.MessageCreate(payload) -> {
      string.contains(payload, "\"content\":\"hello\"")
      |> should.equal(True)
    }
    _ -> should.fail()
  }

  gateway.stop(gw)
}

pub fn ws_dispatch_unknown_event_emits_raw_event_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)
  let subscriber = process.new_subject()
  let _ = gateway.subscribe(gw, subscriber)

  process.send(
    gw,
    gateway.WsMessage(
      "{\"op\":0,\"d\":{\"k\":\"v\"},\"s\":10,\"t\":\"SOMETHING_ELSE\"}",
    ),
  )

  let assert Ok(event) = process.receive(subscriber, within: 1000)
  case event {
    gateway.RawEvent(name, payload) -> {
      name |> should.equal("SOMETHING_ELSE")
      string.contains(payload, "\"k\":\"v\"") |> should.equal(True)
    }
    _ -> should.fail()
  }

  gateway.stop(gw)
}

pub fn ws_reconnect_opcode_sets_disconnected_status_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)
  let _ = gateway.connect(gw)

  process.send(gw, gateway.WsMessage("{\"op\":7,\"d\":{},\"s\":11}"))

  gateway.get_status(gw)
  |> should.equal(gateway.Disconnected)

  gateway.stop(gw)
}

pub fn ws_invalid_session_non_resumable_clears_session_info_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  process.send(
    gw,
    gateway.WsMessage(
      "{\"op\":0,\"d\":{\"session_id\":\"sess-2\",\"resume_gateway_url\":\"wss://resume.gateway\",\"user\":{\"id\":\"u2\",\"username\":\"bob\",\"discriminator\":\"0001\",\"bot\":false}},\"s\":13,\"t\":\"READY\"}",
    ),
  )
  process.send(gw, gateway.WsMessage("{\"op\":9,\"d\":false,\"s\":14}"))

  gateway.get_status(gw)
  |> should.equal(gateway.ConnectionError("Invalid session"))
  gateway.get_session_info(gw)
  |> should.equal(None)

  gateway.stop(gw)
}

pub fn ws_invalid_session_resumable_keeps_session_info_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)

  process.send(
    gw,
    gateway.WsMessage(
      "{\"op\":0,\"d\":{\"session_id\":\"sess-3\",\"resume_gateway_url\":\"wss://resume.gateway\",\"user\":{\"id\":\"u3\",\"username\":\"carol\",\"discriminator\":\"0002\",\"bot\":false}},\"s\":21,\"t\":\"READY\"}",
    ),
  )
  process.send(gw, gateway.WsMessage("{\"op\":9,\"d\":true,\"s\":22}"))

  gateway.get_session_info(gw)
  |> should.equal(
    Some(gateway.SessionInfo(
      session_id: "sess-3",
      sequence: 21,
      resume_gateway_url: "wss://resume.gateway",
    )),
  )

  gateway.stop(gw)
}

pub fn double_heartbeat_without_ack_marks_zombie_connection_test() {
  let config = gateway.default_config("test_token")
  let assert Ok(gw) = gateway.start(config)
  let reply_one = process.new_subject()
  let reply_two = process.new_subject()

  process.send(gw, gateway.HeartbeatTick(reply_to: reply_one))
  let assert Ok(_) = process.receive(reply_one, within: 1000)

  process.send(gw, gateway.HeartbeatTick(reply_to: reply_two))
  let assert Ok(_) = process.receive(reply_two, within: 1000)

  gateway.get_status(gw)
  |> should.equal(gateway.ConnectionError("Zombie connection"))

  gateway.stop(gw)
}

// ============================================================================
// JSON Payload Tests
// ============================================================================

pub fn identify_payload_format_test() {
  let payload = gateway.identify_payload("test_token", 513)

  should.equal(string.contains(payload, "\"op\":2"), True)
  should.equal(string.contains(payload, "\"token\":\"test_token\""), True)
  should.equal(string.contains(payload, "\"intents\":513"), True)
  should.equal(string.contains(payload, "\"properties\""), True)
  should.equal(string.contains(payload, "\"os\":\"linux\""), True)
  should.equal(string.contains(payload, "\"browser\":\"supernova\""), True)
}

pub fn heartbeat_payload_format_test() {
  let payload = gateway.heartbeat_payload(42)

  should.equal(string.contains(payload, "\"op\":1"), True)
  should.equal(string.contains(payload, "\"d\":42"), True)
}

pub fn heartbeat_payload_zero_sequence_test() {
  let payload = gateway.heartbeat_payload(0)

  should.equal(string.contains(payload, "\"d\":0"), True)
}

pub fn resume_payload_format_test() {
  let payload = gateway.resume_payload("test_token", "session123", 100)

  should.equal(string.contains(payload, "\"op\":6"), True)
  should.equal(string.contains(payload, "\"token\":\"test_token\""), True)
  should.equal(string.contains(payload, "\"session_id\":\"session123\""), True)
  should.equal(string.contains(payload, "\"seq\":100"), True)
}

// ============================================================================
// Event Data Tests
// ============================================================================

pub fn ready_data_construction_test() {
  let event =
    gateway.Ready(
      gateway.ReadyData(
        session_id: "test_session",
        resume_gateway_url: "wss://test.gateway",
        user: gateway.UserData(
          id: "1",
          username: "test",
          discriminator: "0000",
          bot: True,
        ),
        guilds: [],
      ),
    )

  case event {
    gateway.Ready(data) -> {
      data.session_id
      |> should.equal("test_session")
    }
  }
}

pub fn guild_create_event_test() {
  let event = gateway.GuildCreate("{\"id\":\"123\"}")

  case event {
    gateway.GuildCreate(data) -> {
      data
      |> should.equal("{\"id\":\"123\"}")
    }
  }
}

pub fn message_create_event_test() {
  let event = gateway.MessageCreate("{\"content\":\"hello\"}")

  case event {
    gateway.MessageCreate(data) -> {
      data
      |> should.equal("{\"content\":\"hello\"}")
    }
  }
}
