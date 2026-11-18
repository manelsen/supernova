//// Tests for the Access Control Actor module
////
//// Integration tests — actor lifecycle and JSON persistence under a
//// temporary `/tmp` directory. No network, no LLM, no real credentials.

import exception
import gleam/string
import gleeunit
import gleeunit/should
import supernova/core/access/actor
import supernova/core/access/types.{
  type AccessConfig, AccessConfig, Admin, Allowed, Allowlist, ChatAllowed,
  ChatDenied, Denied, Member, Open,
}
import test_workspace

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn with_temp_dir(body: fn(String) -> Nil) -> Nil {
  let dir = test_workspace.create_temp_dir("access")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(dir)
}

fn config(
  admins: List(String),
  members: List(String),
  chats: List(String),
) -> AccessConfig {
  AccessConfig(
    mode: Allowlist,
    admins: admins,
    members: members,
    denied_reply: "Esta instância é privada.",
    allowed_chats: chats,
  )
}

@external(erlang, "supernova_file_system_ffi", "write_file")
fn ffi_write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)

// ============================================================================
// Decisions
// ============================================================================

pub fn deny_by_default_test() {
  with_temp_dir(fn(dir) {
    let assert Ok(access) =
      actor.start_with_clock(config([], [], []), dir, fn() { 1000 })

    actor.check(access, "telegram:1") |> should.equal(Denied)

    actor.stop(access)
  })
}

pub fn member_and_admin_pass_test() {
  with_temp_dir(fn(dir) {
    let assert Ok(access) =
      actor.start_with_clock(
        config(["telegram:1"], ["discord:2"], []),
        dir,
        fn() { 1000 },
      )

    actor.check(access, "telegram:1") |> should.equal(Allowed(Admin))
    actor.check(access, "discord:2") |> should.equal(Allowed(Member))
    actor.check(access, "telegram:99") |> should.equal(Denied)

    actor.is_admin(access, "telegram:1") |> should.be_true()
    actor.is_admin(access, "discord:2") |> should.be_false()

    actor.stop(access)
  })
}

pub fn open_mode_allows_everyone_test() {
  with_temp_dir(fn(dir) {
    let open_config =
      AccessConfig(
        mode: Open,
        admins: [],
        members: [],
        denied_reply: "Esta instância é privada.",
        allowed_chats: [],
      )
    let assert Ok(access) =
      actor.start_with_clock(open_config, dir, fn() { 1000 })

    actor.check(access, "telegram:777") |> should.equal(Allowed(Member))

    actor.stop(access)
  })
}

// ============================================================================
// Chats
// ============================================================================

pub fn chat_allowlist_controls_groups_test() {
  with_temp_dir(fn(dir) {
    let assert Ok(access) =
      actor.start_with_clock(config([], ["telegram:1"], []), dir, fn() { 1000 })

    actor.check_chat(access, "telegram:1", "telegram:1", True)
    |> should.equal(ChatAllowed)

    actor.check_chat(access, "telegram:1", "telegram:-100", False)
    |> should.equal(ChatDenied)

    actor.add_chat(access, "telegram:-100") |> should.be_ok()

    actor.check_chat(access, "telegram:1", "telegram:-100", False)
    |> should.equal(ChatAllowed)

    actor.list_chats(access) |> should.equal(["telegram:-100"])

    actor.remove_chat(access, "telegram:-100") |> should.be_ok()

    actor.check_chat(access, "telegram:1", "telegram:-100", False)
    |> should.equal(ChatDenied)

    actor.stop(access)
  })
}

pub fn unauthorized_principal_denied_in_private_chat_test() {
  with_temp_dir(fn(dir) {
    let assert Ok(access) =
      actor.start_with_clock(config([], [], []), dir, fn() { 1000 })

    actor.check_chat(access, "telegram:1", "telegram:1", True)
    |> should.equal(ChatDenied)

    actor.stop(access)
  })
}

// ============================================================================
// Mutations and persistence
// ============================================================================

pub fn admin_commands_persist_across_restart_test() {
  with_temp_dir(fn(dir) {
    let assert Ok(first) =
      actor.start_with_clock(config(["telegram:1"], [], []), dir, fn() { 1000 })

    first
    |> actor.add_member("telegram:2", Member)
    |> should.be_ok()
    first
    |> actor.add_member("discord:3", Admin)
    |> should.be_ok()
    first
    |> actor.add_chat("telegram:-100")
    |> should.be_ok()

    actor.list_members(first) |> should.equal(["telegram:2"])
    actor.list_admins(first) |> should.equal(["telegram:1", "discord:3"])

    actor.stop(first)

    // The YAML base is authoritative: removing telegram:1 from config
    // revokes it on restart, while command-added entries survive.
    let assert Ok(second) =
      actor.start_with_clock(config([], [], []), dir, fn() { 2000 })

    actor.check(second, "telegram:1") |> should.equal(Denied)
    actor.check(second, "telegram:2") |> should.equal(Allowed(Member))
    actor.check(second, "discord:3") |> should.equal(Allowed(Admin))
    actor.list_members(second) |> should.equal(["telegram:2"])
    actor.list_admins(second) |> should.equal(["discord:3"])
    actor.list_chats(second) |> should.equal(["telegram:-100"])

    actor.stop(second)
  })
}

pub fn removing_a_member_persists_test() {
  with_temp_dir(fn(dir) {
    let assert Ok(first) =
      actor.start_with_clock(
        config(["telegram:1"], ["telegram:2"], []),
        dir,
        fn() { 1000 },
      )

    first |> actor.remove_member("telegram:2") |> should.be_ok()
    actor.list_members(first) |> should.equal([])

    actor.stop(first)

    let assert Ok(second) =
      actor.start_with_clock(config([], [], []), dir, fn() { 2000 })

    actor.check(second, "telegram:2") |> should.equal(Denied)

    actor.stop(second)
  })
}

pub fn cannot_remove_last_admin_test() {
  with_temp_dir(fn(dir) {
    let assert Ok(access) =
      actor.start_with_clock(config(["telegram:1"], [], []), dir, fn() { 1000 })

    access |> actor.remove_member("telegram:1") |> should.be_error()
    actor.list_admins(access) |> should.equal(["telegram:1"])

    access
    |> actor.add_member("telegram:2", Admin)
    |> should.be_ok()
    access |> actor.remove_member("telegram:1") |> should.be_ok()
    actor.list_admins(access) |> should.equal(["telegram:2"])

    actor.stop(access)
  })
}

pub fn promoting_a_member_to_admin_moves_lists_test() {
  with_temp_dir(fn(dir) {
    let assert Ok(access) =
      actor.start_with_clock(
        config(["telegram:1"], ["telegram:2"], []),
        dir,
        fn() { 1000 },
      )

    access
    |> actor.add_member("telegram:2", Admin)
    |> should.be_ok()

    actor.list_admins(access) |> should.equal(["telegram:1", "telegram:2"])
    actor.list_members(access) |> should.equal([])

    actor.stop(access)
  })
}

pub fn corrupted_state_file_falls_back_to_config_test() {
  with_temp_dir(fn(dir) {
    let assert Ok(_) =
      ffi_write_file(dir <> "/access.json", "{ definitely not json")

    let assert Ok(access) =
      actor.start_with_clock(config(["telegram:1"], [], []), dir, fn() { 1000 })

    actor.check(access, "telegram:1") |> should.equal(Allowed(Admin))
    actor.check(access, "telegram:2") |> should.equal(Denied)

    actor.stop(access)
  })
}

pub fn yaml_revocation_survives_denials_test() {
  with_temp_dir(fn(dir) {
    let assert Ok(first) =
      actor.start_with_clock(config([], ["telegram:A"], []), dir, fn() { 1000 })

    actor.take_denied_notice(first, "telegram:B") |> should.be_true()

    actor.stop(first)

    let assert Ok(second) =
      actor.start_with_clock(config([], [], []), dir, fn() { 2000 })

    actor.check(second, "telegram:A") |> should.equal(Denied)
    actor.check(second, "telegram:B") |> should.equal(Denied)

    actor.stop(second)
  })
}

pub fn command_removal_survives_yaml_restart_test() {
  with_temp_dir(fn(dir) {
    let base = config([], ["telegram:A", "telegram:C"], [])

    let assert Ok(first) = actor.start_with_clock(base, dir, fn() { 1000 })
    first |> actor.remove_member("telegram:A") |> should.be_ok()
    actor.stop(first)

    let assert Ok(second) = actor.start_with_clock(base, dir, fn() { 2000 })
    actor.check(second, "telegram:A") |> should.equal(Denied)
    actor.check(second, "telegram:C") |> should.equal(Allowed(Member))
    actor.stop(second)
  })
}

pub fn added_member_survives_without_yaml_test() {
  with_temp_dir(fn(dir) {
    let assert Ok(first) =
      actor.start_with_clock(config([], [], []), dir, fn() { 1000 })
    first |> actor.add_member("telegram:D", Member) |> should.be_ok()
    actor.stop(first)

    let assert Ok(second) =
      actor.start_with_clock(config([], [], []), dir, fn() { 2000 })
    actor.check(second, "telegram:D") |> should.equal(Allowed(Member))
    actor.stop(second)
  })
}

pub fn legacy_full_list_file_is_migrated_test() {
  with_temp_dir(fn(dir) {
    let legacy =
      "{\"version\":1,\"admins\":[],\"members\":[\"telegram:A\"],\"allowed_chats\":[]}"
    let assert Ok(_) = ffi_write_file(dir <> "/access.json", legacy)

    let assert Ok(access) =
      actor.start_with_clock(config([], [], []), dir, fn() { 1000 })
    actor.check(access, "telegram:A") |> should.equal(Allowed(Member))
    actor.stop(access)

    let assert Ok(rewritten) = ffi_read_file(dir <> "/access.json")
    rewritten |> should_contain("\"version\":2")
    rewritten |> should_contain("\"added\"")
  })
}

pub fn notice_write_does_not_store_effective_lists_test() {
  with_temp_dir(fn(dir) {
    let base = config(["telegram:5"], ["telegram:A"], ["telegram:-100"])
    let assert Ok(access) = actor.start_with_clock(base, dir, fn() { 1000 })
    actor.take_denied_notice(access, "telegram:B") |> should.be_true()
    actor.stop(access)

    let assert Ok(text) = ffi_read_file(dir <> "/access.json")
    text |> should_contain("\"denied_notices\"")
    text |> should_not_contain("\"admins\":[\"telegram:5\"]")
    text |> should_not_contain("\"members\":[\"telegram:A\"]")
  })
}

fn should_contain(text: String, needle: String) -> Nil {
  case string.contains(text, needle) {
    False -> panic as "missing expected content"
    True -> Nil
  }
}

fn should_not_contain(text: String, needle: String) -> Nil {
  case string.contains(text, needle) {
    True -> panic as "unexpected content"
    False -> Nil
  }
}

// ============================================================================
// Denial notices
// ============================================================================

pub fn denial_notice_at_most_once_per_day_test() {
  with_temp_dir(fn(dir) {
    let base = config([], [], [])

    let assert Ok(first) = actor.start_with_clock(base, dir, fn() { 1000 })

    actor.take_denied_notice(first, "telegram:1") |> should.be_true()
    actor.take_denied_notice(first, "telegram:1") |> should.be_false()
    actor.take_denied_notice(first, "telegram:2") |> should.be_true()

    actor.stop(first)

    // Restart within the 24 h window: the notice stays suppressed.
    let assert Ok(second) =
      actor.start_with_clock(base, dir, fn() { 1000 + 86_400_000 - 1 })

    actor.take_denied_notice(second, "telegram:1") |> should.be_false()

    actor.stop(second)

    // Restart after the window: a new notice is due.
    let assert Ok(third) =
      actor.start_with_clock(base, dir, fn() { 1000 + 86_400_000 })

    actor.take_denied_notice(third, "telegram:1") |> should.be_true()

    actor.stop(third)
  })
}

pub fn chat_denial_notice_at_most_once_per_day_test() {
  with_temp_dir(fn(dir) {
    let base = config([], [], [])

    let assert Ok(first) = actor.start_with_clock(base, dir, fn() { 5000 })

    actor.take_chat_denied_notice(first, "telegram:-100")
    |> should.be_true()
    actor.take_chat_denied_notice(first, "telegram:-100")
    |> should.be_false()

    actor.stop(first)

    let assert Ok(second) =
      actor.start_with_clock(base, dir, fn() { 5000 + 86_400_000 })

    actor.take_chat_denied_notice(second, "telegram:-100")
    |> should.be_true()

    actor.stop(second)
  })
}

pub fn stored_revocation_survives_unrelated_command_and_yaml_gap_test() {
  with_temp_dir(fn(dir) {
    let base = config([], ["telegram:A", "telegram:C"], [])

    let assert Ok(first) = actor.start_with_clock(base, dir, fn() { 1000 })
    first |> actor.remove_member("telegram:A") |> should.be_ok()
    actor.stop(first)

    // Operator temporarily removes A from YAML; the actor is restarted.
    let assert Ok(second) =
      actor.start_with_clock(config([], ["telegram:C"], []), dir, fn() { 2000 })
    actor.check(second, "telegram:A") |> should.equal(Denied)
    second |> actor.add_chat("telegram:-100") |> should.be_ok()
    actor.stop(second)

    // YAML restores A; the stored revocation must still win.
    let assert Ok(third) = actor.start_with_clock(base, dir, fn() { 3000 })
    actor.check(third, "telegram:A") |> should.equal(Denied)
    actor.check(third, "telegram:C") |> should.equal(Allowed(Member))
    actor.stop(third)
  })
}
