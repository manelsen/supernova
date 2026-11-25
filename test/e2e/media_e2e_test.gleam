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
import supernova/core/preferences
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/resource_ledger/types.{LLMUsage}
import supernova/core/session/history_store
import supernova/core/session/supervisor as session_supervisor
import supernova/llm/provider
import supernova/self/forget

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

fn keep_voice(root: String, forwarded: Bool) {
  let assert Ok(voice) =
    inbound_media.keep(
      root,
      ogg,
      inbound_media.Declared(
        kind: Audio,
        mime: Some("audio/ogg"),
        seconds: Some(9),
        file_name: None,
        voice_note: True,
        forwarded: forwarded,
      ),
    )
  voice
}

fn born(router) {
  let _ = say(router, message("oi", "dora"))
  let _ = say(router, message("Lua", "dora"))
  let _ = say(router, message("sim", "dora"))
  Nil
}

/// PRD-A, A-05 (D6): a forwarded audio comes back as its transcription,
/// without the model; the exchange stays in the history.
pub fn a_forwarded_audio_comes_back_transcribed_test() {
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
    born(router)

    let sent = process.new_subject()
    let send = fn(reply: port.ChannelReply) {
      process.send(sent, reply.content)
      Ok(Nil)
    }
    let voice = keep_voice(root, True)
    let assert port.InboundMessage(turn) =
      media_reading.prepare_turn(
        port.InboundMessage(message(inbound_media.tag_for(voice), "dora")),
        send,
      )
    clear_prompts()
    let answer = say(router, turn)
    string.starts_with(answer, "Transcrição do áudio\nOlá") |> should.be_true()
    string.ends_with(answer, "Fim da transcrição") |> should.be_true()
    // No model call for it, and nothing sent ahead.
    prompt_texts() |> should.equal([])
    process.receive(sent, 50) |> should.equal(Error(Nil))
    let said =
      history_store.load(store, "sim:dora:dora")
      |> list.map(fn(m) { m.content })
    list.any(said, fn(text) { string.starts_with(text, "[áudio encaminhado]") })
    |> should.be_true()
    session_supervisor.stop(sessions)
  })
}

/// With /transcricao, the person's own audio comes back transcribed before
/// the agent answers it; /esquecer forgets the preference.
pub fn transcription_of_own_audio_is_a_preference_test() {
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
    born(router)
    let sent = process.new_subject()
    let send = fn(reply: port.ChannelReply) {
      process.send(sent, reply.content)
      Ok(Nil)
    }

    // Off: the own audio is read for the agent, nothing sent ahead.
    let assert port.InboundMessage(_) =
      media_reading.prepare_turn(
        port.InboundMessage(message(
          inbound_media.tag_for(keep_voice(root, False)),
          "dora",
        )),
        send,
      )
    process.receive(sent, 50) |> should.equal(Error(Nil))

    say(router, message("/transcricao", "dora"))
    |> should.equal(
      "Pronto: quando você me mandar áudio, eu te devolvo a transcrição antes de responder.",
    )
    let assert port.InboundMessage(read) =
      media_reading.prepare_turn(
        port.InboundMessage(message(
          inbound_media.tag_for(keep_voice(root, False)),
          "dora",
        )),
        send,
      )
    let assert Ok(ahead) = process.receive(sent, 100)
    string.starts_with(ahead, "Transcrição do áudio\nOlá") |> should.be_true()
    // The agent still gets the audio's text to answer.
    string.starts_with(read.content, "\n[mensagem de voz de 0:09, transcrita]")
    |> should.be_true()

    say(router, message("/transcricao", "dora"))
    |> should.equal("Pronto: não devolvo mais a transcrição dos seus áudios.")
    preferences.load(root, "sim:dora").transcription |> should.be_false()

    let assert Ok(_) =
      preferences.save(root, "sim:dora", preferences.Preferences(True, True))
    let assert Ok(_) = forget.forget(root, "sim:dora", None)
    preferences.load(root, "sim:dora") |> should.equal(preferences.none)
  })
}

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompt_texts() -> List(String)
