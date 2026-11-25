//// PRD-C, C-04 and PRD-I, I-04: what Supernova makes of each GOWA v9.10
//// webhook. Payloads follow docs/webhook-payload.md of that version.

import gleam/option.{None, Some}
import gleeunit/should
import supernova/adapters/whatsapp_inbound as inbound
import supernova/core/identity/aliases
import test_workspace

const agent = "628987654321@s.whatsapp.net"

fn message(fields: String) -> String {
  "{\"event\":\"message\",\"device_id\":\""
  <> agent
  <> "\",\"payload\":{\"id\":\"3EB0C127D7BACC83D6A1\",\"timestamp\":\"2023-10-15T10:30:00Z\",\"is_from_me\":false,"
  <> fields
  <> "}}"
}

pub fn a_private_text_is_answered_as_the_phone_test() {
  let body =
    message(
      "\"chat_id\":\"628123456789@s.whatsapp.net\",\"from\":\"628123456789@s.whatsapp.net\",\"from_name\":\"John Doe\",\"body\":\"Hello, how are you?\"",
    )
  let assert inbound.Answer(msg, learned: None, ..) = inbound.decide(body)
  msg.channel |> should.equal("whatsapp")
  msg.channel_id |> should.equal("628123456789@s.whatsapp.net")
  msg.user_id |> should.equal("628123456789")
  msg.username |> should.equal("John Doe")
  msg.content |> should.equal("Hello, how are you?")
  msg.id |> should.equal("3EB0C127D7BACC83D6A1")
}

pub fn a_message_with_both_ids_teaches_the_lid_test() {
  let body =
    message(
      "\"chat_id\":\"628123456789@s.whatsapp.net\",\"from\":\"628123456789@s.whatsapp.net\",\"from_lid\":\"251556368777322@lid\",\"body\":\"oi\"",
    )
  let assert inbound.Answer(_, learned: Some(pair), ..) = inbound.decide(body)
  pair
  |> should.equal(#("whatsapp:251556368777322@lid", "whatsapp:628123456789"))
}

pub fn a_reply_keeps_what_it_answers_test() {
  let body =
    message(
      "\"chat_id\":\"628123456789@s.whatsapp.net\",\"from\":\"628123456789@s.whatsapp.net\",\"body\":\"sim\",\"replied_to_id\":\"ABC\",\"quoted_body\":\"posso?\",\"replied_to_sender\":\""
      <> agent
      <> "\"",
    )
  let assert inbound.Answer(msg, ..) = inbound.decide(body)
  msg.reply_to_id |> should.equal(Some("ABC"))
}

pub fn own_messages_and_other_events_are_ignored_test() {
  let own =
    "{\"event\":\"message\",\"device_id\":\""
    <> agent
    <> "\",\"payload\":{\"id\":\"1\",\"chat_id\":\"x@s.whatsapp.net\",\"from\":\""
    <> agent
    <> "\",\"is_from_me\":true,\"body\":\"eco\"}}"
  let assert inbound.Ignore(_) = inbound.decide(own)
  let assert inbound.Ignore(_) =
    inbound.decide(
      "{\"event\":\"message.ack\",\"device_id\":\"d\",\"payload\":{\"ids\":[\"1\"]}}",
    )
  let assert inbound.Ignore(_) =
    inbound.decide(message(
      "\"chat_id\":\"628123456789@s.whatsapp.net\",\"from\":\"628123456789@s.whatsapp.net\"",
    ))
  inbound.decide("não é json") |> should.equal(inbound.Malformed)
}

pub fn in_a_group_only_what_is_addressed_to_the_agent_test() {
  let group =
    "\"chat_id\":\"120363012345678901@g.us\",\"from\":\"628123456789@s.whatsapp.net\","
  // Talk among the others: not for the agent.
  let assert inbound.Ignore(_) =
    inbound.decide_allowing_groups(message(
      group <> "\"body\":\"bom dia, gente\"",
    ))
  // A mention of the agent.
  let assert inbound.Answer(msg, ..) =
    inbound.decide_allowing_groups(message(
      group
      <> "\"body\":\"@628987654321 pode ver isso?\",\"mentions\":[\""
      <> agent
      <> "\",\"628111111111@s.whatsapp.net\"]",
    ))
  msg.channel_id |> should.equal("120363012345678901@g.us")
  // A reply to the agent.
  let assert inbound.Answer(..) =
    inbound.decide_allowing_groups(message(
      group
      <> "\"body\":\"isso\",\"replied_to_id\":\"Z\",\"replied_to_sender\":\""
      <> agent
      <> "\"",
    ))
  // A command.
  let assert inbound.Answer(..) =
    inbound.decide_allowing_groups(message(group <> "\"body\":\"/eu\""))
  // A mention of someone else.
  let assert inbound.Ignore(_) =
    inbound.decide_allowing_groups(message(
      group
      <> "\"body\":\"@628111111111 oi\",\"mentions\":[\"628111111111@s.whatsapp.net\"]",
    ))
}

pub fn a_known_lid_is_its_person_an_unknown_one_is_asked_to_write_privately_test() {
  let dir = test_workspace.create_temp_dir("wa-lid")
  let group =
    "\"chat_id\":\"120363012345678901@g.us\",\"from\":\"999@lid\",\"body\":\"/eu\""
  inbound.decide_allowing_groups(message(group))
  |> should.equal(inbound.AskPrivate(
    chat_id: "120363012345678901@g.us",
    reply_to: "3EB0C127D7BACC83D6A1",
  ))
  // In private an unknown LID is only logged.
  let assert inbound.Ignore(_) =
    inbound.decide_allowing_groups(message(
      "\"chat_id\":\"999@lid\",\"from\":\"999@lid\",\"body\":\"oi\"",
    ))

  let assert Ok(Nil) =
    aliases.link(dir, "whatsapp:999@lid", "whatsapp:62999", "whatsapp", 1)
  let assert inbound.Answer(msg, ..) =
    inbound.decide_allowing_groups(message(group))
  msg.user_id |> should.equal("999@lid")
  let assert Ok(Nil) = aliases.unlink(dir, "whatsapp:999@lid")
  test_workspace.remove_dir_recursive(dir)
}

pub fn account_events_say_why_test() {
  inbound.decide(
    "{\"event\":\"device.logged_out\",\"device_id\":\"628123456789@s.whatsapp.net\",\"session_id\":\"org_2\",\"timestamp\":\"2026-10-28T09:00:00Z\",\"payload\":{\"code\":401,\"reason\":\"logged out from another device\",\"on_connect\":true}}",
  )
  |> should.equal(inbound.AccountDown(
    "a conta foi desconectada (401: logged out from another device)",
  ))
  inbound.decide(
    "{\"event\":\"device.temporary_ban\",\"device_id\":\"628123456789@s.whatsapp.net\",\"session_id\":\"org_2\",\"timestamp\":\"2026-10-28T09:00:00Z\",\"payload\":{\"code\":101,\"reason\":\"you sent too many messages\",\"expires_in_seconds\":86400,\"expires_at\":\"2026-10-29T09:00:00Z\"}}",
  )
  |> should.equal(inbound.AccountDown(
    "suspensão temporária até 2026-10-29T09:00:00Z (101: you sent too many messages)",
  ))
}

/// PRD-C, C-05: an image GOWA downloaded comes with its path, with or
/// without a caption; an image without text is still a message.
pub fn an_image_comes_with_its_path_test() {
  let private =
    "\"chat_id\":\"628123456789@s.whatsapp.net\",\"from\":\"628123456789@s.whatsapp.net\","
  let assert inbound.Answer(
    msg,
    attachments: [inbound.Attachment(kind: inbound.Image, path: Some(path), ..)],
    ..,
  ) =
    inbound.decide(message(
      private <> "\"image\":\"statics/media/1752404751-ad9e.jpeg\"",
    ))
  path |> should.equal("statics/media/1752404751-ad9e.jpeg")
  msg.content |> should.equal("")
  let assert inbound.Answer(
    msg,
    attachments: [inbound.Attachment(kind: inbound.Image, ..)],
    ..,
  ) =
    inbound.decide(message(
      private
      <> "\"body\":\"olha\",\"image\":{\"path\":\"statics/media/x.jpeg\",\"caption\":\"olha\"}",
    ))
  msg.content |> should.equal("olha")
  // Not downloaded: only WhatsApp's encrypted URL. The image is there, with
  // no path to fetch; it becomes a note, not silence.
  let assert inbound.Answer(
    msg,
    attachments: [inbound.Attachment(kind: inbound.Image, path: None, ..)],
    ..,
  ) =
    inbound.decide(message(
      private
      <> "\"image\":{\"url\":\"https://mmg.whatsapp.net/x\",\"caption\":\"veja\"}",
    ))
  msg.content |> should.equal("veja")
}

/// The maintainer's rule for now: every conversation in private. With
/// groups off (the default), a group message is dropped unread, even a
/// mention or a command, and no one is asked anything in the group.
pub fn groups_are_off_by_default_test() {
  let group =
    "\"chat_id\":\"120363012345678901@g.us\",\"from\":\"628123456789@s.whatsapp.net\","
  inbound.decide(message(
    group <> "\"body\":\"@628987654321 oi\",\"mentions\":[\"" <> agent <> "\"]",
  ))
  |> should.equal(inbound.Ignore("groups are off"))
  inbound.decide(message(group <> "\"body\":\"/eu\""))
  |> should.equal(inbound.Ignore("groups are off"))
  inbound.decide(message(
    "\"chat_id\":\"120363012345678901@g.us\",\"from\":\"999@lid\",\"body\":\"/eu\"",
  ))
  |> should.equal(inbound.Ignore("groups are off"))
  // Private chats are as before.
  let assert inbound.Answer(..) =
    inbound.decide(message(
      "\"chat_id\":\"628123456789@s.whatsapp.net\",\"from\":\"628123456789@s.whatsapp.net\",\"body\":\"oi\"",
    ))
}

// PRD-A, A-01: nothing a person sends disappears. Payload shapes follow
// GOWA v9.10's docs/webhook-payload.md.

const private_chat =
  "\"chat_id\":\"628123456789@s.whatsapp.net\",\"from\":\"628123456789@s.whatsapp.net\","

pub fn a_voice_note_is_an_attachment_with_its_length_test() {
  let assert inbound.Answer(msg, attachments: [audio], forwarded: False, ..) =
    inbound.decide(message(
      private_chat
      <> "\"audio\":\"statics/media/1752-voz.ogg\",\"media_info\":{\"mime_type\":\"audio/ogg; codecs=opus\",\"seconds\":42,\"ptt\":true}",
    ))
  msg.content |> should.equal("")
  audio
  |> should.equal(inbound.Attachment(
    kind: inbound.Audio,
    path: Some("statics/media/1752-voz.ogg"),
    seconds: Some(42),
    file_name: None,
    mime: Some("audio/ogg; codecs=opus"),
    voice_note: True,
  ))
}

pub fn a_forwarded_audio_says_so_test() {
  let assert inbound.Answer(forwarded: True, attachments: [_], ..) =
    inbound.decide(message(
      private_chat
      <> "\"forwarded\":true,\"forwarding_score\":1,\"audio\":\"statics/media/a.ogg\"",
    ))
}

pub fn video_document_and_stickers_are_attachments_test() {
  let assert inbound.Answer(msg, attachments: [video], ..) =
    inbound.decide(message(
      private_chat
      <> "\"body\":\"Watch this!\",\"video\":{\"path\":\"statics/media/v.mp4\",\"caption\":\"Watch this!\"},\"media_info\":{\"seconds\":70}",
    ))
  msg.content |> should.equal("Watch this!")
  video.kind |> should.equal(inbound.Video)
  video.seconds |> should.equal(Some(70))

  let assert inbound.Answer(attachments: [note], ..) =
    inbound.decide(message(
      private_chat <> "\"video_note\":\"statics/media/n.mp4\"",
    ))
  note.kind |> should.equal(inbound.Video)

  let assert inbound.Answer(attachments: [document], ..) =
    inbound.decide(message(
      private_chat
      <> "\"document\":{\"path\":\"statics/media/contrato.pdf\"},\"media_info\":{\"mime_type\":\"application/pdf\",\"file_name\":\"contrato.pdf\"}",
    ))
  document.kind |> should.equal(inbound.Document)
  document.file_name |> should.equal(Some("contrato.pdf"))

  let assert inbound.Answer(attachments: [sticker], ..) =
    inbound.decide(message(
      private_chat <> "\"sticker\":\"statics/media/s.webp\"",
    ))
  sticker.kind |> should.equal(inbound.Sticker)
  let assert inbound.Answer(attachments: [animated], ..) =
    inbound.decide(message(
      private_chat
      <> "\"sticker\":\"statics/media/s.webp\",\"media_info\":{\"is_animated\":true}",
    ))
  animated.kind |> should.equal(inbound.AnimatedSticker)
}

pub fn location_contact_and_poll_become_text_test() {
  let assert inbound.Answer(msg, attachments: [], ..) =
    inbound.decide(message(
      private_chat
      <> "\"location\":{\"degreesLatitude\":-6.2088,\"degreesLongitude\":106.8456,\"name\":\"Jakarta, Indonesia\",\"address\":\"Central Jakarta\"}",
    ))
  msg.content
  |> should.equal(
    "[localização: Jakarta, Indonesia, Central Jakarta (-6.2088, 106.8456)]",
  )

  let assert inbound.Answer(msg, ..) =
    inbound.decide(message(
      private_chat
      <> "\"live_location\":{\"degreesLatitude\":1.5,\"degreesLongitude\":2.5}",
    ))
  msg.content |> should.equal("[localização em tempo real: (1.5, 2.5)]")

  let assert inbound.Answer(msg, ..) =
    inbound.decide(message(
      private_chat
      <> "\"contact\":{\"displayName\":\"Ana\",\"vcard\":\"BEGIN:VCARD\\nEND:VCARD\",\"phone_number\":\"5511988887777\"}",
    ))
  msg.content |> should.equal("[contato: Ana, 5511988887777]")

  let assert inbound.Answer(msg, ..) =
    inbound.decide(message(
      private_chat
      <> "\"contacts_array\":[{\"displayName\":\"Ana\",\"phone_number\":\"1\"},{\"displayName\":\"Bia\",\"phone_number\":\"2\"}]",
    ))
  msg.content |> should.equal("[contato: Ana, 1]\n[contato: Bia, 2]")

  let assert inbound.Answer(msg, ..) =
    inbound.decide(message(
      private_chat
      <> "\"poll\":{\"type\":\"creation\",\"question\":\"Pizza ou sushi?\",\"options\":[{\"name\":\"Pizza\"},{\"name\":\"Sushi\"}]}",
    ))
  msg.content |> should.equal("[enquete: Pizza ou sushi? (Pizza; Sushi)]")
}

pub fn notes_name_what_could_not_be_opened_test() {
  let audio =
    inbound.Attachment(
      kind: inbound.Audio,
      path: Some("statics/media/a.ogg"),
      seconds: Some(42),
      file_name: None,
      mime: None,
      voice_note: True,
    )
  inbound.unopened_note(audio, False)
  |> should.equal("[uma mensagem de voz de 0:42, que ainda não consigo ouvir]")
  inbound.unopened_note(inbound.Attachment(..audio, voice_note: False), True)
  |> should.equal("[um áudio encaminhado de 0:42, que ainda não consigo ouvir]")
  inbound.unopened_note(
    inbound.Attachment(..audio, kind: inbound.Video, seconds: Some(3723)),
    False,
  )
  |> should.equal("[um vídeo de 1:02:03, que ainda não consigo ver]")
  inbound.unopened_note(
    inbound.Attachment(
      ..audio,
      kind: inbound.Document,
      seconds: None,
      file_name: Some("contrato.pdf"),
    ),
    False,
  )
  |> should.equal("[um documento (contrato.pdf), que ainda não consigo ler]")
  inbound.unopened_note(
    inbound.Attachment(..audio, kind: inbound.AnimatedSticker),
    False,
  )
  |> should.equal("[uma figurinha animada]")
}
