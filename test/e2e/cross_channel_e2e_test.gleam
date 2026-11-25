//// PRD-I, I-05: one person, two channels, one agent. What Carol said on one
//// channel, her agent finds when she asks on the other.

import e2e/e2e_support as support
import envoy
import exception
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/adapters/channel_router
import supernova/agenda/runtime as agenda_runtime
import supernova/channel/port
import supernova/config
import supernova/core/identity/aliases
import supernova/core/session/history_store
import supernova/core/session/supervisor as session_supervisor
import supernova/llm/provider

fn cfg() -> config.Config {
  config.Config(
    ..support.channel_config(),
    access: config.AccessConfig(
      ..support.access_config([], ["sim:carol"]),
      allowed_chats: ["sim:carol"],
    ),
  )
}

fn say(
  router: channel_router.ChannelRouter,
  channel: String,
  chat_id: String,
  user_id: String,
  content: String,
) -> String {
  let events = process.new_subject()
  let message =
    port.ChannelMessage(
      id: channel <> "-" <> string.inspect(string.length(content)) <> content,
      channel: channel,
      channel_id: chat_id,
      user_id: user_id,
      username: user_id,
      content: content,
      is_bot: False,
      reply_to_id: None,
    )
  case
    channel_router.route_inbound_for_handler(
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

pub fn what_was_said_on_one_channel_is_found_on_the_other_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  support.with_runtime_root(cfg(), fn(root) {
    let llm =
      provider.ProviderConfig(
        name: "mock",
        api_key: None,
        base_url: None,
        default_model: "mock-model",
      )
    agenda_runtime.configure(
      agenda_runtime.Context(data_dir: root, offset_minutes: -180, clock: fn() {
        1_795_273_200_000
      }),
    )
    let store = history_store.HistoryStore(data_dir: root, limit: 40)
    let assert Ok(sessions) = session_supervisor.start_with_history(store)
    let assert Ok(on_sim) =
      channel_router.start_with_session_supervisor("sim", sessions, llm)
    let assert Ok(on_discord) =
      channel_router.start_with_session_supervisor("discord", sessions, llm)

    // Carol meets her agent on the sim channel.
    let _ = say(on_sim, "sim", "carol", "carol", "oi")
    let _ = say(on_sim, "sim", "carol", "carol", "Lua")
    let _ = say(on_sim, "sim", "carol", "carol", "sim")
    let _ = say(on_sim, "sim", "carol", "carol", "meu gato se chama Biscoito")

    // Before the link, Discord is a stranger.
    say(on_discord, "discord", "dm:carol-d", "carol-d", "oi")
    |> should.not_equal("Mock response")

    // Linked (I-02 covers the commands), Discord is Carol.
    let assert Ok(Nil) =
      aliases.link(root, "discord:carol-d", "sim:carol", "discord", 1)
    clear_prompts()
    let _ =
      say(
        on_discord,
        "discord",
        "dm:carol-d",
        "carol-d",
        "[mock-busca Biscoito]",
      )
    let prompts = prompt_texts()
    prompts
    |> list.any(fn(prompt) { string.contains(prompt, "meu gato se chama") })
    |> should.be_true()

    let assert Ok(Nil) = aliases.unlink(root, "discord:carol-d")
    session_supervisor.stop(sessions)
  })
}

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompt_texts() -> List(String)
