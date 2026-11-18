//// Tests for the Access Control Pure module
////
//// Pure tests — no actors, no I/O, no FFI.

import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/core/access/pure
import supernova/core/access/types.{
  type AccessConfig, AccessConfig, AddAccess, AddChat, Admin, Allowed, Allowlist,
  ChatAllowed, ChatDenied, Denied, ListAccess, ListChats, Member, Open,
  PersistedLists, PersistedState, RemoveAccess, RemoveChat, empty_lists,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn allowlist(admins: List(String), members: List(String)) -> AccessConfig {
  AccessConfig(
    mode: Allowlist,
    admins: admins,
    members: members,
    denied_reply: "Esta instância é privada.",
    allowed_chats: [],
  )
}

fn open(members: List(String)) -> AccessConfig {
  AccessConfig(
    mode: Open,
    admins: [],
    members: members,
    denied_reply: "Esta instância é privada.",
    allowed_chats: [],
  )
}

// ============================================================================
// decide
// ============================================================================

pub fn default_denies_test() {
  pure.decide(allowlist([], []), "telegram:123")
  |> should.equal(Denied)
}

pub fn member_passes_test() {
  pure.decide(allowlist([], ["telegram:123"]), "telegram:123")
  |> should.equal(Allowed(Member))
}

pub fn admin_passes_test() {
  pure.decide(allowlist(["telegram:1"], []), "telegram:1")
  |> should.equal(Allowed(Admin))
}

pub fn admin_wins_when_also_member_test() {
  pure.decide(allowlist(["telegram:1"], ["telegram:1"]), "telegram:1")
  |> should.equal(Allowed(Admin))
}

pub fn open_mode_allows_unknown_as_member_test() {
  pure.decide(open([]), "discord:999")
  |> should.equal(Allowed(Member))
}

pub fn open_mode_keeps_admin_role_test() {
  let config = AccessConfig(..open([]), admins: ["discord:1"])
  pure.decide(config, "discord:1")
  |> should.equal(Allowed(Admin))
}

// ============================================================================
// decide_chat
// ============================================================================

pub fn private_chat_allowed_for_member_test() {
  let config = allowlist([], ["telegram:123"])
  pure.decide_chat(config, "telegram:123", "telegram:123", True)
  |> should.equal(ChatAllowed)
}

pub fn group_chat_denied_by_default_test() {
  let config = allowlist([], ["telegram:123"])
  pure.decide_chat(config, "telegram:123", "telegram:-100", False)
  |> should.equal(ChatDenied)
}

pub fn authorized_group_chat_allowed_test() {
  let config =
    AccessConfig(..allowlist([], ["telegram:123"]), allowed_chats: [
      "telegram:-100",
    ])
  pure.decide_chat(config, "telegram:123", "telegram:-100", False)
  |> should.equal(ChatAllowed)
}

pub fn unauthorized_principal_denied_even_in_private_test() {
  let config = allowlist([], [])
  pure.decide_chat(config, "telegram:123", "telegram:123", True)
  |> should.equal(ChatDenied)
}

pub fn open_mode_still_requires_group_allowlist_test() {
  pure.decide_chat(open([]), "discord:9", "discord:guild:9", False)
  |> should.equal(ChatDenied)
}

// ============================================================================
// role_name / authorization
// ============================================================================

pub fn role_names_test() {
  pure.role_name(Admin) |> should.equal("admin")
  pure.role_name(Member) |> should.equal("membro")
}

pub fn only_admin_can_manage_access_test() {
  pure.can_manage_access(Allowed(Admin)) |> should.be_true()
  pure.can_manage_access(Allowed(Member)) |> should.be_false()
  pure.can_manage_access(Denied) |> should.be_false()
}

// ============================================================================
// parse_command
// ============================================================================

pub fn parse_list_test() {
  pure.parse_command("/acesso listar")
  |> should.equal(Some(ListAccess))
}

pub fn parse_add_defaults_to_member_test() {
  pure.parse_command("/acesso adicionar telegram:123")
  |> should.equal(Some(AddAccess("telegram:123", Member)))
}

pub fn parse_add_admin_test() {
  pure.parse_command("/acesso adicionar telegram:123 admin")
  |> should.equal(Some(AddAccess("telegram:123", Admin)))
}

pub fn parse_add_member_alias_test() {
  pure.parse_command("/acesso adicionar telegram:123 membro")
  |> should.equal(Some(AddAccess("telegram:123", Member)))
}

pub fn parse_remove_test() {
  pure.parse_command("/acesso remover telegram:123")
  |> should.equal(Some(RemoveAccess("telegram:123")))
}

pub fn parse_chat_commands_test() {
  pure.parse_command("/acesso chat adicionar telegram:-100")
  |> should.equal(Some(AddChat("telegram:-100")))
  pure.parse_command("/acesso chat remover telegram:-100")
  |> should.equal(Some(RemoveChat("telegram:-100")))
  pure.parse_command("/acesso chat listar")
  |> should.equal(Some(ListChats))
}

pub fn parse_tolerates_extra_spacing_and_bot_suffix_test() {
  pure.parse_command("  /acesso@SupernovaBot   listar  ")
  |> should.equal(Some(ListAccess))
}

pub fn parse_rejects_invalid_commands_test() {
  pure.parse_command("/acesso") |> should.equal(None)
  pure.parse_command("/acesso adicionar") |> should.equal(None)
  pure.parse_command("/acesso adicionar telegram:1 superadmin")
  |> should.equal(None)
  pure.parse_command("/acesso remover telegram:1 extra")
  |> should.equal(None)
  pure.parse_command("/ajuda") |> should.equal(None)
  pure.parse_command("") |> should.equal(None)
}

// ============================================================================
// Mutations
// ============================================================================

pub fn add_member_promotes_to_admin_and_dedupes_test() {
  let config = allowlist([], ["telegram:1"])
  let updated = pure.add_member(config, "telegram:1", Admin)

  updated.admins |> should.equal(["telegram:1"])
  updated.members |> should.equal([])
}

pub fn add_member_does_not_demote_admin_test() {
  let config = allowlist(["telegram:1"], [])
  let updated = pure.add_member(config, "telegram:1", Member)

  updated.admins |> should.equal(["telegram:1"])
  updated.members |> should.equal([])
}

pub fn add_member_is_idempotent_test() {
  let config = allowlist([], ["telegram:1"])
  let updated = pure.add_member(config, "telegram:1", Member)

  updated.members |> should.equal(["telegram:1"])
}

pub fn remove_last_admin_is_refused_test() {
  let config = allowlist(["telegram:1"], [])
  pure.remove_member(config, "telegram:1")
  |> should.be_error()
}

pub fn remove_admin_when_another_remains_test() {
  let config = allowlist(["telegram:1", "telegram:2"], [])
  let assert Ok(updated) = pure.remove_member(config, "telegram:1")

  updated.admins |> should.equal(["telegram:2"])
}

pub fn remove_member_test() {
  let config = allowlist(["telegram:1"], ["telegram:2"])
  let assert Ok(updated) = pure.remove_member(config, "telegram:2")

  updated.members |> should.equal([])
  updated.admins |> should.equal(["telegram:1"])
}

pub fn chat_allowlist_mutations_test() {
  let config = allowlist([], [])
  let updated = pure.add_chat(config, "telegram:-100")
  updated.allowed_chats |> should.equal(["telegram:-100"])

  pure.add_chat(updated, "telegram:-100") |> should.equal(updated)

  pure.remove_chat(updated, "telegram:-100").allowed_chats
  |> should.equal([])
}

// ============================================================================
// Notice throttling
// ============================================================================

pub fn notice_due_first_time_test() {
  pure.notice_due(None, 1000, pure.day_ms) |> should.be_true()
}

pub fn notice_suppressed_within_day_test() {
  pure.notice_due(Some(1000), 1000 + pure.day_ms - 1, pure.day_ms)
  |> should.be_false()
}

pub fn notice_due_after_day_test() {
  pure.notice_due(Some(1000), 1000 + pure.day_ms, pure.day_ms)
  |> should.be_true()
}

pub fn notice_suppressed_on_clock_skew_test() {
  pure.notice_due(Some(10_000), 1000, pure.day_ms)
  |> should.be_false()
}

// ============================================================================
// Persistence round-trip
// ============================================================================

pub fn encode_decode_round_trip_test() {
  let base =
    AccessConfig(
      mode: Allowlist,
      admins: ["telegram:1"],
      members: ["discord:2"],
      denied_reply: "privada",
      allowed_chats: ["telegram:-100", "discord:guild:7"],
    )
  let denied = dict.from_list([#("telegram:9", 123_456)])
  let chat_denied = dict.from_list([#("telegram:-999", 654_321)])
  let persisted =
    PersistedState(
      added: PersistedLists(
        admins: ["telegram:3"],
        members: ["discord:4"],
        allowed_chats: ["telegram:-200"],
      ),
      removed: PersistedLists(
        admins: ["telegram:1"],
        members: [],
        allowed_chats: ["telegram:-100"],
      ),
      denied_notices: denied,
      chat_denied_notices: chat_denied,
    )

  let encoded = pure.encode_state(persisted)
  let assert Ok(decoded) = pure.decode_state(base, encoded)

  decoded |> should.equal(persisted)

  let restored = pure.apply_persisted(base, persisted)
  restored.admins |> should.equal(["telegram:3"])
  restored.members |> should.equal(["discord:2", "discord:4"])
  restored.allowed_chats |> should.equal(["discord:guild:7", "telegram:-200"])
  restored.mode |> should.equal(Allowlist)
  restored.denied_reply |> should.equal("privada")
}

pub fn encode_state_stores_only_deltas_test() {
  let encoded =
    pure.encode_state(PersistedState(
      added: empty_lists(),
      removed: empty_lists(),
      denied_notices: dict.new(),
      chat_denied_notices: dict.new(),
    ))

  encoded |> should_contain("\"added\"")
  encoded |> should_contain("\"removed\"")
  encoded |> should_not_contain("\"admins\":[\"telegram:1\"]")
}

pub fn legacy_full_lists_become_added_deltas_test() {
  let base = allowlist([], ["telegram:A", "telegram:C"])
  let legacy =
    "{\"version\":1,\"admins\":[],\"members\":[\"telegram:A\",\"telegram:B\"],\"allowed_chats\":[\"telegram:-100\"],\"denied_notices\":{\"telegram:9\":123}}"

  let assert Ok(persisted) = pure.decode_state(base, legacy)

  persisted.added.members |> should.equal(["telegram:B"])
  persisted.removed.members |> should.equal([])
  persisted.denied_notices
  |> should.equal(dict.from_list([#("telegram:9", 123)]))

  let restored = pure.apply_persisted(base, persisted)
  restored.members |> should.equal(["telegram:A", "telegram:C", "telegram:B"])
}

pub fn decode_uses_config_when_fields_missing_test() {
  let base = allowlist(["telegram:1"], ["telegram:2"])
  let assert Ok(persisted) =
    pure.decode_state(base, "{\"admins\":[\"telegram:9\"]}")

  persisted.added.admins |> should.equal(["telegram:9"])
  persisted.removed.admins |> should.equal([])

  let restored = pure.apply_persisted(base, persisted)
  restored.admins |> should.equal(["telegram:1", "telegram:9"])
  restored.members |> should.equal(["telegram:2"])
  restored.allowed_chats |> should.equal([])
}

pub fn decode_invalid_json_fails_test() {
  pure.decode_state(allowlist([], []), "not json")
  |> should.be_error()
}

fn should_contain(text: String, needle: String) -> Nil {
  case string.contains(text, needle) {
    True -> Nil
    False -> panic as "missing expected content"
  }
}

fn should_not_contain(text: String, needle: String) -> Nil {
  case string.contains(text, needle) {
    False -> Nil
    True -> panic as "unexpected content"
  }
}
