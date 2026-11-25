//// The gateway against a local WebSocket fake (`test/discord_fake.gleam`):
//// connection, Identify, READY, heartbeats, resume and the close codes.

import discord_fake
import gleam/erlang/process
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import supernova/adapters/discord_events as events
import supernova/adapters/discord_gateway as gateway

fn config(fake: discord_fake.Fake, statuses) -> gateway.GatewayConfig {
  gateway.GatewayConfig(
    ..gateway.default_config("token-de-teste"),
    intents: gateway.message_content_intents(),
    url: fake.url,
    reconnect_delay_ms: 10,
    on_status: fn(status) { process.send(statuses, status) },
  )
}

/// Connect and get to READY: returns the gateway and the connection.
fn ready(
  fake: discord_fake.Fake,
  statuses,
  interval: Int,
) -> #(gateway.Gateway, process.Pid) {
  let assert Ok(gw) = gateway.start(config(fake, statuses))
  let assert Ok(Nil) = gateway.connect(gw)
  let conn = discord_fake.expect_connection(fake, 2000)
  discord_fake.send_text(conn, discord_fake.hello(interval))
  let _identify = discord_fake.expect_op(fake, 2, 2000)
  discord_fake.send_text(
    conn,
    discord_fake.ready("sess-1", discord_fake.resume_url(fake), 1),
  )
  wait_status(statuses, gateway.Connected)
  #(gw, conn)
}

fn wait_status(statuses, wanted: gateway.ConnectionStatus) -> Nil {
  case process.receive(statuses, 3000) {
    Ok(status) if status == wanted -> Nil
    Ok(_) -> wait_status(statuses, wanted)
    Error(_) ->
      panic as { "status never reached " <> gateway.status_to_string(wanted) }
  }
}

pub fn connect_identifies_with_token_and_intents_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let assert Ok(gw) = gateway.start(config(fake, statuses))
  let assert Ok(Nil) = gateway.connect(gw)
  let conn = discord_fake.expect_connection(fake, 2000)
  discord_fake.send_text(conn, discord_fake.hello(60_000))

  let identify = discord_fake.expect_op(fake, 2, 2000)
  discord_fake.d_string(identify, "token")
  |> should.equal(Some("token-de-teste"))
  // Guilds | GuildMessages | DirectMessages | MessageContent
  discord_fake.d_int(identify, "intents") |> should.equal(Some(37_377))
  gateway.get_status(gw) |> should.equal(gateway.Identifying)
  gateway.stop(gw)
}

pub fn ready_marks_connected_and_notifies_subscribers_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let assert Ok(gw) = gateway.start(config(fake, statuses))
  let subscriber = process.new_subject()
  let _ = gateway.subscribe(gw, subscriber)
  let assert Ok(Nil) = gateway.connect(gw)
  let conn = discord_fake.expect_connection(fake, 2000)
  discord_fake.send_text(conn, discord_fake.hello(60_000))
  let _ = discord_fake.expect_op(fake, 2, 2000)
  discord_fake.send_text(
    conn,
    discord_fake.ready("sess-1", discord_fake.resume_url(fake), 1),
  )

  wait_status(statuses, gateway.Connected)
  let assert Ok(gateway.Ready(data)) = process.receive(subscriber, 2000)
  data.session_id |> should.equal("sess-1")
  data.user.username |> should.equal("supernova")
  gateway.stop(gw)
}

pub fn message_text_with_quotes_and_newlines_survives_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, conn) = ready(fake, statuses, 60_000)
  let subscriber = process.new_subject()
  let _ = gateway.subscribe(gw, subscriber)

  discord_fake.send_text(
    conn,
    discord_fake.dispatch(
      "MESSAGE_CREATE",
      "{\"id\":\"1\",\"channel_id\":\"2\",\"content\":\"ela disse \\\"oi\\\"\\nlinha 2 \\u00e9\",\"timestamp\":\"2026-11-25T00:00:00Z\",\"author\":{\"id\":\"3\",\"username\":\"u\"}}",
      2,
    ),
  )

  let assert Ok(gateway.MessageCreate(data)) = process.receive(subscriber, 2000)
  let assert events.EventMessageCreate(message) =
    events.parse_event("MESSAGE_CREATE", data)
  message.content |> should.equal("ela disse \"oi\"\nlinha 2 é")
  gateway.stop(gw)
}

pub fn heartbeats_carry_the_last_sequence_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, conn) = ready(fake, statuses, 50)

  let beat = discord_fake.expect_op(fake, 1, 2000)
  beat |> should.equal("{\"op\":1,\"d\":1}")
  discord_fake.send_text(conn, discord_fake.heartbeat_ack())
  let _ = discord_fake.expect_op(fake, 1, 2000)
  gateway.stop(gw)
}

pub fn server_heartbeat_request_is_answered_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, conn) = ready(fake, statuses, 60_000)

  discord_fake.send_text(conn, "{\"op\":1,\"d\":null}")
  discord_fake.expect_op(fake, 1, 2000) |> should.equal("{\"op\":1,\"d\":1}")
  gateway.stop(gw)
}

pub fn missed_ack_resumes_on_a_new_connection_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, _conn) = ready(fake, statuses, 50)

  // No ACK for the first heartbeat: the next one finds a zombie.
  let conn = discord_fake.expect_connection(fake, 3000)
  discord_fake.send_text(conn, discord_fake.hello(60_000))
  let resume = discord_fake.expect_op(fake, 6, 2000)
  discord_fake.d_string(resume, "session_id") |> should.equal(Some("sess-1"))
  discord_fake.d_int(resume, "seq") |> should.equal(Some(1))
  discord_fake.send_text(conn, discord_fake.resumed(2))
  wait_status(statuses, gateway.Connected)
  gateway.stop(gw)
}

pub fn reconnect_opcode_resumes_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, conn) = ready(fake, statuses, 60_000)

  discord_fake.send_text(conn, discord_fake.reconnect())
  let conn = discord_fake.expect_connection(fake, 2000)
  discord_fake.send_text(conn, discord_fake.hello(60_000))
  let _ = discord_fake.expect_op(fake, 6, 2000)
  gateway.stop(gw)
}

pub fn resumable_invalid_session_resumes_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, conn) = ready(fake, statuses, 60_000)

  discord_fake.send_text(conn, discord_fake.invalid_session(True))
  let conn = discord_fake.expect_connection(fake, 2000)
  discord_fake.send_text(conn, discord_fake.hello(60_000))
  let _ = discord_fake.expect_op(fake, 6, 2000)
  gateway.stop(gw)
}

pub fn non_resumable_invalid_session_identifies_again_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, conn) = ready(fake, statuses, 60_000)

  discord_fake.send_text(conn, discord_fake.invalid_session(False))
  let conn = discord_fake.expect_connection(fake, 2000)
  discord_fake.send_text(conn, discord_fake.hello(60_000))
  let _ = discord_fake.expect_op(fake, 2, 2000)
  gateway.get_session_info(gw) |> should.equal(option.None)
  gateway.stop(gw)
}

pub fn dropped_connection_resumes_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, conn) = ready(fake, statuses, 60_000)

  discord_fake.drop(conn)
  wait_status(statuses, gateway.Disconnected)
  let conn = discord_fake.expect_connection(fake, 2000)
  discord_fake.send_text(conn, discord_fake.hello(60_000))
  let _ = discord_fake.expect_op(fake, 6, 2000)
  gateway.stop(gw)
}

pub fn session_timeout_close_identifies_again_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, conn) = ready(fake, statuses, 60_000)

  discord_fake.close(conn, 4009)
  let conn = discord_fake.expect_connection(fake, 2000)
  discord_fake.send_text(conn, discord_fake.hello(60_000))
  let _ = discord_fake.expect_op(fake, 2, 2000)
  gateway.stop(gw)
}

pub fn disallowed_intents_close_stops_for_good_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, conn) = ready(fake, statuses, 60_000)

  discord_fake.close(conn, 4014)
  let reason = case process.receive(statuses, 2000) {
    Ok(gateway.ConnectionError(reason)) -> reason
    _ -> wait_error(statuses)
  }
  string.contains(reason, "Message Content Intent") |> should.be_true
  // No new connection.
  let _ = discord_fake.expect_closed(fake, 1000)
  discord_fake.expect_quiet(fake, 300)
  gateway.stop(gw)
}

fn wait_error(statuses) -> String {
  case process.receive(statuses, 2000) {
    Ok(gateway.ConnectionError(reason)) -> reason
    Ok(_) -> wait_error(statuses)
    Error(_) -> panic as "no ConnectionError"
  }
}

pub fn bad_token_close_stops_for_good_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, conn) = ready(fake, statuses, 60_000)

  discord_fake.close(conn, 4004)
  string.contains(wait_error(statuses), "token") |> should.be_true
  gateway.stop(gw)
}

pub fn disconnect_closes_and_stays_down_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, _conn) = ready(fake, statuses, 60_000)

  gateway.disconnect(gw)
  let _ = discord_fake.expect_closed(fake, 2000)
  discord_fake.expect_quiet(fake, 300)
  gateway.get_status(gw) |> should.equal(gateway.Disconnected)
  gateway.stop(gw)
}

pub fn stop_closes_the_connection_test() {
  let fake = discord_fake.start()
  let statuses = process.new_subject()
  let #(gw, _conn) = ready(fake, statuses, 60_000)

  gateway.stop(gw)
  let _ = discord_fake.expect_closed(fake, 2000)
  Nil
}

pub fn unreachable_gateway_keeps_retrying_test() {
  let statuses = process.new_subject()
  let config =
    gateway.GatewayConfig(
      ..gateway.default_config("t"),
      url: "ws://127.0.0.1:9/?v=10&encoding=json",
      reconnect_delay_ms: 10,
      on_status: fn(status) { process.send(statuses, status) },
    )
  let assert Ok(gw) = gateway.start(config)
  let assert Ok(Nil) = gateway.connect(gw)
  wait_status(statuses, gateway.Disconnected)
  wait_status(statuses, gateway.Connecting)
  gateway.stop(gw)
}

pub fn backoff_doubles_up_to_a_minute_test() {
  gateway.backoff_ms(1000, 0) |> should.equal(1000)
  gateway.backoff_ms(1000, 1) |> should.equal(2000)
  gateway.backoff_ms(1000, 5) |> should.equal(32_000)
  gateway.backoff_ms(1000, 6) |> should.equal(60_000)
  gateway.backoff_ms(1000, 500) |> should.equal(60_000)
}

pub fn fatal_close_codes_test() {
  gateway.fatal_close_reason(4004) |> option.is_some |> should.be_true
  gateway.fatal_close_reason(4014) |> option.is_some |> should.be_true
  gateway.fatal_close_reason(4000) |> should.equal(option.None)
  gateway.fatal_close_reason(4009) |> should.equal(option.None)
}
