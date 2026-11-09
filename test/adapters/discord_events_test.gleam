//// Tests for Discord Event Handling Module

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/adapters/discord_events as events

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Event Filter Tests
// ============================================================================

pub fn new_filter_matches_all_events_test() {
  let filter = events.new_filter()
  let event = events.EventUnknown("TEST", "{}")

  events.matches_filter(event, filter)
  |> should.equal(True)
}

pub fn filter_by_guild_matches_correct_guild_test() {
  let filter =
    events.new_filter()
    |> events.filter_by_guild("123456789")

  let msg =
    events.Message(
      id: "1",
      channel_id: "1",
      guild_id: Some("123456789"),
      author: events.User(
        id: "1",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )

  let event = events.EventMessageCreate(msg)

  events.matches_filter(event, filter)
  |> should.equal(True)
}

pub fn filter_by_guild_rejects_wrong_guild_test() {
  let filter =
    events.new_filter()
    |> events.filter_by_guild("123456789")

  let msg =
    events.Message(
      id: "1",
      channel_id: "1",
      guild_id: Some("987654321"),
      author: events.User(
        id: "1",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )

  let event = events.EventMessageCreate(msg)

  events.matches_filter(event, filter)
  |> should.equal(False)
}

pub fn filter_by_channel_matches_correct_channel_test() {
  let filter =
    events.new_filter()
    |> events.filter_by_channel("111222333")

  let msg =
    events.Message(
      id: "1",
      channel_id: "111222333",
      guild_id: None,
      author: events.User(
        id: "1",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )

  let event = events.EventMessageCreate(msg)

  events.matches_filter(event, filter)
  |> should.equal(True)
}

pub fn filter_by_user_matches_author_test() {
  let filter =
    events.new_filter()
    |> events.filter_by_user("user123")

  let msg =
    events.Message(
      id: "1",
      channel_id: "1",
      guild_id: None,
      author: events.User(
        id: "user123",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )

  let event = events.EventMessageCreate(msg)

  events.matches_filter(event, filter)
  |> should.equal(True)
}

pub fn filter_by_event_types_matches_test() {
  let filter =
    events.new_filter()
    |> events.filter_by_event_types(["MESSAGE_CREATE", "MESSAGE_UPDATE"])

  let msg =
    events.Message(
      id: "1",
      channel_id: "1",
      guild_id: None,
      author: events.User(
        id: "1",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )

  let event = events.EventMessageCreate(msg)

  events.matches_filter(event, filter)
  |> should.equal(True)
}

pub fn filter_by_event_types_rejects_test() {
  let filter =
    events.new_filter()
    |> events.filter_by_event_types(["MESSAGE_DELETE"])

  let msg =
    events.Message(
      id: "1",
      channel_id: "1",
      guild_id: None,
      author: events.User(
        id: "1",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )

  let event = events.EventMessageCreate(msg)

  events.matches_filter(event, filter)
  |> should.equal(False)
}

pub fn combined_filter_all_must_match_test() {
  let filter =
    events.new_filter()
    |> events.filter_by_guild("guild1")
    |> events.filter_by_channel("channel1")

  let msg =
    events.Message(
      id: "1",
      channel_id: "channel1",
      guild_id: Some("guild1"),
      author: events.User(
        id: "1",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )

  let event = events.EventMessageCreate(msg)

  events.matches_filter(event, filter)
  |> should.equal(True)
}

// ============================================================================
// Event Type Name Tests
// ============================================================================

pub fn event_to_type_name_message_create_test() {
  let msg =
    events.Message(
      id: "1",
      channel_id: "1",
      guild_id: None,
      author: events.User(
        id: "1",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )

  events.event_to_type_name(events.EventMessageCreate(msg))
  |> should.equal("MESSAGE_CREATE")
}

pub fn event_to_type_name_message_update_test() {
  let event =
    events.EventMessageUpdate(
      id: "1",
      channel_id: "1",
      guild_id: None,
      content: Some("Updated"),
      edited_timestamp: Some("2024-01-01T00:01:00Z"),
      author: None,
    )

  events.event_to_type_name(event)
  |> should.equal("MESSAGE_UPDATE")
}

pub fn event_to_type_name_message_delete_test() {
  let event =
    events.EventMessageDelete(id: "1", channel_id: "1", guild_id: None)

  events.event_to_type_name(event)
  |> should.equal("MESSAGE_DELETE")
}

pub fn event_to_type_name_interaction_create_test() {
  let inter =
    events.Interaction(
      id: "1",
      application_id: "app1",
      interaction_type: events.ApplicationCommand,
      data: None,
      guild_id: None,
      channel_id: None,
      member: None,
      user: None,
      token: "token123",
      version: 1,
      app_permissions: None,
      locale: None,
      guild_locale: None,
    )

  events.event_to_type_name(events.EventInteractionCreate(inter))
  |> should.equal("INTERACTION_CREATE")
}

pub fn event_to_type_name_reaction_add_test() {
  let event =
    events.EventReactionAdd(
      user_id: "user1",
      channel_id: "ch1",
      message_id: "msg1",
      guild_id: None,
      emoji: events.Emoji(id: None, name: Some("👍"), animated: None),
      member: None,
    )

  events.event_to_type_name(event)
  |> should.equal("MESSAGE_REACTION_ADD")
}

pub fn event_to_type_name_reaction_remove_test() {
  let event =
    events.EventReactionRemove(
      user_id: "user1",
      channel_id: "ch1",
      message_id: "msg1",
      guild_id: None,
      emoji: events.Emoji(id: None, name: Some("👍"), animated: None),
    )

  events.event_to_type_name(event)
  |> should.equal("MESSAGE_REACTION_REMOVE")
}

pub fn event_to_type_name_unknown_test() {
  let event = events.EventUnknown("CUSTOM_EVENT", "{}")

  events.event_to_type_name(event)
  |> should.equal("CUSTOM_EVENT")
}

// ============================================================================
// Event Parsing Tests
// ============================================================================

pub fn parse_event_message_create_test() {
  let raw =
    "{\"id\":\"123456789\",\"channel_id\":\"987654321\",\"guild_id\":\"111222333\",\"content\":\"Hello World\",\"timestamp\":\"2024-01-01T00:00:00Z\",\"author\":{\"id\":\"555666777\",\"username\":\"testuser\",\"discriminator\":\"1234\",\"bot\":false},\"tts\":false,\"mention_everyone\":false,\"pinned\":false}"

  let event = events.parse_event("MESSAGE_CREATE", raw)

  case event {
    events.EventMessageCreate(msg) -> {
      msg.id |> should.equal("123456789")
      msg.channel_id |> should.equal("987654321")
      msg.guild_id |> should.equal(Some("111222333"))
      msg.content |> should.equal("Hello World")
      msg.author.id |> should.equal("555666777")
      msg.author.username |> should.equal("testuser")
    }
    _ -> panic as "Expected EventMessageCreate"
  }
}

pub fn parse_event_message_create_without_guild_test() {
  let raw =
    "{\"id\":\"123\",\"channel_id\":\"456\",\"content\":\"DM message\",\"timestamp\":\"2024-01-01T00:00:00Z\",\"author\":{\"id\":\"789\",\"username\":\"dmuser\",\"discriminator\":\"0000\"},\"tts\":false}"

  let event = events.parse_event("MESSAGE_CREATE", raw)

  case event {
    events.EventMessageCreate(msg) -> {
      msg.guild_id |> should.equal(None)
    }
    _ -> panic as "Expected EventMessageCreate"
  }
}

pub fn parse_event_message_update_test() {
  let raw =
    "{\"id\":\"123\",\"channel_id\":\"456\",\"guild_id\":\"789\",\"content\":\"Updated content\",\"edited_timestamp\":\"2024-01-01T00:01:00Z\"}"

  let event = events.parse_event("MESSAGE_UPDATE", raw)

  case event {
    events.EventMessageUpdate(id, channel_id, guild_id, content, edited_ts, _) -> {
      id |> should.equal("123")
      channel_id |> should.equal("456")
      guild_id |> should.equal(Some("789"))
      content |> should.equal(Some("Updated content"))
      edited_ts |> should.equal(Some("2024-01-01T00:01:00Z"))
    }
    _ -> panic as "Expected EventMessageUpdate"
  }
}

pub fn parse_event_message_delete_test() {
  let raw = "{\"id\":\"123\",\"channel_id\":\"456\",\"guild_id\":\"789\"}"

  let event = events.parse_event("MESSAGE_DELETE", raw)

  case event {
    events.EventMessageDelete(id, channel_id, guild_id) -> {
      id |> should.equal("123")
      channel_id |> should.equal("456")
      guild_id |> should.equal(Some("789"))
    }
    _ -> panic as "Expected EventMessageDelete"
  }
}

pub fn parse_event_interaction_create_test() {
  let raw =
    "{\"id\":\"111\",\"application_id\":\"222\",\"type\":2,\"token\":\"token123\",\"version\":1,\"guild_id\":\"333\",\"channel_id\":\"444\",\"data\":{\"id\":\"555\",\"name\":\"ping\",\"type\":1}}"

  let event = events.parse_event("INTERACTION_CREATE", raw)

  case event {
    events.EventInteractionCreate(inter) -> {
      inter.id |> should.equal("111")
      inter.application_id |> should.equal("222")
      inter.interaction_type |> should.equal(events.ApplicationCommand)
      inter.token |> should.equal("token123")
      inter.guild_id |> should.equal(Some("333"))
      inter.channel_id |> should.equal(Some("444"))
      case inter.data {
        Some(events.ApplicationCommandData(
          id,
          name,
          command_type,
          options,
          _,
          _,
        )) -> {
          id |> should.equal("555")
          name |> should.equal("ping")
          command_type |> should.equal(events.ChatInput)
          options |> should.equal([])
        }
        _ -> panic as "Expected ApplicationCommandData"
      }
    }
    _ -> panic as "Expected EventInteractionCreate"
  }
}

pub fn parse_event_interaction_create_message_component_test() {
  let raw =
    "{\"id\":\"111\",\"application_id\":\"222\",\"type\":3,\"token\":\"token123\",\"version\":1,\"data\":{\"custom_id\":\"button1\",\"component_type\":2}}"

  let event = events.parse_event("INTERACTION_CREATE", raw)

  case event {
    events.EventInteractionCreate(inter) -> {
      inter.interaction_type |> should.equal(events.MessageComponent)
      case inter.data {
        Some(events.MessageComponentData(custom_id, component_type, values, _)) -> {
          custom_id |> should.equal("button1")
          component_type |> should.equal(events.ButtonType)
          values |> should.equal(None)
        }
        _ -> panic as "Expected MessageComponentData"
      }
    }
    _ -> panic as "Expected EventInteractionCreate"
  }
}

pub fn parse_event_reaction_add_test() {
  let raw =
    "{\"user_id\":\"123\",\"channel_id\":\"456\",\"message_id\":\"789\",\"guild_id\":\"111\",\"emoji\":{\"id\":null,\"name\":\"👍\"}}"

  let event = events.parse_event("MESSAGE_REACTION_ADD", raw)

  case event {
    events.EventReactionAdd(user_id, channel_id, message_id, guild_id, emoji, _) -> {
      user_id |> should.equal("123")
      channel_id |> should.equal("456")
      message_id |> should.equal("789")
      guild_id |> should.equal(Some("111"))
      emoji.name |> should.equal(Some("👍"))
    }
    _ -> panic as "Expected EventReactionAdd"
  }
}

pub fn parse_event_reaction_remove_test() {
  let raw =
    "{\"user_id\":\"123\",\"channel_id\":\"456\",\"message_id\":\"789\",\"emoji\":{\"id\":\"custom_emoji_id\",\"name\":\"custom_emoji\"}}"

  let event = events.parse_event("MESSAGE_REACTION_REMOVE", raw)

  case event {
    events.EventReactionRemove(user_id, channel_id, message_id, guild_id, emoji) -> {
      user_id |> should.equal("123")
      channel_id |> should.equal("456")
      message_id |> should.equal("789")
      guild_id |> should.equal(None)
      emoji.id |> should.equal(Some("custom_emoji_id"))
      emoji.name |> should.equal(Some("custom_emoji"))
    }
    _ -> panic as "Expected EventReactionRemove"
  }
}

pub fn parse_event_unknown_returns_unknown_event_test() {
  let raw = "{\"some\":\"data\"}"

  let event = events.parse_event("UNKNOWN_EVENT", raw)

  case event {
    events.EventUnknown(name, data) -> {
      name |> should.equal("UNKNOWN_EVENT")
      data |> should.equal(raw)
    }
    _ -> panic as "Expected EventUnknown"
  }
}

// ============================================================================
// Event Dispatcher Tests
// ============================================================================

pub fn start_dispatcher_test() {
  let result = events.start_dispatcher()

  case result {
    Ok(dispatcher) -> {
      events.stop_dispatcher(dispatcher)
    }
    Error(_) -> panic as "Failed to start dispatcher"
  }
}

pub fn register_handler_test() {
  let assert Ok(dispatcher) = events.start_dispatcher()

  let handler_id = events.register_handler(dispatcher, fn(_event) { Nil })

  should.be_true(handler_id > 0)

  events.stop_dispatcher(dispatcher)
}

pub fn register_handler_with_filter_test() {
  let assert Ok(dispatcher) = events.start_dispatcher()

  let filter =
    events.new_filter()
    |> events.filter_by_channel("test_channel")

  let handler_id =
    events.register_handler_with_filter(dispatcher, fn(_event) { Nil }, filter)

  should.be_true(handler_id > 0)

  events.stop_dispatcher(dispatcher)
}

pub fn unregister_handler_test() {
  let assert Ok(dispatcher) = events.start_dispatcher()

  let handler_id = events.register_handler(dispatcher, fn(_event) { Nil })

  let result = events.unregister_handler(dispatcher, handler_id)
  result |> should.equal(True)

  // Unregistering again should return False
  let result2 = events.unregister_handler(dispatcher, handler_id)
  result2 |> should.equal(False)

  events.stop_dispatcher(dispatcher)
}

pub fn handler_count_test() {
  let assert Ok(dispatcher) = events.start_dispatcher()

  events.handler_count(dispatcher) |> should.equal(0)

  let _ = events.register_handler(dispatcher, fn(_event) { Nil })
  events.handler_count(dispatcher) |> should.equal(1)

  let _ = events.register_handler(dispatcher, fn(_event) { Nil })
  events.handler_count(dispatcher) |> should.equal(2)

  events.stop_dispatcher(dispatcher)
}

pub fn dispatch_calls_handlers_test() {
  let assert Ok(dispatcher) = events.start_dispatcher()

  let subject = process.new_subject()

  let _ =
    events.register_handler(dispatcher, fn(event) {
      process.send(subject, event)
    })

  let event = events.EventUnknown("TEST", "{}")
  events.dispatch(dispatcher, event)

  // Wait for the async dispatch
  let received = process.receive(subject, 1000)

  case received {
    Ok(events.EventUnknown("TEST", "{}")) -> Nil
    _ -> panic as "Expected to receive dispatched event"
  }

  events.stop_dispatcher(dispatcher)
}

pub fn dispatch_respects_filter_test() {
  let assert Ok(dispatcher) = events.start_dispatcher()

  let subject = process.new_subject()

  let filter =
    events.new_filter()
    |> events.filter_by_channel("target_channel")

  let _ =
    events.register_handler_with_filter(
      dispatcher,
      fn(event) { process.send(subject, event) },
      filter,
    )

  // Dispatch event that matches filter
  let matching_msg =
    events.Message(
      id: "1",
      channel_id: "target_channel",
      guild_id: None,
      author: events.User(
        id: "1",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )
  let matching_event = events.EventMessageCreate(matching_msg)
  events.dispatch(dispatcher, matching_event)

  // Should receive
  let received = process.receive(subject, 500)
  let _ = case received {
    Ok(_) -> Nil
    Error(_) -> panic as "Should have received matching event"
  }

  // Dispatch event that doesn't match filter
  let non_matching_msg =
    events.Message(
      id: "2",
      channel_id: "other_channel",
      guild_id: None,
      author: events.User(
        id: "1",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )
  let non_matching_event = events.EventMessageCreate(non_matching_msg)
  events.dispatch(dispatcher, non_matching_event)

  // Should not receive
  let not_received = process.receive(subject, 200)
  not_received |> should.equal(Error(Nil))

  events.stop_dispatcher(dispatcher)
}

pub fn set_logging_test() {
  let assert Ok(dispatcher) = events.start_dispatcher()

  // Enable logging
  events.set_logging(dispatcher, True)

  // Dispatch event (should be logged)
  let event = events.EventUnknown("TEST", "{}")
  events.dispatch(dispatcher, event)

  // Disable logging
  events.set_logging(dispatcher, False)

  events.stop_dispatcher(dispatcher)
}

// ============================================================================
// Event Classification Tests
// ============================================================================

pub fn is_message_event_test() {
  let msg =
    events.Message(
      id: "1",
      channel_id: "1",
      guild_id: None,
      author: events.User(
        id: "1",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )

  events.is_message_event(events.EventMessageCreate(msg))
  |> should.equal(True)

  events.is_message_event(events.EventMessageUpdate(
    "1",
    "1",
    None,
    None,
    None,
    None,
  ))
  |> should.equal(True)

  events.is_message_event(events.EventMessageDelete("1", "1", None))
  |> should.equal(True)

  events.is_message_event(events.EventUnknown("TEST", "{}"))
  |> should.equal(False)
}

pub fn is_interaction_event_test() {
  let inter =
    events.Interaction(
      id: "1",
      application_id: "1",
      interaction_type: events.ApplicationCommand,
      data: None,
      guild_id: None,
      channel_id: None,
      member: None,
      user: None,
      token: "token",
      version: 1,
      app_permissions: None,
      locale: None,
      guild_locale: None,
    )

  events.is_interaction_event(events.EventInteractionCreate(inter))
  |> should.equal(True)

  events.is_interaction_event(events.EventUnknown("TEST", "{}"))
  |> should.equal(False)
}

pub fn is_reaction_event_test() {
  let add_event =
    events.EventReactionAdd(
      user_id: "1",
      channel_id: "1",
      message_id: "1",
      guild_id: None,
      emoji: events.Emoji(id: None, name: Some("👍"), animated: None),
      member: None,
    )

  let remove_event =
    events.EventReactionRemove(
      user_id: "1",
      channel_id: "1",
      message_id: "1",
      guild_id: None,
      emoji: events.Emoji(id: None, name: Some("👍"), animated: None),
    )

  events.is_reaction_event(add_event) |> should.equal(True)
  events.is_reaction_event(remove_event) |> should.equal(True)
  events.is_reaction_event(events.EventUnknown("TEST", "{}"))
  |> should.equal(False)
}

// ============================================================================
// Get Message/Interaction Tests
// ============================================================================

pub fn get_message_from_event_test() {
  let msg =
    events.Message(
      id: "1",
      channel_id: "1",
      guild_id: None,
      author: events.User(
        id: "1",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )

  let event = events.EventMessageCreate(msg)

  case events.get_message(event) {
    Some(m) -> m.id |> should.equal("1")
    None -> panic as "Expected Some message"
  }
}

pub fn get_message_returns_none_for_other_events_test() {
  let event = events.EventUnknown("TEST", "{}")

  events.get_message(event)
  |> should.equal(None)
}

pub fn get_interaction_from_event_test() {
  let inter =
    events.Interaction(
      id: "inter1",
      application_id: "app1",
      interaction_type: events.ApplicationCommand,
      data: None,
      guild_id: None,
      channel_id: None,
      member: None,
      user: None,
      token: "token",
      version: 1,
      app_permissions: None,
      locale: None,
      guild_locale: None,
    )

  let event = events.EventInteractionCreate(inter)

  case events.get_interaction(event) {
    Some(i) -> i.id |> should.equal("inter1")
    None -> panic as "Expected Some interaction"
  }
}

pub fn get_interaction_returns_none_for_other_events_test() {
  let event = events.EventUnknown("TEST", "{}")

  events.get_interaction(event)
  |> should.equal(None)
}

// ============================================================================
// Interaction Type to String Tests
// ============================================================================

pub fn interaction_type_to_string_test() {
  events.interaction_type_to_string(events.Ping)
  |> should.equal("Ping")

  events.interaction_type_to_string(events.ApplicationCommand)
  |> should.equal("ApplicationCommand")

  events.interaction_type_to_string(events.MessageComponent)
  |> should.equal("MessageComponent")

  events.interaction_type_to_string(events.ApplicationCommandAutocomplete)
  |> should.equal("ApplicationCommandAutocomplete")

  events.interaction_type_to_string(events.ModalSubmit)
  |> should.equal("ModalSubmit")

  events.interaction_type_to_string(events.UnknownInteractionType(99))
  |> should.equal("Unknown(99)")
}

// ============================================================================
// Format Event for Log Tests
// ============================================================================

pub fn format_event_for_log_message_create_test() {
  let msg =
    events.Message(
      id: "msg123",
      channel_id: "ch456",
      guild_id: Some("guild789"),
      author: events.User(
        id: "user111",
        username: "test",
        discriminator: "0000",
        bot: None,
        avatar: None,
      ),
      member: None,
      content: "Hello",
      timestamp: "2024-01-01T00:00:00Z",
      edited_timestamp: None,
      tts: False,
      mention_everyone: False,
      mentions: [],
      mention_roles: [],
      attachments: [],
      embeds: [],
      reactions: [],
      pinned: False,
      webhook_id: None,
      message_reference: None,
      flags: None,
    )

  let log = events.format_event_for_log(events.EventMessageCreate(msg))

  string.contains(log, "MESSAGE_CREATE") |> should.equal(True)
  string.contains(log, "msg123") |> should.equal(True)
  string.contains(log, "ch456") |> should.equal(True)
  string.contains(log, "user111") |> should.equal(True)
}

pub fn format_event_for_log_message_delete_test() {
  let event =
    events.EventMessageDelete(id: "del123", channel_id: "ch456", guild_id: None)

  let log = events.format_event_for_log(event)

  string.contains(log, "MESSAGE_DELETE") |> should.equal(True)
  string.contains(log, "del123") |> should.equal(True)
  string.contains(log, "ch456") |> should.equal(True)
}

pub fn format_event_for_log_interaction_test() {
  let inter =
    events.Interaction(
      id: "inter123",
      application_id: "app1",
      interaction_type: events.ApplicationCommand,
      data: None,
      guild_id: Some("guild1"),
      channel_id: None,
      member: None,
      user: None,
      token: "token",
      version: 1,
      app_permissions: None,
      locale: None,
      guild_locale: None,
    )

  let log = events.format_event_for_log(events.EventInteractionCreate(inter))

  string.contains(log, "INTERACTION_CREATE") |> should.equal(True)
  string.contains(log, "inter123") |> should.equal(True)
  string.contains(log, "ApplicationCommand") |> should.equal(True)
}

pub fn parse_event_message_create_with_mentions_reference_and_member_test() {
  let raw =
    "{\"id\":\"m-1\",\"channel_id\":\"c-1\",\"guild_id\":\"g-1\",\"content\":\"Hello\",\"timestamp\":\"2024-01-01T00:00:00Z\",\"author\":{\"id\":\"u-1\",\"username\":\"author\",\"discriminator\":\"1234\",\"bot\":false},\"member\":{\"user\":{\"id\":\"u-1\",\"username\":\"author\",\"discriminator\":\"1234\",\"bot\":false},\"nick\":\"Author Nick\",\"roles\":[\"r-1\",\"r-2\"],\"joined_at\":\"2024-01-01T00:00:00Z\"},\"mentions\":[{\"id\":\"u-2\",\"username\":\"mentioned\",\"discriminator\":\"4321\",\"bot\":false}],\"mention_roles\":[\"r-9\"],\"message_reference\":{\"message_id\":\"m-parent\",\"channel_id\":\"c-parent\",\"guild_id\":\"g-parent\"},\"tts\":true,\"mention_everyone\":true,\"pinned\":true,\"webhook_id\":\"wh-1\",\"flags\":64}"

  let event = events.parse_event("MESSAGE_CREATE", raw)

  case event {
    events.EventMessageCreate(msg) -> {
      msg.mentions |> should.equal([
        events.User(
          id: "u-2",
          username: "mentioned",
          discriminator: "4321",
          bot: Some(False),
          avatar: None,
        ),
      ])
      msg.mention_roles |> should.equal(["r-9"])
      msg.tts |> should.equal(True)
      msg.mention_everyone |> should.equal(True)
      msg.pinned |> should.equal(True)
      msg.webhook_id |> should.equal(Some("wh-1"))
      msg.flags |> should.equal(Some(64))

      case msg.member {
        Some(member) -> {
          member.nick |> should.equal(Some("Author Nick"))
          member.roles |> should.equal(["r-1", "r-2"])
          member.joined_at |> should.equal(Some("2024-01-01T00:00:00Z"))
        }
        None -> panic as "Expected member to be parsed"
      }

      case msg.message_reference {
        Some(reference) -> {
          reference.message_id |> should.equal(Some("m-parent"))
          reference.channel_id |> should.equal(Some("c-parent"))
          reference.guild_id |> should.equal(Some("g-parent"))
        }
        None -> panic as "Expected message reference to be parsed"
      }
    }
    _ -> panic as "Expected EventMessageCreate"
  }
}

pub fn parse_event_message_create_invalid_payload_returns_unknown_test() {
  let raw = "{\"id\":\"m-1\",\"channel_id\":\"c-1\",\"author\":{\"id\":\"u-1\"}}"

  case events.parse_event("MESSAGE_CREATE", raw) {
    events.EventUnknown("MESSAGE_CREATE", _) -> Nil
    _ -> panic as "Expected EventUnknown for invalid message payload"
  }
}

pub fn parse_event_interaction_create_with_command_options_test() {
  let raw =
    "{\"id\":\"i-1\",\"application_id\":\"app-1\",\"type\":2,\"token\":\"tok\",\"version\":1,\"data\":{\"id\":\"cmd-1\",\"name\":\"config\",\"type\":1,\"options\":[{\"name\":\"text\",\"type\":3,\"value\":\"hello\"},{\"name\":\"count\",\"type\":4,\"value\":7},{\"name\":\"verbose\",\"type\":5,\"value\":true},{\"name\":\"user\",\"type\":6,\"value\":\"u-1\"},{\"name\":\"channel\",\"type\":7,\"value\":\"c-1\"},{\"name\":\"role\",\"type\":8,\"value\":\"r-1\"},{\"name\":\"unknown_opt\",\"type\":42,\"value\":\"ignored\"}]}}"

  case events.parse_event("INTERACTION_CREATE", raw) {
    events.EventInteractionCreate(interaction) -> {
      interaction.interaction_type |> should.equal(events.ApplicationCommand)

      case interaction.data {
        Some(events.ApplicationCommandData(
          id: "cmd-1",
          name: "config",
          command_type: events.ChatInput,
          options: options,
          resolved: _,
          target_id: _,
        )) -> {
          case options {
            [first, second, third, fourth, fifth, sixth, seventh] -> {
              first.value |> should.equal(Some(events.StringValue("hello")))
              second.value |> should.equal(Some(events.IntValue(7)))
              third.value |> should.equal(Some(events.BoolValue(True)))
              fourth.value |> should.equal(Some(events.UserValue("u-1")))
              fifth.value |> should.equal(Some(events.ChannelValue("c-1")))
              sixth.value |> should.equal(Some(events.RoleValue("r-1")))
              seventh.option_type |> should.equal(events.UnknownOptionType(42))
              seventh.value |> should.equal(None)
            }
            _ -> panic as "Expected seven command options"
          }
        }
        _ -> panic as "Expected ApplicationCommandData"
      }
    }
    _ -> panic as "Expected EventInteractionCreate"
  }
}

pub fn parse_event_interaction_create_message_component_values_test() {
  let raw =
    "{\"id\":\"i-2\",\"application_id\":\"app-1\",\"type\":3,\"token\":\"tok\",\"version\":1,\"data\":{\"custom_id\":\"picker_model_select\",\"component_type\":3,\"values\":[\"openai|gpt-5\",\"anthropic|claude\"]}}"

  case events.parse_event("INTERACTION_CREATE", raw) {
    events.EventInteractionCreate(interaction) -> {
      interaction.interaction_type |> should.equal(events.MessageComponent)
      case interaction.data {
        Some(events.MessageComponentData(
          custom_id: "picker_model_select",
          component_type: events.StringSelectType,
          values: Some(values),
          resolved: _,
        )) ->
          values |> should.equal(["openai|gpt-5", "anthropic|claude"])
        _ -> panic as "Expected MessageComponentData with parsed values"
      }
    }
    _ -> panic as "Expected EventInteractionCreate"
  }
}

pub fn parse_event_interaction_create_modal_submit_test() {
  let raw =
    "{\"id\":\"i-3\",\"application_id\":\"app-1\",\"type\":5,\"token\":\"tok\",\"version\":1,\"data\":{\"custom_id\":\"feedback_modal\"}}"

  case events.parse_event("INTERACTION_CREATE", raw) {
    events.EventInteractionCreate(interaction) -> {
      interaction.interaction_type |> should.equal(events.ModalSubmit)
      case interaction.data {
        Some(events.ModalSubmitData(custom_id, components)) -> {
          custom_id |> should.equal("feedback_modal")
          components |> should.equal([])
        }
        _ -> panic as "Expected ModalSubmitData"
      }
    }
    _ -> panic as "Expected EventInteractionCreate"
  }
}

pub fn parse_event_interaction_create_unknown_type_without_data_test() {
  let raw =
    "{\"id\":\"i-4\",\"application_id\":\"app-1\",\"type\":99,\"token\":\"tok\",\"version\":1}"

  case events.parse_event("INTERACTION_CREATE", raw) {
    events.EventInteractionCreate(interaction) -> {
      interaction.interaction_type |> should.equal(events.UnknownInteractionType(99))
      interaction.data |> should.equal(None)
    }
    _ -> panic as "Expected EventInteractionCreate"
  }
}

pub fn matches_filter_interaction_user_comes_from_member_user_test() {
  let filter =
    events.new_filter()
    |> events.filter_by_user("member-user")

  let interaction =
    events.Interaction(
      id: "i-member",
      application_id: "app",
      interaction_type: events.ApplicationCommand,
      data: None,
      guild_id: Some("g-1"),
      channel_id: Some("c-1"),
      member: Some(events.Member(
        user: Some(events.User(
          id: "member-user",
          username: "member",
          discriminator: "0001",
          bot: Some(False),
          avatar: None,
        )),
        nick: None,
        roles: [],
        joined_at: None,
      )),
      user: None,
      token: "token",
      version: 1,
      app_permissions: None,
      locale: None,
      guild_locale: None,
    )

  events.matches_filter(events.EventInteractionCreate(interaction), filter)
  |> should.equal(True)
}

pub fn parse_event_interaction_component_with_empty_values_array_test() {
  let raw =
    "{\"id\":\"i-empty-values\",\"application_id\":\"app-1\",\"type\":3,\"token\":\"tok\",\"version\":1,\"data\":{\"custom_id\":\"picker_model_select\",\"component_type\":3,\"values\":[]}}"

  case events.parse_event("INTERACTION_CREATE", raw) {
    events.EventInteractionCreate(interaction) -> {
      interaction.interaction_type |> should.equal(events.MessageComponent)
      case interaction.data {
        Some(events.MessageComponentData(
          custom_id: "picker_model_select",
          component_type: events.StringSelectType,
          values: values,
          resolved: _,
        )) -> values |> should.equal(None)
        _ -> panic as "Expected MessageComponentData with None values"
      }
    }
    _ -> panic as "Expected EventInteractionCreate"
  }
}

pub fn parse_event_interaction_autocomplete_command_test() {
  let raw =
    "{\"id\":\"i-auto\",\"application_id\":\"app-1\",\"type\":4,\"token\":\"tok\",\"version\":1,\"data\":{\"id\":\"cmd-1\",\"name\":\"search\",\"type\":1}}"

  case events.parse_event("INTERACTION_CREATE", raw) {
    events.EventInteractionCreate(interaction) -> {
      interaction.interaction_type
      |> should.equal(events.ApplicationCommandAutocomplete)
      case interaction.data {
        Some(events.ApplicationCommandData(
          id: "cmd-1",
          name: "search",
          command_type: events.ChatInput,
          options: [],
          resolved: _,
          target_id: _,
        )) -> Nil
        _ -> panic as "Expected ApplicationCommandData for autocomplete"
      }
    }
    _ -> panic as "Expected EventInteractionCreate"
  }
}

pub fn parse_event_interaction_nested_subcommand_options_test() {
  let raw =
    "{\"id\":\"i-nested\",\"application_id\":\"app-1\",\"type\":2,\"token\":\"tok\",\"version\":1,\"data\":{\"id\":\"cmd-nested\",\"name\":\"admin\",\"type\":1,\"options\":[{\"name\":\"group\",\"type\":1,\"options\":[{\"name\":\"text\",\"type\":3,\"value\":\"hello\"}]}]}}"

  case events.parse_event("INTERACTION_CREATE", raw) {
    events.EventInteractionCreate(interaction) -> {
      case interaction.data {
        Some(events.ApplicationCommandData(options: options, ..)) ->
          case options {
            [outer] -> {
              outer.option_type |> should.equal(events.SubCommand)
              outer.value |> should.equal(None)
              case outer.options {
                [inner] -> {
                  inner.option_type |> should.equal(events.StringOption)
                  inner.value |> should.equal(Some(events.StringValue("hello")))
                }
                _ -> panic as "Expected nested inner option"
              }
            }
            _ -> panic as "Expected one outer option"
          }
        _ -> panic as "Expected ApplicationCommandData"
      }
    }
    _ -> panic as "Expected EventInteractionCreate"
  }
}

pub fn parse_event_interaction_create_invalid_payload_returns_unknown_test() {
  let raw = "{\"id\":\"i-invalid\",\"application_id\":\"app-1\",\"type\":2}"

  case events.parse_event("INTERACTION_CREATE", raw) {
    events.EventUnknown("INTERACTION_CREATE", _) -> Nil
    _ -> panic as "Expected EventUnknown for invalid interaction payload"
  }
}

pub fn parse_interaction_missing_required_fields_returns_error_test() {
  events.parse_interaction("{\"id\":\"x\"}")
  |> should.equal(Error(Nil))
}

pub fn parse_event_message_update_with_author_details_test() {
  let raw =
    "{\"id\":\"m-upd\",\"channel_id\":\"c-upd\",\"guild_id\":\"g-upd\",\"content\":\"Updated\",\"edited_timestamp\":\"2024-01-01T00:01:00Z\",\"author\":{\"id\":\"u-upd\",\"username\":\"upd-user\",\"discriminator\":\"1234\",\"bot\":true}}"

  case events.parse_event("MESSAGE_UPDATE", raw) {
    events.EventMessageUpdate(id, channel_id, guild_id, content, edited_ts, author) -> {
      id |> should.equal("m-upd")
      channel_id |> should.equal("c-upd")
      guild_id |> should.equal(Some("g-upd"))
      content |> should.equal(Some("Updated"))
      edited_ts |> should.equal(Some("2024-01-01T00:01:00Z"))
      case author {
        Some(parsed) -> {
          parsed.id |> should.equal("u-upd")
          parsed.bot |> should.equal(Some(True))
        }
        None -> panic as "Expected author to be parsed"
      }
    }
    _ -> panic as "Expected EventMessageUpdate"
  }
}

pub fn format_event_for_log_unknown_event_includes_raw_data_preview_test() {
  let raw =
    "{\"field\":\"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\"}"

  let log = events.format_event_for_log(events.EventUnknown("CUSTOM", raw))
  string.contains(log, "[Discord Event] CUSTOM")
  |> should.equal(True)
  string.contains(log, "raw_data=")
  |> should.equal(True)
}
