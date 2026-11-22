//// Channel rules come from each channel's traits.

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
  catalog.principal_channels() |> should.equal(["telegram", "discord"])
  catalog.is_group_key("telegram:-100") |> should.be_true()
  catalog.is_group_key("discord:guild:9") |> should.be_true()
  catalog.is_group_key("sim:1") |> should.be_true()
  catalog.is_group_key("telegram:") |> should.be_false()
  catalog.is_group_key("discord:dm:1") |> should.be_false()
  catalog.is_group_key("slack:C1") |> should.be_false()
}
