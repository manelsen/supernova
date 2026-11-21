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
import supernova/agenda/store
import supernova/agenda/sweeper
import supernova/channel/port
import supernova/config
import supernova/llm/provider

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

pub fn agenda_command_lists_and_removes_test() {
  use router, root <- with_agenda
  say(router, "alice", "/agenda") |> should.equal("Sua agenda está vazia.")

  let assert Ok(_) =
    store.add(root, "sim:alice", "0 5 * * *", "Radar de IA", now, -180)
  let listing = say(router, "alice", "/agenda")
  string.contains(listing, "Radar de IA") |> should.be_true
  string.contains(listing, "22/11/2026 05:00") |> should.be_true
  string.contains(listing, "/agenda remover") |> should.be_true

  // Bob sees his own, empty agenda and cannot remove Alice's entry.
  say(router, "bob", "/agenda") |> should.equal("Sua agenda está vazia.")
  say(router, "bob", "/agenda remover 1")
  |> should.equal("Não há tarefa 1 na agenda.")

  say(router, "alice", "/agenda remover 1")
  |> should.equal("Tirei a tarefa 1 da agenda.")
  store.list(root, "sim:alice") |> should.equal([])
  string.contains(
    say(router, "alice", "/agenda remover x"),
    "/agenda remover N",
  )
  |> should.be_true
}

pub fn due_entry_reaches_the_agent_test() {
  use router, root <- with_agenda
  // Born and named first, as any agent with an agenda would be.
  let _ = say(router, "alice", "oi")
  let _ = say(router, "alice", "Lua")
  let _ = say(router, "alice", "sim")
  let assert Ok(entry) =
    store.add(root, "sim:alice", "0 5 * * *", "RADAR-AGENDADO", now, -180)
  clear_prompts()
  let replies = process.new_subject()
  let ran =
    sweeper.sweep(root, -180, entry.next_run_at, fn(message) {
      process.send(replies, reply_to(router, message))
    })
  ran |> should.equal(1)
  let assert Ok(reply) = process.receive(replies, 5000)
  reply |> should.not_equal("")
  prompt_texts()
  |> list.any(fn(prompt) {
    string.contains(prompt, "RADAR-AGENDADO")
    && string.contains(prompt, "[Agenda]")
  })
  |> should.be_true
}

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompt_texts() -> List(String)
