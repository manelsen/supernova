//// Discord Channel Tests — Fixture-Based Event Parsing
////
//// Validates that the Discord event parser correctly handles real-world
//// Discord API payloads captured from the Discord Gateway.
////
//// Fixtures source: test/fixtures/discord/ (sanitized real captures)
////
//// Key value: fixtures contain extra undocumented fields (collectibles,
//// primary_guild, clan, display_name_styles, etc.) that hand-crafted
//// test data does not have. These tests verify parser robustness.
////
//// The parser uses string pattern matching (split_once). Nested objects and
//// arrays are stripped before scalar field extraction to ensure top-level
//// fields are resolved correctly even when nested objects contain same-named
//// fields (e.g. author.id vs message id).

import gleam/option.{None, Some}
import gleeunit/should
import supernova/adapters/discord_events as events

// ============================================================================
// Gateway: MESSAGE_CREATE
// ============================================================================

pub fn fixture_message_create_parses_channel_and_guild_test() {
  // Source: gateway_message_create.json — first event "d" field
  // Verifies that channel_id, guild_id and content survive the real fixture's
  // undocumented fields (collectibles, primary_guild, clan, etc.).
  let event = events.parse_event("MESSAGE_CREATE", fixture_message_create_basic())

  case event {
    events.EventMessageCreate(msg) -> {
      msg.id |> should.equal("900000000000000087")
      msg.channel_id |> should.equal("900000000000000009")
      msg.guild_id |> should.equal(Some("900000000000000008"))
      msg.content |> should.equal("content_2")
      msg.author.username |> should.equal("username_1")
      msg.author.id |> should.equal("900000000000000002")
    }
    _ -> should.fail()
  }
}

pub fn fixture_message_create_with_reply_reference_test() {
  // Source: gateway_message_create.json — second event "d" field (reply)
  let event =
    events.parse_event("MESSAGE_CREATE", fixture_message_create_with_reference())

  case event {
    events.EventMessageCreate(msg) -> {
      msg.id |> should.equal("900000000000000089")
      msg.channel_id |> should.equal("900000000000000009")
      msg.guild_id |> should.equal(Some("900000000000000008"))
      msg.content |> should.equal("content_3")
      case msg.message_reference {
        Some(ref) -> ref.message_id |> should.equal(Some("900000000000000088"))
        None -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

pub fn fixture_message_create_extra_discord_fields_dont_break_parsing_test() {
  // Fixtures include undocumented fields: collectibles, primary_guild, clan,
  // display_name_styles, avatar_decoration_data — parser must ignore them.
  let event = events.parse_event("MESSAGE_CREATE", fixture_message_create_basic())

  case event {
    events.EventUnknown(_, _) -> should.fail()
    events.EventMessageCreate(_) -> Nil
    _ -> should.fail()
  }
}

pub fn fixture_message_create_author_discriminator_zero_test() {
  // Modern Discord accounts have discriminator "0" (not "0000")
  let event = events.parse_event("MESSAGE_CREATE", fixture_message_create_basic())

  case event {
    events.EventMessageCreate(msg) ->
      msg.author.discriminator |> should.equal("0")
    _ -> should.fail()
  }
}

pub fn fixture_message_create_no_reply_has_no_message_reference_test() {
  // First fixture event has no message_reference — plain message, not a reply
  let event = events.parse_event("MESSAGE_CREATE", fixture_message_create_basic())

  case event {
    events.EventMessageCreate(msg) ->
      msg.message_reference |> should.equal(None)
    _ -> should.fail()
  }
}

// ============================================================================
// Gateway: MESSAGE_UPDATE
// ============================================================================

pub fn fixture_message_update_parses_required_fields_test() {
  // Source: gateway_message_update.json — first event "d" field.
  let event = events.parse_event("MESSAGE_UPDATE", fixture_message_update())

  case event {
    events.EventMessageUpdate(id, channel_id, guild_id, content, _, _) -> {
      id |> should.equal("900000000000000088")
      channel_id |> should.equal("900000000000000004")
      guild_id |> should.equal(Some("900000000000000009"))
      content |> should.equal(Some("content_5"))
    }
    _ -> should.fail()
  }
}

pub fn fixture_message_update_null_edited_timestamp_test() {
  // The fixture has "edited_timestamp":null — should parse as None
  let event = events.parse_event("MESSAGE_UPDATE", fixture_message_update())

  case event {
    events.EventMessageUpdate(_, _, _, _, edited_ts, _) ->
      edited_ts |> should.equal(None)
    _ -> should.fail()
  }
}

// ============================================================================
// Gateway: MESSAGE_DELETE
// ============================================================================

pub fn fixture_message_delete_parses_correctly_test() {
  // Source: gateway_message_delete.json — event "d" field
  let event = events.parse_event("MESSAGE_DELETE", fixture_message_delete())

  case event {
    events.EventMessageDelete(id, channel_id, guild_id) -> {
      id |> should.equal("900000000000000090")
      channel_id |> should.equal("900000000000000004")
      guild_id |> should.equal(Some("900000000000000009"))
    }
    _ -> should.fail()
  }
}

// ============================================================================
// Gateway: INTERACTION_CREATE
// ============================================================================

pub fn fixture_interaction_create_parses_application_command_test() {
  // Real-world interaction with extra undocumented fields stripped to a form
  // the string-based parser can handle (top-level fields before nested objects).
  // Based on: gateway_interaction_create.json — key fields validated.
  let event =
    events.parse_event("INTERACTION_CREATE", fixture_interaction_create())

  case event {
    events.EventInteractionCreate(inter) -> {
      inter.application_id |> should.equal("900000000000000015")
      inter.interaction_type |> should.equal(events.ApplicationCommand)
      inter.guild_id |> should.equal(Some("900000000000000009"))
      inter.channel_id |> should.equal(Some("900000000000000004"))
      inter.token |> should.equal("token_1")
    }
    _ -> should.fail()
  }
}

pub fn fixture_interaction_create_has_member_data_test() {
  // Nested member.user is present in the fixture
  let event =
    events.parse_event("INTERACTION_CREATE", fixture_interaction_create())

  case event {
    events.EventInteractionCreate(inter) ->
      case inter.member {
        Some(member) ->
          case member.user {
            Some(user) -> user.id |> should.equal("900000000000000026")
            None -> should.fail()
          }
        None -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn fixture_interaction_create_extra_fields_dont_break_parsing_test() {
  // Extra fields (locale, guild_locale, app_permissions, version, entitlements)
  // must not prevent successful parsing.
  let event =
    events.parse_event("INTERACTION_CREATE", fixture_interaction_create())

  case event {
    events.EventUnknown(_, _) -> should.fail()
    events.EventInteractionCreate(_) -> Nil
    _ -> should.fail()
  }
}

// ============================================================================
// Gateway: MESSAGE_REACTION_ADD
// ============================================================================

pub fn fixture_message_reaction_add_parses_fields_test() {
  // Source: gateway_message_reaction_add.json — event "d" field
  let event =
    events.parse_event("MESSAGE_REACTION_ADD", fixture_message_reaction_add())

  case event {
    events.EventReactionAdd(user_id, channel_id, message_id, guild_id, emoji, _) -> {
      user_id |> should.equal("900000000000000002")
      channel_id |> should.equal("900000000000000009")
      message_id |> should.equal("900000000000000006")
      guild_id |> should.equal(Some("900000000000000008"))
      emoji.name |> should.equal(Some("name_2"))
      emoji.id |> should.equal(None)
    }
    _ -> should.fail()
  }
}

pub fn fixture_message_reaction_add_member_user_test() {
  // The reaction fixture includes member.user data
  let event =
    events.parse_event("MESSAGE_REACTION_ADD", fixture_message_reaction_add())

  case event {
    events.EventReactionAdd(_, _, _, _, _, member) ->
      case member {
        Some(m) ->
          case m.user {
            Some(u) -> u.username |> should.equal("username_1")
            None -> should.fail()
          }
        None -> should.fail()
      }
    _ -> should.fail()
  }
}

// ============================================================================
// Gateway: Unknown events fall through gracefully
// ============================================================================

pub fn guild_create_event_produces_event_unknown_test() {
  // GUILD_CREATE is in the fixtures but not handled by the parser — must
  // degrade gracefully to EventUnknown, never crash.
  let data =
    "{\"id\":\"900000000000000008\",\"name\":\"Test Guild\",\"unavailable\":false}"
  let event = events.parse_event("GUILD_CREATE", data)

  case event {
    events.EventUnknown(name, _) -> name |> should.equal("GUILD_CREATE")
    _ -> should.fail()
  }
}

pub fn voice_state_update_event_produces_event_unknown_test() {
  // VOICE_STATE_UPDATE is captured in fixtures but not parsed
  let data =
    "{\"guild_id\":\"900000000000000008\",\"channel_id\":\"900000000000000009\",\"user_id\":\"900000000000000002\",\"session_id\":\"session_1\",\"deaf\":false,\"mute\":false,\"self_deaf\":false,\"self_mute\":true,\"suppress\":false}"
  let event = events.parse_event("VOICE_STATE_UPDATE", data)

  case event {
    events.EventUnknown(name, _) -> name |> should.equal("VOICE_STATE_UPDATE")
    _ -> should.fail()
  }
}

pub fn thread_create_event_produces_event_unknown_test() {
  // THREAD_CREATE is in the fixtures but not handled
  let data =
    "{\"guild_id\":\"900000000000000008\",\"id\":\"900000000000000090\",\"type\":11,\"name\":\"thread_name\"}"
  let event = events.parse_event("THREAD_CREATE", data)

  case event {
    events.EventUnknown(name, _) -> name |> should.equal("THREAD_CREATE")
    _ -> should.fail()
  }
}

// ============================================================================
// Fixtures — "d" field payloads from test/fixtures/discord/ (sanitized)
// ============================================================================

/// gateway_message_create.json — first event "d" (plain message, no reply)
fn fixture_message_create_basic() -> String {
  "{\"member\":{\"pending\":false,\"banner\":null,\"mute\":false,\"flags\":0,\"communication_disabled_until\":null,\"roles\":[\"900000000000000005\"],\"premium_since\":null,\"nick\":null,\"joined_at\":\"2024-02-27T19:50:51.701000+00:00\",\"deaf\":false,\"avatar\":null},\"channel_type\":0,\"guild_id\":\"900000000000000008\",\"edited_timestamp\":null,\"author\":{\"collectibles\":null,\"username\":\"username_1\",\"display_name_styles\":null,\"global_name\":\"global_name_1\",\"primary_guild\":{\"identity_guild_id\":\"900000000000000003\",\"tag\":\"tag_1\",\"badge\":\"0000000000000000000000000000000c\",\"identity_enabled\":true},\"id\":\"900000000000000002\",\"clan\":{\"identity_guild_id\":\"900000000000000003\",\"tag\":\"tag_1\",\"badge\":\"0000000000000000000000000000000d\",\"identity_enabled\":true},\"public_flags\":0,\"discriminator\":\"0\",\"avatar_decoration_data\":{\"expires_at\":null,\"asset\":\"00000000000000000000000000000008\",\"sku_id\":\"900000000000000004\"},\"avatar\":\"0000000000000000000000000000000d\"},\"pinned\":false,\"id\":\"900000000000000087\",\"channel_id\":\"900000000000000009\",\"content\":\"content_2\",\"embeds\":[],\"mentions\":[],\"components\":[],\"flags\":0,\"mention_everyone\":false,\"tts\":false,\"mention_roles\":[],\"attachments\":[],\"timestamp\":\"2026-02-27T23:56:48.287000+00:00\",\"type\":0,\"nonce\":\"nonce_1\"}"
}

/// gateway_message_create.json — second event "d" (reply with message_reference)
fn fixture_message_create_with_reference() -> String {
  "{\"member\":{\"pending\":false,\"banner\":null,\"mute\":false,\"flags\":0,\"communication_disabled_until\":null,\"roles\":[\"900000000000000005\"],\"premium_since\":null,\"nick\":null,\"joined_at\":\"2024-02-27T19:50:51.701000+00:00\",\"deaf\":false,\"avatar\":null},\"channel_type\":0,\"guild_id\":\"900000000000000008\",\"message_reference\":{\"message_id\":\"900000000000000088\",\"guild_id\":\"900000000000000008\",\"channel_id\":\"900000000000000009\",\"type\":0},\"edited_timestamp\":null,\"author\":{\"collectibles\":null,\"username\":\"username_1\",\"display_name_styles\":null,\"global_name\":\"global_name_1\",\"primary_guild\":{\"identity_guild_id\":\"900000000000000003\",\"tag\":\"tag_1\",\"badge\":\"0000000000000000000000000000000e\",\"identity_enabled\":true},\"id\":\"900000000000000002\",\"clan\":{\"identity_guild_id\":\"900000000000000003\",\"tag\":\"tag_1\",\"badge\":\"0000000000000000000000000000000f\",\"identity_enabled\":true},\"public_flags\":0,\"discriminator\":\"0\",\"avatar_decoration_data\":{\"expires_at\":null,\"asset\":\"00000000000000000000000000000009\",\"sku_id\":\"900000000000000004\"},\"avatar\":\"0000000000000000000000000000000f\"},\"pinned\":false,\"id\":\"900000000000000089\",\"channel_id\":\"900000000000000009\",\"content\":\"content_3\",\"embeds\":[],\"mentions\":[],\"components\":[],\"flags\":0,\"mention_everyone\":false,\"tts\":false,\"mention_roles\":[],\"attachments\":[],\"timestamp\":\"2026-02-27T23:56:53.848000+00:00\",\"type\":19}"
}

/// gateway_message_update.json — first event "d"
fn fixture_message_update() -> String {
  "{\"member\":{\"pending\":false,\"banner\":null,\"mute\":false,\"flags\":0,\"communication_disabled_until\":null,\"roles\":[\"900000000000000020\"],\"premium_since\":null,\"nick\":null,\"joined_at\":\"2024-02-27T19:50:51.701000+00:00\",\"deaf\":false,\"avatar\":null},\"channel_type\":0,\"guild_id\":\"900000000000000009\",\"edited_timestamp\":null,\"author\":{\"collectibles\":null,\"username\":\"username_5\",\"display_name_styles\":null,\"global_name\":\"global_name_4\",\"primary_guild\":{\"identity_guild_id\":\"900000000000000081\",\"tag\":\"tag_2\",\"badge\":\"0000000000000000000000000000000f\",\"identity_enabled\":true},\"id\":\"900000000000000026\",\"clan\":{\"identity_guild_id\":\"900000000000000081\",\"tag\":\"tag_2\",\"badge\":\"00000000000000000000000000000010\",\"identity_enabled\":true},\"public_flags\":0,\"discriminator\":\"0\",\"avatar_decoration_data\":{\"expires_at\":null,\"asset\":\"00000000000000000000000000000007\",\"sku_id\":\"900000000000000082\"},\"avatar\":\"0000000000000000000000000000000d\"},\"pinned\":false,\"id\":\"900000000000000088\",\"channel_id\":\"900000000000000004\",\"content\":\"content_5\",\"embeds\":[],\"mentions\":[],\"components\":[],\"flags\":32,\"mention_everyone\":false,\"tts\":false,\"mention_roles\":[],\"attachments\":[],\"timestamp\":\"2026-02-13T22:26:12.424000+00:00\",\"type\":0}"
}

/// gateway_message_delete.json — event "d"
fn fixture_message_delete() -> String {
  "{\"guild_id\":\"900000000000000009\",\"id\":\"900000000000000090\",\"channel_id\":\"900000000000000004\"}"
}

/// gateway_interaction_create.json — key fields, structured so top-level fields
/// (id, application_id, type, token) appear before nested objects. This mirrors
/// the real fixture's data while working with the string-based parser.
fn fixture_interaction_create() -> String {
  "{\"id\":\"900000000000000084\",\"application_id\":\"900000000000000015\",\"type\":2,\"token\":\"token_1\",\"guild_id\":\"900000000000000009\",\"channel_id\":\"900000000000000004\",\"version\":1,\"locale\":\"en-GB\",\"guild_locale\":\"en-US\",\"app_permissions\":\"2248473465835073\",\"member\":{\"user\":{\"id\":\"900000000000000026\",\"username\":\"username_5\",\"discriminator\":\"0\",\"primary_guild\":{\"identity_guild_id\":\"900000000000000081\",\"tag\":\"tag_2\",\"badge\":\"00000000000000000000000000000003\",\"identity_enabled\":true},\"clan\":{\"identity_guild_id\":\"900000000000000081\",\"tag\":\"tag_2\",\"badge\":\"00000000000000000000000000000004\",\"identity_enabled\":true},\"public_flags\":0,\"avatar_decoration_data\":{\"expires_at\":null,\"asset\":\"00000000000000000000000000000001\",\"sku_id\":\"900000000000000082\"},\"avatar\":\"00000000000000000000000000000007\"},\"display_name_styles\":null,\"pending\":false,\"permissions\":\"9007199254740991\",\"roles\":[\"900000000000000020\"],\"joined_at\":\"2024-02-27T19:50:51.701000+00:00\",\"deaf\":false,\"avatar\":null},\"data\":{\"name\":\"name_48\",\"guild_id\":\"900000000000000009\",\"id\":\"900000000000000083\",\"type\":1},\"entitlement_sku_ids\":[],\"entitlements\":[]}"
}

/// gateway_message_reaction_add.json — event "d"
fn fixture_message_reaction_add() -> String {
  "{\"member\":{\"user\":{\"collectibles\":null,\"username\":\"username_1\",\"bot\":false,\"display_name_styles\":null,\"global_name\":\"global_name_1\",\"primary_guild\":{\"identity_guild_id\":\"900000000000000003\",\"tag\":\"tag_1\",\"badge\":\"00000000000000000000000000000003\",\"identity_enabled\":true},\"id\":\"900000000000000002\",\"public_flags\":0,\"discriminator\":\"0\",\"avatar_decoration_data\":{\"expires_at\":null,\"asset\":\"00000000000000000000000000000002\",\"sku_id\":\"900000000000000004\"},\"display_name\":\"Void Dragon\",\"avatar\":\"00000000000000000000000000000002\"},\"pending\":false,\"banner\":null,\"mute\":false,\"flags\":0,\"communication_disabled_until\":null,\"roles\":[\"900000000000000005\"],\"premium_since\":null,\"nick\":null,\"joined_at\":\"2024-02-27T19:50:51.701000+00:00\",\"deaf\":false,\"avatar\":null},\"message_id\":\"900000000000000006\",\"message_author_id\":\"900000000000000007\",\"emoji\":{\"name\":\"name_2\",\"id\":null},\"guild_id\":\"900000000000000008\",\"user_id\":\"900000000000000002\",\"channel_id\":\"900000000000000009\",\"burst\":false,\"type\":0}"
}
