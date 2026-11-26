//// The whole turn with the memory on: an inbound message goes through the
//// router, the gate reads it, the pre-search runs, and what `lembrar` found
//// reaches the model in the same turn (docs/prd/PRD-M-memoria.md, 6.3, 6.5
//// and I2). The gate and `prepare_with` have their own tests; this one covers
//// the glue in `executor_messages_for_turn`, where a turn could lose the
//// pre-search without anybody noticing.
////
//// The LLM is the mock provider, which records the prompts it was given. Only
//// the Decision and the embeddings are stubbed, through the runtime settings,
//// as the bench does.

import e2e/e2e_support as support
import envoy
import exception
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/adapters/sim_router
import supernova/agenda/runtime as agenda_runtime
import supernova/channel/port
import supernova/config
import supernova/core/session/history_store.{HistoryStore, StoredMessage}
import supernova/llm/provider
import supernova/memory/decision
import supernova/memory/runtime

// 2026-11-21 12:00 in São Paulo (a Saturday).
const now = 1_795_273_200_000

const phone = "3222-1010"

pub fn main() -> Nil {
  gleeunit.main()
}

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
    // The sim channel has no private chats: allow each person's own chat.
    access: config.AccessConfig(
      ..support.access_config([], ["sim:alice"]),
      allowed_chats: ["sim:alice"],
    ),
  )
}

fn private(user_id: String, content: String) -> port.ChannelMessage {
  port.ChannelMessage(
    id: "r-" <> content,
    channel: "sim",
    channel_id: user_id,
    user_id: user_id,
    username: user_id,
    content: content,
    is_bot: False,
    reply_to_id: None,
  )
}

fn say(
  router: sim_router.SimRouter,
  user_id: String,
  content: String,
) -> String {
  let events = process.new_subject()
  case
    sim_router.route_inbound_for_handler(
      router,
      port.InboundMessage(private(user_id, content)),
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

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompt_texts() -> List(String)

/// What the person told days ago, on disk: the live session of the test has no
/// store, so this is the only conversation `lembrar` can find.
fn seed_history(root: String) -> Nil {
  let store = HistoryStore(data_dir: root, limit: 100)
  let messages = [
    StoredMessage(
      role: "user",
      content: "o telefone da clínica é " <> phone,
      at: now - 60_000,
    ),
    StoredMessage(role: "assistant", content: "anotei.", at: now - 59_000),
  ]
  case history_store.append(store, "sim:alice", messages) {
    Ok(_) -> Nil
    Error(_) -> should.fail()
  }
}

/// Gemini's settings with a stubbed Decision and embeddings: the gate always
/// says the message is about the past, every vector is [1, 0], and every
/// excerpt of `lembrar` looks right for the subject.
fn settings() -> runtime.Settings {
  let transport = fn(
    url: String,
    _headers: List(#(String, String)),
    body: String,
  ) {
    case
      url == decision.embed_url(decision.Gemini),
      string.contains(body, "\"passado\"")
    {
      True, _ -> Ok(#(200, "{\"embedding\":{\"values\":[1,0]}}"))
      False, True -> Ok(#(200, "{\"answers\":{\"passado\":{\"noul\":0.93}}}"))
      False, False ->
        Ok(#(
          200,
          "{\"answers\":{\"falado\":{\"noul\":0.9},\"t1\":{\"noul\":0.9},\"t2\":{\"noul\":0.9},\"t3\":{\"noul\":0.9},\"t4\":{\"noul\":0.9},\"t5\":{\"noul\":0.9}}}",
        ))
    }
  }
  runtime.Settings(
    transport: transport,
    endpoint: decision.endpoint(decision.Gemini, "k"),
    thresholds: runtime.default_thresholds(decision.Gemini),
    gate_timeout_ms: 500,
    recall_timeout_ms: 5000,
    admit: runtime.no_ledger,
  )
}

fn with_turn(body: fn(sim_router.SimRouter, String) -> a) -> a {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  use <- exception.defer(runtime.clear)
  let assert Ok(router) = sim_router.start(mock_provider())
  support.with_runtime_root(cfg(), fn(root) {
    agenda_runtime.configure(
      agenda_runtime.Context(data_dir: root, offset_minutes: -180, clock: fn() {
        now
      }),
    )
    support.seed_core(root, "sim:alice", "Núcleo de teste.")
    seed_history(root)
    body(router, root)
  })
}

/// The question reaches the model with what `lembrar` found, in the same turn.
pub fn the_pre_search_reaches_the_model_in_a_turn_test() {
  use router, _root <- with_turn()
  let _ = runtime.configure(settings())
  clear_prompts()
  let reply = say(router, "alice", "qual é o telefone da clínica?")
  reply |> string.contains("UNEXPECTED") |> should.be_false
  reply |> should.not_equal("")
  prompt_texts()
  |> list.any(fn(prompt) {
    string.contains(prompt, "Trechos mais prováveis:")
    && string.contains(prompt, phone)
  })
  |> should.be_true
}

/// The other side of the same coin (I5): with the memory off, no pre-search
/// reaches the model, and the phone does not appear in what it sees.
pub fn without_the_memory_the_turn_is_the_one_from_before_test() {
  use router, _root <- with_turn()
  clear_prompts()
  let reply = say(router, "alice", "qual é o telefone da clínica?")
  reply |> string.contains("UNEXPECTED") |> should.be_false
  reply |> should.not_equal("")
  prompt_texts()
  |> list.any(fn(prompt) {
    string.contains(prompt, "Trechos mais prováveis:")
    || string.contains(prompt, phone)
  })
  |> should.be_false
}
