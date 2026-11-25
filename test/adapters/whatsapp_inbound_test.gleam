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
    inbound.decide(message(group <> "\"body\":\"bom dia, gente\""))
  // A mention of the agent.
  let assert inbound.Answer(msg, ..) =
    inbound.decide(message(
      group
      <> "\"body\":\"@628987654321 pode ver isso?\",\"mentions\":[\""
      <> agent
      <> "\",\"628111111111@s.whatsapp.net\"]",
    ))
  msg.channel_id |> should.equal("120363012345678901@g.us")
  // A reply to the agent.
  let assert inbound.Answer(..) =
    inbound.decide(message(
      group
      <> "\"body\":\"isso\",\"replied_to_id\":\"Z\",\"replied_to_sender\":\""
      <> agent
      <> "\"",
    ))
  // A command.
  let assert inbound.Answer(..) =
    inbound.decide(message(group <> "\"body\":\"/eu\""))
  // A mention of someone else.
  let assert inbound.Ignore(_) =
    inbound.decide(message(
      group
      <> "\"body\":\"@628111111111 oi\",\"mentions\":[\"628111111111@s.whatsapp.net\"]",
    ))
}

pub fn a_known_lid_is_its_person_an_unknown_one_is_asked_to_write_privately_test() {
  let dir = test_workspace.create_temp_dir("wa-lid")
  let group =
    "\"chat_id\":\"120363012345678901@g.us\",\"from\":\"999@lid\",\"body\":\"/eu\""
  inbound.decide(message(group))
  |> should.equal(inbound.AskPrivate(
    chat_id: "120363012345678901@g.us",
    reply_to: "3EB0C127D7BACC83D6A1",
  ))
  // In private an unknown LID is only logged.
  let assert inbound.Ignore(_) =
    inbound.decide(message(
      "\"chat_id\":\"999@lid\",\"from\":\"999@lid\",\"body\":\"oi\"",
    ))

  let assert Ok(Nil) =
    aliases.link(dir, "whatsapp:999@lid", "whatsapp:62999", "whatsapp", 1)
  let assert inbound.Answer(msg, ..) = inbound.decide(message(group))
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
  let assert inbound.Answer(msg, image: Some(path), ..) =
    inbound.decide(message(
      private <> "\"image\":\"statics/media/1752404751-ad9e.jpeg\"",
    ))
  path |> should.equal("statics/media/1752404751-ad9e.jpeg")
  msg.content |> should.equal("")
  let assert inbound.Answer(msg, image: Some(_), ..) =
    inbound.decide(message(
      private
      <> "\"body\":\"olha\",\"image\":{\"path\":\"statics/media/x.jpeg\",\"caption\":\"olha\"}",
    ))
  msg.content |> should.equal("olha")
  // Not downloaded: only WhatsApp's encrypted URL, so no image.
  let assert inbound.Answer(msg, image: None, ..) =
    inbound.decide(message(
      private
      <> "\"image\":{\"url\":\"https://mmg.whatsapp.net/x\",\"caption\":\"veja\"}",
    ))
  msg.content |> should.equal("veja")
}
