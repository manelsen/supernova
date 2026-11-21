import e2e/e2e_support as support
import envoy
import exception
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/adapters/sim_router
import supernova/agenda/runtime as agenda_runtime
import supernova/channel/port
import supernova/config
import supernova/core/closed_group/global as closed_group_global
import supernova/llm/provider
import supernova/self/incidents

// 2026-11-21 12:00 in São Paulo (a Saturday).
const now = 1_795_273_200_000

fn mock_provider() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

fn cfg() -> config.Config {
  config.Config(
    ..support.channel_config(),
    // The sim channel has no private chats: allow each person's own chat,
    // which is where the agenda answers.
    access: config.AccessConfig(
      ..support.access_config([], ["sim:alice", "sim:bob"]),
      allowed_chats: ["sim:alice", "sim:bob"],
    ),
  )
}

fn private(user_id: String, content: String) -> port.ChannelMessage {
  port.ChannelMessage(
    id: "a-" <> content,
    channel: "sim",
    channel_id: user_id,
    user_id: user_id,
    username: user_id,
    content: content,
    is_bot: False,
    reply_to_id: None,
  )
}

fn reply_to(
  router: sim_router.SimRouter,
  message: port.ChannelMessage,
) -> String {
  let events = process.new_subject()
  case
    sim_router.route_inbound_for_handler(
      router,
      port.InboundMessage(message),
      events,
    )
  {
    Ok(port.ImmediateReply(reply)) -> reply.content
    Ok(port.StreamReply(_)) -> await_stream(events)
    other -> "UNEXPECTED " <> string.inspect(other)
  }
}

fn await_stream(events: process.Subject(port.ChannelStreamEvent)) -> String {
  case process.receive(events, 5000) {
    Ok(port.StreamComplete(reply)) -> reply.content
    Ok(port.StreamUpdate(_)) -> await_stream(events)
    Ok(port.StreamFailure(_)) | Error(_) -> ""
  }
}

fn say(
  router: sim_router.SimRouter,
  user_id: String,
  content: String,
) -> String {
  reply_to(router, private(user_id, content))
}

fn with_agenda(body: fn(sim_router.SimRouter, String) -> a) -> a {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  let assert Ok(router) = sim_router.start(mock_provider())
  support.with_runtime_root(cfg(), fn(root) {
    agenda_runtime.configure(
      agenda_runtime.Context(data_dir: root, offset_minutes: -180, clock: fn() {
        now
      }),
    )
    body(router, root)
  })
}

// A failed turn leaves an exact incident, and the next turn's prompt shows
// it under "O que aconteceu por aqui" for the agent to explain.
pub fn failed_turn_reaches_the_next_prompt_test() {
  use router, root <- with_agenda
  let _ = say(router, "alice", "oi")
  let _ = say(router, "alice", "Lua")
  let _ = say(router, "alice", "sim")
  let _ = say(router, "alice", "isso vai falhar [mock-400]")
  let assert [incident] =
    incidents.recent(root, "sim:alice", closed_group_global.now(), 5)
  string.contains(incident.text, "400") |> should.be_true
  clear_prompts()
  let _ = say(router, "alice", "o que houve?")
  prompt_texts()
  |> list.any(fn(prompt) {
    string.contains(prompt, "O que aconteceu por aqui:")
    && string.contains(prompt, "status 400")
  })
  |> should.be_true
}

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompt_texts() -> List(String)
