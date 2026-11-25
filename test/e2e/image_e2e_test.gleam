//// PRD-C, C-05b: an image a person sends reaches the model once, through
//// the real pipeline (closed group, router, executor); the history keeps
//// `[imagem]` and the temporary file is gone.

import e2e/e2e_support as support
import envoy
import exception
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/adapters/sim_router
import supernova/channel/inbound_media
import supernova/channel/port
import supernova/config
import supernova/core/session/history_store
import supernova/core/session/supervisor as session_supervisor
import supernova/llm/provider

const png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3>>

fn cfg() -> config.Config {
  config.Config(
    ..support.channel_config(),
    access: config.AccessConfig(
      ..support.access_config([], ["sim:carol"]),
      allowed_chats: ["sim:carol"],
    ),
  )
}

fn say(router: sim_router.SimRouter, content: String) -> String {
  let events = process.new_subject()
  let message =
    port.ChannelMessage(
      id: "img-" <> string.inspect(string.length(content)),
      channel: "sim",
      channel_id: "carol",
      user_id: "carol",
      username: "carol",
      content: content,
      is_bot: False,
      reply_to_id: None,
    )
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

pub fn an_image_reaches_the_model_once_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  support.with_runtime_root(cfg(), fn(root) {
    let store = history_store.HistoryStore(data_dir: root, limit: 40)
    let assert Ok(sessions) = session_supervisor.start_with_history(store)
    let assert Ok(router) =
      sim_router.start_with_session_supervisor(
        sessions,
        provider.ProviderConfig(
          name: "mock",
          api_key: None,
          base_url: None,
          default_model: "mock-model",
        ),
      )
    // Born and named first.
    let _ = say(router, "oi")
    let _ = say(router, "Lua")
    let _ = say(router, "sim")

    let assert Ok(id) = inbound_media.store(root, png)
    clear_prompts()
    say(router, "olha" <> inbound_media.tag(id))
    |> should.equal("vi 1 imagem(ns)")
    // Amélie's audio description rules went with the image (A-08)...
    prompt_texts()
    |> list.any(fn(p) { string.contains(p, "faça a audiodescrição") })
    |> should.be_true()
    // The file was read once and is gone.
    inbound_media.take_data_url(root, id) |> should.be_error

    // The history keeps the placeholder, never the tag.
    let said =
      history_store.load(store, "sim:carol:carol")
      |> list.map(fn(message) { message.content })
    list.contains(said, "olha\n[imagem]") |> should.be_true()
    list.any(said, fn(text) { string.contains(text, "[imagem:") })
    |> should.be_false()
    // ...but only to the model, never into the history.
    list.any(said, fn(text) { string.contains(text, "audiodescrição") })
    |> should.be_false()
    session_supervisor.stop(sessions)
  })
}

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompt_texts() -> List(String)
