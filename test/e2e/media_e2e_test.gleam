//// PRD-A, A-04 end to end: a voice note sent by a person with access is
//// read by the Gemini reader (a fake serving the real API's recorded
//// answers) before the turn; the agent's model receives the transcription,
//// the history keeps it, and the reading is charged to the person.

import e2e/e2e_support as support
import envoy
import exception
import gemini_fake
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/sim_router
import supernova/channel/inbound_media.{Audio}
import supernova/channel/media_boot
import supernova/channel/media_reading
import supernova/channel/port
import supernova/config
import supernova/core/closed_group/global as closed_group_global
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/resource_ledger/types.{LLMUsage}
import supernova/llm/provider

const ogg = <<"OggS":utf8, 0, 2, 0, 0, 0, 0, 0, 0>>

fn cfg() -> config.Config {
  config.Config(
    ..support.channel_config(),
    access: config.AccessConfig(
      ..support.access_config([], ["sim:dora"]),
      allowed_chats: ["sim:dora"],
    ),
    media: config.MediaConfig(
      ..config.default_media_config(),
      api_key: Some("chave"),
    ),
  )
}

fn message(content: String, user: String) -> port.ChannelMessage {
  port.ChannelMessage(
    id: "m-" <> string.inspect(string.length(content)),
    channel: "sim",
    channel_id: user,
    user_id: user,
    username: user,
    content: content,
    is_bot: False,
    reply_to_id: None,
  )
}

fn say(router, msg) -> String {
  let events = process.new_subject()
  case
    sim_router.route_inbound_for_handler(
      router,
      port.InboundMessage(msg),
      events,
    )
  {
    Ok(port.ImmediateReply(reply)) -> reply.content
    Ok(port.StreamReply(_)) -> await_stream(events)
    other -> "UNEXPECTED " <> string.inspect(other)
  }
}

fn await_stream(events) -> String {
  case process.receive(events, 5000) {
    Ok(port.StreamComplete(reply)) -> reply.content
    Ok(port.StreamUpdate(_)) -> await_stream(events)
    _ -> ""
  }
}

pub fn a_voice_note_is_read_before_the_turn_and_charged_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() {
    envoy.unset("SUPERNOVA_CONSTELLATION_PATH")
    media_reading.clear()
  })
  let gemini = gemini_fake.start(process.new_subject())
  support.with_runtime_root(cfg(), fn(root) {
    let cfg = config.Config(..cfg(), data_dir: root)
    let assert Some(settings) = media_boot.settings(cfg, gemini)
    media_reading.configure(settings)
    let assert Ok(router) =
      sim_router.start(provider.ProviderConfig(
        name: "mock",
        api_key: None,
        base_url: None,
        default_model: "mock-model",
      ))
    // Born and named first.
    let _ = say(router, message("oi", "dora"))
    let _ = say(router, message("Lua", "dora"))
    let _ = say(router, message("sim", "dora"))

    let assert Ok(voice) =
      inbound_media.keep(
        root,
        ogg,
        inbound_media.Declared(
          kind: Audio,
          mime: Some("audio/ogg; codecs=opus"),
          seconds: Some(9),
          file_name: None,
          voice_note: True,
          forwarded: False,
        ),
      )
    let assert port.InboundMessage(read) =
      media_reading.prepare_inbound(
        port.InboundMessage(message(inbound_media.tag_for(voice), "dora")),
      )
    string.starts_with(
      read.content,
      "\n[mensagem de voz de 0:09, transcrita]\nOlá",
    )
    |> should.be_true()
    string.contains(read.content, "Fim da transcrição") |> should.be_false()

    clear_prompts()
    let _ = say(router, read)
    prompt_texts()
    |> list.any(fn(p) {
      string.contains(p, "Este é um áudio de teste da Supernova")
      || string.contains(p, "este é um áudio de teste da Supernova")
    })
    |> should.be_true()

    // Charged to Dora, as Gemini usage, with the tokens the API reported.
    let assert Some(ledger) = closed_group_global.get_ledger()
    ledger_actor.get_all_usage(ledger)
    |> list.any(fn(event) {
      case event {
        LLMUsage(
          principal_id: "sim:dora",
          provider: "gemini",
          prompt_tokens: 513,
          completion_tokens: 73,
          ..,
        ) -> True
        _ -> False
      }
    })
    |> should.be_true()
  })
}

pub fn a_stranger_s_media_costs_nothing_test() {
  use <- exception.defer(fn() { media_reading.clear() })
  let requests = process.new_subject()
  let gemini = gemini_fake.start(requests)
  support.with_runtime_root(cfg(), fn(root) {
    let cfg = config.Config(..cfg(), data_dir: root)
    let assert Some(settings) = media_boot.settings(cfg, gemini)
    media_reading.configure(settings)
    let assert Ok(voice) =
      inbound_media.keep(
        root,
        ogg,
        inbound_media.Declared(
          kind: Audio,
          mime: None,
          seconds: Some(9),
          file_name: None,
          voice_note: True,
          forwarded: False,
        ),
      )
    let assert port.InboundMessage(read) =
      media_reading.prepare_inbound(
        port.InboundMessage(message(inbound_media.tag_for(voice), "estranho")),
      )
    read.content
    |> should.equal(
      "\n[uma mensagem de voz de 0:09, que ainda não consigo ouvir]",
    )
    process.receive(requests, 100) |> should.equal(Error(Nil))
  })
}

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompt_texts() -> List(String)
