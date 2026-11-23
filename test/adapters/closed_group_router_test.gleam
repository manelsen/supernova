//// Router behaviour under the closed-group runtime: gated turns run
//// asynchronously, policy refusals reach the user, and interactive
//// callbacks pass through the same access gate as messages.

import e2e/e2e_support as support
import envoy
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/adapters/channel_common_router as router
import supernova/adapters/telegram_router
import supernova/channel/port
import supernova/config
import supernova/core/session/history_store
import supernova/core/session/server as session_server
import supernova/core/session/supervisor

fn cfg(members: List(String), member_tokens: Int) -> config.Config {
  let base = support.channel_config()
  config.Config(
    ..base,
    access: support.access_config([], members),
    role_budgets: config.RoleBudgetsConfig(
      member: config.RoleBudgetConfig(
        tokens_per_hour: member_tokens,
        tool_calls_per_hour: 60,
      ),
      admin: config.RoleBudgetConfig(
        tokens_per_hour: -1,
        tool_calls_per_hour: -1,
      ),
    ),
  )
}

fn telegram_message(user_id: String, content: String) -> port.ChannelInbound {
  port.InboundMessage(port.ChannelMessage(
    id: "1",
    channel: "telegram",
    channel_id: user_id,
    user_id: user_id,
    username: "tester",
    content: content,
    is_bot: False,
    reply_to_id: None,
  ))
}

fn telegram_click(user_id: String, action_id: String) -> port.ChannelInbound {
  port.InboundInteraction(port.ChannelInteractionMessage(
    channel: "telegram",
    channel_id: user_id,
    user_id: user_id,
    username: "tester",
    is_bot: False,
    event: port.ChannelInteractionEvent(
      id: "cb-1",
      action_id: action_id,
      values: [],
      source_message_id: None,
    ),
  ))
}

fn ensure_born(
  handler: fn(port.ChannelInbound, process.Subject(port.ChannelStreamEvent)) ->
    Result(port.ChannelHandlerResult, port.ChannelError),
  user_id: String,
) -> Nil {
  let events = process.new_subject()
  let _ = handler(telegram_message(user_id, "oi"), events)
  let _ = handler(telegram_message(user_id, "Lua"), events)
  let _ = handler(telegram_message(user_id, "sim"), events)
  Nil
}

fn await_final_content(
  events: process.Subject(port.ChannelStreamEvent),
) -> String {
  case process.receive(events, within: 5000) {
    Ok(port.StreamComplete(reply)) -> reply.content
    Ok(port.StreamUpdate(_)) -> await_final_content(events)
    Ok(port.StreamFailure(_)) -> "<stream failure>"
    Error(_) -> "<timeout>"
  }
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_native() -> Int

@external(erlang, "erlang", "convert_time_unit")
fn convert_time_unit(value: Int, from: Atom, to: Atom) -> Int

type Atom

@external(erlang, "erlang", "binary_to_atom")
fn atom(name: String) -> Atom

fn monotonic_ms() -> Int {
  convert_time_unit(monotonic_native(), atom("native"), atom("millisecond"))
}

// A gated turn must not run inside the router actor: the handler answers
// immediately with a stream placeholder and the LLM turn runs elsewhere.
// With the default member capabilities the mock LLM calls an allowed tool,
// so this also covers the gateway accepting the member's role key.
pub fn gated_turn_is_asynchronous_test() {
  support.with_runtime(cfg(["telegram:123"], 50_000), fn() {
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
    let handler = support.telegram_handler(support.mock_config())
    ensure_born(handler, "123")
    let events = process.new_subject()
    let started = monotonic_ms()

    let assert Ok(port.StreamReply(_)) =
      handler(telegram_message("123", "[mock-delay-ms=1500]"), events)
    { monotonic_ms() - started < 300 } |> should.equal(True)

    await_final_content(events)
    |> string.contains("Mock response")
    |> should.equal(True)
  })
}

pub fn executor_crash_emits_stream_failure_test() {
  support.with_runtime(cfg(["telegram:123"], 50_000), fn() {
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
    let handler = support.telegram_handler(support.mock_config())
    ensure_born(handler, "123")
    let events = process.new_subject()

    let assert Ok(port.StreamReply(_)) =
      handler(telegram_message("123", "[mock-crash]"), events)

    case process.receive(events, within: 5000) {
      Ok(port.StreamFailure(_)) -> Nil
      Ok(port.StreamUpdate(_)) -> should.fail()
      Ok(port.StreamComplete(_)) -> should.fail()
      Error(_) -> should.fail()
    }
  })
}

// A policy refusal reaches the user as a message. Budget exhaustion is
// detected at the gate, before any LLM call, so it is answered immediately.
pub fn policy_refusal_reaches_the_user_test() {
  support.with_runtime(cfg(["telegram:123"], 0), fn() {
    let handler = support.telegram_handler(support.mock_config())
    let events = process.new_subject()

    let assert Ok(port.ImmediateReply(reply)) =
      handler(telegram_message("123", "oi"), events)
    reply.content
    |> string.starts_with("Seu limite de uso desta hora acabou.")
    |> should.equal(True)
  })
}

// A non-member clicking a picker button must be stopped by the access gate
// before any provider or model preference changes.
pub fn interaction_from_non_member_is_gated_test() {
  support.with_runtime(cfg(["telegram:123"], 50_000), fn() {
    let handler = support.telegram_handler(support.mock_config())
    let events = process.new_subject()

    let assert Ok(port.ImmediateReply(reply)) =
      handler(telegram_click("999", "picker_provider:mock"), events)
    reply.content |> should.equal("Esta instância é privada.")
    reply.edit_message_id |> should.equal(None)
  })
}

pub fn interaction_from_member_still_works_test() {
  support.with_runtime(cfg(["telegram:123"], 0), fn() {
    let handler = support.telegram_handler(support.mock_config())
    let events = process.new_subject()

    let assert Ok(port.ImmediateReply(reply)) =
      handler(telegram_click("123", "picker_provider:mock"), events)
    string.contains(reply.content, "Já está em uso: Mock / mock-model")
    |> should.equal(True)
  })
}

/// The tool calls of a turn stay in the conversation, between the person's
/// message and the reply, so the next turns see what the reply was built on.
/// (With the default member capabilities the mock calls an allowed tool.)
pub fn tool_calls_stay_in_the_conversation_test() {
  support.with_runtime_root(cfg(["telegram:123"], 50_000), fn(root) {
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
    let store = history_store.HistoryStore(data_dir: root, limit: 100)
    let assert Ok(sup) = supervisor.start_with_history(store)
    let assert Ok(router) =
      telegram_router.start_with_session_supervisor(sup, support.mock_config())
    let handler = fn(inbound, events) {
      telegram_router.route_inbound_for_handler(router, inbound, events)
    }
    ensure_born(handler, "123")
    let events = process.new_subject()
    let assert Ok(_) = handler(telegram_message("123", "faz algo"), events)
    await_final_content(events)
    |> string.contains("Mock")
    |> should.be_true()

    let history = history_store.load(store, "telegram:123:123")
    let assert [call, result, reply] =
      history
      |> list.drop_while(fn(m) { m.content != "faz algo" })
      |> list.drop(1)
    call.role |> should.equal("tool_call")
    call.content |> string.contains("\"name\":\"canvas\"") |> should.be_true()
    result.role |> should.equal("tool")
    result.content |> should.equal("tool-ok")
    reply.role |> should.equal("assistant")
    supervisor.stop(sup)
  })
}

/// Kept tool calls go back to the model as a call and its answer sharing a
/// nine-character id (Mistral's rule); a call without its result, or a
/// result without its call, is left out, as the APIs refuse them.
pub fn kept_tool_calls_become_calls_and_answers_test() {
  let m = fn(role, content) {
    session_server.ChatMessage(role: role, content: content)
  }
  let messages =
    router.provider_messages_from_session_history([
      m("tool", "órfão"),
      m("user", "procura"),
      m("tool_call", "{\"name\":\"buscar_conversa\",\"arguments\":\"{}\"}"),
      m("tool", "achei"),
      m("assistant", "aqui está"),
      m("user", "de novo"),
      m("tool_call", "{\"name\":\"buscar_conversa\",\"arguments\":\"{}\"}"),
      m("assistant", "sem resultado"),
    ])
  let assert [user1, call, answer, reply1, user2, reply2] = messages
  user1.content |> should.equal("procura")
  let assert option.Some([tool_call]) = call.tool_calls
  tool_call.name |> should.equal("buscar_conversa")
  string.length(tool_call.id) |> should.equal(9)
  answer.role |> should.equal("tool")
  answer.tool_call_id |> should.equal(option.Some(tool_call.id))
  answer.content |> should.equal("achei")
  reply1.content |> should.equal("aqui está")
  user2.content |> should.equal("de novo")
  reply2.content |> should.equal("sem resultado")
}
