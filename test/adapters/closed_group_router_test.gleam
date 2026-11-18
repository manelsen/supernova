//// Router behaviour under the closed-group runtime: gated turns run
//// asynchronously, policy refusals reach the user, and interactive
//// callbacks pass through the same access gate as messages.

import e2e/e2e_support as support
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/channel/port
import supernova/config

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

// A gated turn must not run inside the router actor: the handler answers
// immediately with a stream placeholder and the LLM turn runs elsewhere.
// With the default member capabilities the mock LLM calls an allowed tool,
// so this also covers the gateway accepting the member's role key.
pub fn gated_turn_is_asynchronous_test() {
  support.with_runtime(cfg(["telegram:123"], 50_000), fn() {
    let handler = support.telegram_handler(support.mock_config())
    let events = process.new_subject()

    let assert Ok(result) = handler(telegram_message("123", "oi"), events)
    case result {
      port.StreamReply(_) -> Nil
      port.ImmediateReply(_) -> should.fail()
    }

    await_final_content(events)
    |> string.contains("Mock response")
    |> should.equal(True)
  })
}

// A policy refusal reaches the user as a message. Budget exhaustion is
// detected at the gate, before any LLM call, so it is answered immediately.
pub fn policy_refusal_reaches_the_user_test() {
  support.with_runtime(cfg(["telegram:123"], 0), fn() {
    let handler = support.telegram_handler(support.mock_config())
    let events = process.new_subject()

    let content = case handler(telegram_message("123", "oi"), events) {
      Ok(port.ImmediateReply(reply)) -> reply.content
      Ok(port.StreamReply(_)) -> await_final_content(events)
      Error(_) -> "<error>"
    }
    content
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

    case handler(telegram_click("999", "picker_provider:mock"), events) {
      Ok(port.ImmediateReply(reply)) ->
        string.contains(reply.content, "Provider set to")
        |> should.equal(False)
      Ok(port.StreamReply(_)) -> should.fail()
      Error(_) -> Nil
    }
  })
}

pub fn interaction_from_member_still_works_test() {
  support.with_runtime(cfg(["telegram:123"], 50_000), fn() {
    let handler = support.telegram_handler(support.mock_config())
    let events = process.new_subject()

    let assert Ok(port.ImmediateReply(reply)) =
      handler(telegram_click("123", "picker_provider:mock"), events)
    string.contains(reply.content, "Provider set to") |> should.equal(True)
  })
}
