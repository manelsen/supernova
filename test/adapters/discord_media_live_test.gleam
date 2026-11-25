//// Attachments and stickers against the local fakes (PRD-D, D-05): fetched
//// from the CDN, checked by their bytes and tagged in the text, as in
//// Telegram; never for someone without access, never from another origin.

import discord_fake
import e2e/e2e_support as support
import exception
import gleam/erlang/process
import gleam/int
import gleam/string
import gleeunit/should
import supernova/channel/channel_kit
import supernova/channel/port
import supernova/channel/registry
import supernova/config

const png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13>>

const ogg = <<"OggS":utf8, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0>>

fn cfg() -> config.Config {
  config.Config(
    ..support.channel_config(),
    access: support.access_config([], ["discord:456"]),
  )
}

/// Starts the channel on both fakes; every message's text goes to `seen`.
fn start(
  seen: process.Subject(String),
) -> #(registry.ChannelRegistry, discord_fake.Api, process.Pid) {
  let fake = discord_fake.start()
  let api = discord_fake.start_api()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      cfg(),
      fn(inbound, _events) {
        case inbound {
          port.InboundMessage(message) -> process.send(seen, message.content)
          _ -> Nil
        }
        Error(port.Ignored("test"))
      },
      channel_kit.StartHooks(
        ..channel_kit.no_start_hooks(),
        discord_gateway: channel_kit.DiscordGatewayAt(
          gateway_url: fake.url,
          api_url: api.base_url,
        ),
        disable_telegram_polling: True,
      ),
    )
  let conn = discord_fake.expect_connection(fake, 3000)
  discord_fake.send_text(conn, discord_fake.hello(60_000))
  let _ = discord_fake.expect_op(fake, 2, 3000)
  discord_fake.send_text(
    conn,
    discord_fake.ready("sess-1", discord_fake.resume_url(fake), 1),
  )
  #(channel_registry, api, conn)
}

fn message(
  user_id: String,
  content: String,
  flags: Int,
  attachments: String,
  stickers: String,
) -> String {
  "{\"id\":\"m1\",\"channel_id\":\"dm1\",\"content\":\""
  <> content
  <> "\",\"timestamp\":\"2026-11-25T00:00:00Z\",\"flags\":"
  <> int.to_string(flags)
  <> ",\"author\":{\"id\":\""
  <> user_id
  <> "\",\"username\":\"u\"},\"attachments\":["
  <> attachments
  <> "],\"sticker_items\":["
  <> stickers
  <> "]}"
}

fn attachment(url: String, content_type: String, size: Int) -> String {
  "{\"id\":\"a1\",\"filename\":\"arquivo\",\"content_type\":\""
  <> content_type
  <> "\",\"size\":"
  <> int.to_string(size)
  <> ",\"url\":\""
  <> url
  <> "\",\"proxy_url\":\""
  <> url
  <> "\"}"
}

fn send(conn: process.Pid, data: String) -> Nil {
  discord_fake.send_text(conn, discord_fake.dispatch("MESSAGE_CREATE", data, 2))
}

pub fn image_is_fetched_and_tagged_test() {
  support.with_runtime(cfg(), fn() {
    let seen = process.new_subject()
    let #(channel_registry, api, conn) = start(seen)
    use <- exception.defer(fn() { registry.stop_channels(channel_registry) })
    discord_fake.script_bytes(api, "/attachments/foto.png", 200, png)
    send(
      conn,
      message(
        "456",
        "olha isso",
        0,
        attachment(api.base_url <> "/attachments/foto.png", "image/png", 12),
        "",
      ),
    )
    let assert Ok(content) = process.receive(seen, 5000)
    string.starts_with(content, "olha isso\n[imagem:") |> should.be_true
  })
}

pub fn voice_message_is_audio_test() {
  support.with_runtime(cfg(), fn() {
    let seen = process.new_subject()
    let #(channel_registry, api, conn) = start(seen)
    use <- exception.defer(fn() { registry.stop_channels(channel_registry) })
    discord_fake.script_bytes(api, "/attachments/voz.ogg", 200, ogg)
    send(
      conn,
      message(
        "456",
        "",
        8192,
        attachment(api.base_url <> "/attachments/voz.ogg", "audio/ogg", 14),
        "",
      ),
    )
    let assert Ok(content) = process.receive(seen, 5000)
    // The tag became the reader's note: no reader is configured in tests,
    // and the note says it was a voice message.
    string.contains(content, "uma mensagem de voz") |> should.be_true
  })
}

pub fn other_origins_are_refused_test() {
  support.with_runtime(cfg(), fn() {
    let seen = process.new_subject()
    let #(channel_registry, api, conn) = start(seen)
    use <- exception.defer(fn() { registry.stop_channels(channel_registry) })
    send(
      conn,
      message(
        "456",
        "",
        0,
        attachment("http://169.254.169.254/latest/x.png", "image/png", 12),
        "",
      ),
    )
    let assert Ok(content) = process.receive(seen, 5000)
    string.contains(content, "origem desconhecida") |> should.be_true
    let _ = api
  })
}

pub fn too_large_is_not_downloaded_test() {
  support.with_runtime(cfg(), fn() {
    let seen = process.new_subject()
    let #(channel_registry, api, conn) = start(seen)
    use <- exception.defer(fn() { registry.stop_channels(channel_registry) })
    send(
      conn,
      message(
        "456",
        "",
        0,
        attachment(
          api.base_url <> "/attachments/big.png",
          "image/png",
          30_000_000,
        ),
        "",
      ),
    )
    let assert Ok(content) = process.receive(seen, 5000)
    string.contains(content, "grande demais") |> should.be_true
    discord_fake.expect_no_request_to(api, "/attachments/", 300)
  })
}

pub fn nothing_is_downloaded_for_someone_without_access_test() {
  support.with_runtime(cfg(), fn() {
    let seen = process.new_subject()
    let #(channel_registry, api, conn) = start(seen)
    use <- exception.defer(fn() { registry.stop_channels(channel_registry) })
    send(
      conn,
      message(
        "999",
        "oi",
        0,
        attachment(api.base_url <> "/attachments/foto.png", "image/png", 12),
        "",
      ),
    )
    let assert Ok(content) = process.receive(seen, 5000)
    content |> should.equal("oi")
    discord_fake.expect_no_request_to(api, "/attachments/", 300)
  })
}

pub fn stickers_test() {
  support.with_runtime(cfg(), fn() {
    let seen = process.new_subject()
    let #(channel_registry, api, conn) = start(seen)
    use <- exception.defer(fn() { registry.stop_channels(channel_registry) })
    discord_fake.script_bytes(api, "/stickers/st1.png", 200, png)
    send(
      conn,
      message(
        "456",
        "",
        0,
        "",
        "{\"id\":\"st1\",\"name\":\"gato\",\"format_type\":1},{\"id\":\"st2\",\"name\":\"dança\",\"format_type\":3}",
      ),
    )
    let assert Ok(content) = process.receive(seen, 5000)
    string.contains(content, "[imagem:") |> should.be_true
    string.contains(content, "[uma figurinha animada]") |> should.be_true
  })
}

pub fn document_and_animated_sticker_test() {
  support.with_runtime(cfg(), fn() {
    let seen = process.new_subject()
    let #(channel_registry, api, conn) = start(seen)
    use <- exception.defer(fn() { registry.stop_channels(channel_registry) })
    discord_fake.script_bytes(api, "/attachments/doc.pdf", 200, <<
      "%PDF-1.4 teste":utf8,
    >>)
    discord_fake.script_bytes(api, "/stickers/st3.gif", 200, <<
      "GIF89a":utf8, 1, 0, 1, 0,
    >>)
    send(
      conn,
      message(
        "456",
        "",
        0,
        attachment(
          api.base_url <> "/attachments/doc.pdf",
          "application/pdf",
          14,
        ),
        "{\"id\":\"st3\",\"name\":\"pulo\",\"format_type\":4}",
      ),
    )
    let assert Ok(content) = process.receive(seen, 5000)
    string.contains(content, "documento") |> should.be_true
    string.contains(content, "figurinha") |> should.be_true
  })
}

pub fn failed_download_becomes_a_note_test() {
  support.with_runtime(cfg(), fn() {
    let seen = process.new_subject()
    let #(channel_registry, api, conn) = start(seen)
    use <- exception.defer(fn() { registry.stop_channels(channel_registry) })
    discord_fake.script(api, "/attachments/sumiu.mp4", 404, "{}")
    send(
      conn,
      message(
        "456",
        "",
        0,
        attachment(api.base_url <> "/attachments/sumiu.mp4", "video/mp4", 100),
        "",
      ),
    )
    let assert Ok(content) = process.receive(seen, 5000)
    string.contains(content, "um vídeo que não consegui ver") |> should.be_true
  })
}
