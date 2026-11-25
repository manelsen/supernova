//// Channel rules come from each channel's traits.

import gleam/list
import gleam/string
import gleeunit/should
import supernova/channel/catalog

pub fn telegram_rules_test() {
  let telegram = catalog.get("telegram")
  telegram.is_private_chat("123") |> should.be_true()
  telegram.is_private_chat("-100123") |> should.be_false()
  telegram.is_private_chat("") |> should.be_false()
  telegram.chat_key("-100123") |> should.equal("telegram:-100123")
  telegram.private_delivery |> should.be_true()
}

pub fn discord_rules_test() {
  let discord = catalog.get("discord")
  discord.is_private_chat("dm:42") |> should.be_true()
  discord.is_private_chat("777@guild:9") |> should.be_false()
  discord.chat_key("dm:42") |> should.equal("discord:dm:42")
  discord.chat_key("777@guild:9") |> should.equal("discord:guild:9")
  discord.chat_key("777") |> should.equal("discord:guild:777")
  discord.private_delivery |> should.be_false()
}

pub fn generic_and_unknown_channels_test() {
  let slack = catalog.get("slack")
  slack.has_principals |> should.be_false()
  slack.is_private_chat("D1") |> should.be_false()
  slack.chat_key("C1") |> should.equal("slack:C1")
  let other = catalog.get("pombo")
  other.chat_key("x") |> should.equal("pombo:x")
  other.private_delivery |> should.be_false()
}

pub fn principal_channels_and_group_keys_test() {
  catalog.principal_channels()
  |> should.equal(["telegram", "discord", "whatsapp"])
  catalog.is_group_key("whatsapp:120363012345678901@g.us") |> should.be_true()
  catalog.is_group_key("telegram:-100") |> should.be_true()
  catalog.is_group_key("discord:guild:9") |> should.be_true()
  catalog.is_group_key("sim:1") |> should.be_true()
  catalog.is_group_key("telegram:") |> should.be_false()
  catalog.is_group_key("discord:dm:1") |> should.be_false()
  catalog.is_group_key("slack:C1") |> should.be_false()
}

/// PRD-C, C-01: what the core used to ask by channel name.
pub fn inbound_routing_and_interactions_are_traits_test() {
  let routed =
    catalog.all()
    |> list.filter(fn(channel) { channel.routes_inbound })
    |> list.map(fn(channel) { channel.name })
  routed
  |> should.equal(["telegram", "discord", "sim", "matrix", "slack", "whatsapp"])

  let interactive =
    catalog.all()
    |> list.filter(fn(channel) { channel.supports_interactions })
    |> list.map(fn(channel) { channel.name })
  interactive |> should.equal(["telegram", "discord", "slack"])

  catalog.get("telegram").edits_interaction_source |> should.be_true()
  catalog.get("discord").edits_interaction_source |> should.be_false()
  catalog.get("sim").turn_timeout_ms |> should.equal(300_000)
  catalog.get("telegram").turn_timeout_ms |> should.equal(30_000)
  catalog.get("nenhum").routes_inbound |> should.be_false()
}

pub fn a_person_is_reached_privately_through_the_traits_test() {
  catalog.get("discord").private_chat_for("42") |> should.equal("open-dm:42")
  catalog.get("telegram").private_chat_for("42") |> should.equal("42")
  catalog.get("matrix").private_chat_for("@a:b") |> should.equal("@a:b")
}

/// PRD-C, C-04: WhatsApp chats and people.
pub fn whatsapp_rules_test() {
  let whatsapp = catalog.get("whatsapp")
  whatsapp.is_private_chat("628123456789@s.whatsapp.net") |> should.be_true()
  whatsapp.is_private_chat("999@lid") |> should.be_true()
  whatsapp.is_private_chat("120363012345678901@g.us") |> should.be_false()
  whatsapp.chat_key("120363012345678901@g.us")
  |> should.equal("whatsapp:120363012345678901@g.us")
  whatsapp.private_chat_for("628123456789")
  |> should.equal("628123456789@s.whatsapp.net")
  whatsapp.private_chat_for("999@lid") |> should.equal("999@lid")
  whatsapp.receives_by_webhook |> should.be_true()
  whatsapp.supports_interactions |> should.be_false()
  whatsapp.sends_voice |> should.be_true()
  string.contains(whatsapp.help_commands, "/voz") |> should.be_true()
}
