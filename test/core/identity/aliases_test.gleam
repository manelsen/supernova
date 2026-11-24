//// PRD-I, I-01: one person, one agent. A linked identity is an alias of
//// the person's first one, and every derivation of a principal resolves it.

import gleeunit/should
import supernova/core/agent_identity
import supernova/core/identity/aliases
import test_workspace

pub fn an_unknown_identity_is_itself_test() {
  aliases.resolve("telegram:i01-ninguem")
  |> should.equal("telegram:i01-ninguem")
}

pub fn a_link_resolves_and_survives_a_restart_test() {
  let dir = test_workspace.create_temp_dir("aliases-restart")
  let assert Ok(Nil) =
    aliases.link(dir, "whatsapp:i01-5511", "telegram:i01-1", "whatsapp", 1000)
  aliases.resolve("whatsapp:i01-5511") |> should.equal("telegram:i01-1")
  aliases.aliases_of("telegram:i01-1") |> should.equal(["whatsapp:i01-5511"])

  // A fresh start reads the file.
  aliases.forget_loaded()
  aliases.resolve("whatsapp:i01-5511") |> should.equal("whatsapp:i01-5511")
  let assert Ok(Nil) = aliases.load(dir)
  aliases.resolve("whatsapp:i01-5511") |> should.equal("telegram:i01-1")

  let assert Ok(Nil) = aliases.unlink(dir, "whatsapp:i01-5511")
  aliases.resolve("whatsapp:i01-5511") |> should.equal("whatsapp:i01-5511")
  aliases.aliases_of("telegram:i01-1") |> should.equal([])
  test_workspace.remove_dir_recursive(dir)
}

pub fn an_alias_never_points_to_an_alias_test() {
  let dir = test_workspace.create_temp_dir("aliases-chain")
  let assert Ok(Nil) =
    aliases.link(
      dir,
      "whatsapp:i01-chain-a",
      "telegram:i01-chain",
      "whatsapp",
      1,
    )
  // Linking to an alias links to its person.
  let assert Ok(Nil) =
    aliases.link(
      dir,
      "discord:i01-chain-b",
      "whatsapp:i01-chain-a",
      "discord",
      2,
    )
  aliases.resolve("discord:i01-chain-b") |> should.equal("telegram:i01-chain")
  // A person with aliases cannot become an alias.
  aliases.link(dir, "telegram:i01-chain", "sim:i01-outra", "telegram", 3)
  |> should.be_error
  test_workspace.remove_dir_recursive(dir)
}

pub fn invalid_links_are_refused_test() {
  let dir = test_workspace.create_temp_dir("aliases-invalid")
  aliases.link(dir, "telegram:i01-x", "telegram:i01-x", "telegram", 1)
  |> should.be_error
  let assert Ok(Nil) =
    aliases.link(dir, "whatsapp:i01-y", "telegram:i01-y", "whatsapp", 1)
  // Already linked to someone: unlink first.
  aliases.link(dir, "whatsapp:i01-y", "telegram:i01-z", "whatsapp", 2)
  |> should.be_error
  aliases.unlink(dir, "whatsapp:i01-nunca") |> should.be_error
  test_workspace.remove_dir_recursive(dir)
}

pub fn every_derivation_of_a_principal_resolves_test() {
  let dir = test_workspace.create_temp_dir("aliases-derive")
  let assert Ok(Nil) =
    aliases.link(dir, "whatsapp:i01-55", "telegram:i01-7", "whatsapp", 1)
  agent_identity.principal_id("whatsapp", "i01-55")
  |> should.equal("telegram:i01-7")
  agent_identity.principal_from_session_id("whatsapp:grupo@g.us:i01-55")
  |> should.equal("telegram:i01-7")
  agent_identity.principal_from_session_id("telegram:i01-7:i01-7")
  |> should.equal("telegram:i01-7")
  test_workspace.remove_dir_recursive(dir)
}
