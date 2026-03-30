import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/telegram

pub fn main() -> Nil {
  Nil
}

// ============================================================================
// Configuration Tests
// ============================================================================

pub fn new_config_test() -> Nil {
  let config = telegram.new_config("test_token")
  config.token |> should.equal("test_token")
  config.polling_timeout |> should.equal(30)
  config.polling_interval |> should.equal(0)
  config.allowed_updates |> should.equal([])
}

pub fn with_polling_timeout_test() -> Nil {
  let config = telegram.new_config("test_token")
  let config = telegram.with_polling_timeout(config, 60)
  config.polling_timeout |> should.equal(60)
}

pub fn with_polling_interval_test() -> Nil {
  let config = telegram.new_config("test_token")
  let config = telegram.with_polling_interval(config, 5)
  config.polling_interval |> should.equal(5)
}

pub fn with_allowed_updates_test() -> Nil {
  let config = telegram.new_config("test_token")
  let config =
    telegram.with_allowed_updates(config, ["message", "callback_query"])
  config.allowed_updates |> should.equal(["message", "callback_query"])
}

// ============================================================================
// Chat Type Parsing Tests
// ============================================================================

pub fn parse_chat_type_private_test() -> Nil {
  let chat =
    decode_chat_from_json(
      "{\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}",
    )
  chat.chat_type |> should.equal(telegram.PrivateChat)
}

pub fn parse_chat_type_group_test() -> Nil {
  let chat =
    decode_chat_from_json(
      "{\"id\": 123, \"type\": \"group\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}",
    )
  chat.chat_type |> should.equal(telegram.GroupChat)
}

pub fn parse_chat_type_supergroup_test() -> Nil {
  let chat =
    decode_chat_from_json(
      "{\"id\": 123, \"type\": \"supergroup\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}",
    )
  chat.chat_type |> should.equal(telegram.SupergroupChat)
}

pub fn parse_chat_type_channel_test() -> Nil {
  let chat =
    decode_chat_from_json(
      "{\"id\": 123, \"type\": \"channel\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}",
    )
  chat.chat_type |> should.equal(telegram.ChannelChat)
}

// ============================================================================
// User Decoding Tests
// ============================================================================

pub fn decode_user_basic_test() -> Nil {
  let user =
    decode_user_from_json(
      "{\"id\": 123456789, \"is_bot\": false, \"first_name\": \"John\", \"last_name\": null, \"username\": null, \"language_code\": null}",
    )
  user.id |> should.equal("123456789")
  user.is_bot |> should.equal(False)
  user.first_name |> should.equal("John")
  user.last_name |> should.equal(None)
  user.username |> should.equal(None)
}

pub fn decode_user_with_all_fields_test() -> Nil {
  let user =
    decode_user_from_json(
      "{\"id\": 123, \"is_bot\": true, \"first_name\": \"Test\", \"last_name\": \"Bot\", \"username\": \"testbot\", \"language_code\": \"en\"}",
    )
  user.id |> should.equal("123")
  user.is_bot |> should.equal(True)
  user.first_name |> should.equal("Test")
  user.last_name |> should.equal(Some("Bot"))
  user.username |> should.equal(Some("testbot"))
  user.language_code |> should.equal(Some("en"))
}

// ============================================================================
// Chat Decoding Tests
// ============================================================================

pub fn decode_chat_private_test() -> Nil {
  let chat =
    decode_chat_from_json(
      "{\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": \"john\", \"first_name\": \"John\", \"last_name\": null}",
    )
  chat.id |> should.equal("123")
  chat.chat_type |> should.equal(telegram.PrivateChat)
  chat.first_name |> should.equal(Some("John"))
  chat.username |> should.equal(Some("john"))
}

pub fn decode_chat_group_test() -> Nil {
  let chat =
    decode_chat_from_json(
      "{\"id\": -100123, \"type\": \"supergroup\", \"title\": \"Test Group\", \"username\": \"testgroup\", \"first_name\": null, \"last_name\": null}",
    )
  chat.id |> should.equal("-100123")
  chat.chat_type |> should.equal(telegram.SupergroupChat)
  chat.title |> should.equal(Some("Test Group"))
  chat.username |> should.equal(Some("testgroup"))
}

// ============================================================================
// Message Decoding Tests
// ============================================================================

pub fn decode_message_basic_test() -> Nil {
  let msg =
    decode_message_from_json(
      "{\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": null, \"caption\": null, \"entities\": null, \"caption_entities\": null}",
    )
  msg.message_id |> should.equal(1)
  msg.date |> should.equal(1_609_459_200)
  msg.chat.id |> should.equal("123")
  msg.text |> should.equal(None)
}

pub fn decode_message_with_text_test() -> Nil {
  let msg =
    decode_message_from_json(
      "{\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": \"Hello World\", \"caption\": null, \"entities\": null, \"caption_entities\": null}",
    )
  msg.text |> should.equal(Some("Hello World"))
}

pub fn decode_message_with_user_test() -> Nil {
  let msg =
    decode_message_from_json(
      "{\"message_id\": 1, \"from\": {\"id\": 456, \"is_bot\": false, \"first_name\": \"John\", \"last_name\": null, \"username\": null, \"language_code\": null}, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": null, \"caption\": null, \"entities\": null, \"caption_entities\": null}",
    )
  case msg.from {
    Some(user) -> {
      user.id |> should.equal("456")
      user.first_name |> should.equal("John")
    }
    None -> should.fail()
  }
}

pub fn decode_message_with_caption_test() -> Nil {
  let msg =
    decode_message_from_json(
      "{\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": null, \"caption\": \"Photo caption\", \"entities\": null, \"caption_entities\": null}",
    )
  msg.caption |> should.equal(Some("Photo caption"))
}

// ============================================================================
// Callback Query Decoding Tests
// ============================================================================

pub fn decode_callback_query_basic_test() -> Nil {
  let cb =
    decode_callback_query_from_json(
      "{\"id\": \"cb123\", \"from\": {\"id\": 456, \"is_bot\": false, \"first_name\": \"John\", \"last_name\": null, \"username\": null, \"language_code\": null}, \"message\": null, \"inline_message_id\": null, \"chat_instance\": \"12345\", \"data\": \"button_click\", \"game_short_name\": null}",
    )
  cb.id |> should.equal("cb123")
  cb.from.id |> should.equal("456")
  cb.chat_instance |> should.equal("12345")
  cb.data |> should.equal(Some("button_click"))
}

pub fn decode_callback_query_with_message_test() -> Nil {
  let cb =
    decode_callback_query_from_json(
      "{\"id\": \"cb123\", \"from\": {\"id\": 456, \"is_bot\": false, \"first_name\": \"John\", \"last_name\": null, \"username\": null, \"language_code\": null}, \"message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": null, \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"inline_message_id\": null, \"chat_instance\": \"12345\", \"data\": \"test\", \"game_short_name\": null}",
    )
  case cb.message {
    Some(msg) -> msg.message_id |> should.equal(1)
    None -> should.fail()
  }
}

// ============================================================================
// Update Decoding Tests
// ============================================================================

pub fn decode_update_with_message_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 100, \"message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": \"Hello\", \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": null}",
    )
  update.update_id |> should.equal(100)
  case update.message {
    Some(msg) -> msg.text |> should.equal(Some("Hello"))
    None -> should.fail()
  }
}

pub fn decode_update_with_callback_query_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 101, \"message\": null, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": {\"id\": \"cb123\", \"from\": {\"id\": 456, \"is_bot\": false, \"first_name\": \"John\", \"last_name\": null, \"username\": null, \"language_code\": null}, \"message\": null, \"inline_message_id\": null, \"chat_instance\": \"12345\", \"data\": \"test\", \"game_short_name\": null}}",
    )
  update.update_id |> should.equal(101)
  case update.callback_query {
    Some(cb) -> cb.data |> should.equal(Some("test"))
    None -> should.fail()
  }
}

pub fn decode_update_with_edited_message_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 102, \"message\": null, \"edited_message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": \"Edited text\", \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": null}",
    )
  update.update_id |> should.equal(102)
  case update.edited_message {
    Some(msg) -> msg.text |> should.equal(Some("Edited text"))
    None -> should.fail()
  }
}

pub fn decode_updates_array_test() -> Nil {
  let json_str =
    "{\"ok\": true, \"result\": [{\"update_id\": 100, \"message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": \"Hello\", \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": null}]}"

  let decoder = {
    use result <- decode.field("result", decode.list(decode_update()))
    decode.success(result)
  }

  case json.parse(from: json_str, using: decoder) {
    Ok(updates) -> {
      updates |> list_length |> should.equal(1)
      case updates {
        [first] -> first.update_id |> should.equal(100)
        _ -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

// ============================================================================
// Utility Function Tests
// ============================================================================

pub fn get_message_text_from_update_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 100, \"message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": \"Hello\", \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": null}",
    )
  telegram.get_message_text(update) |> should.equal(Some("Hello"))
}

pub fn get_message_text_from_update_no_message_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 100, \"message\": null, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": null}",
    )
  telegram.get_message_text(update) |> should.equal(None)
}

pub fn get_callback_data_from_update_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 101, \"message\": null, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": {\"id\": \"cb123\", \"from\": {\"id\": 456, \"is_bot\": false, \"first_name\": \"John\", \"last_name\": null, \"username\": null, \"language_code\": null}, \"message\": null, \"inline_message_id\": null, \"chat_instance\": \"12345\", \"data\": \"test\", \"game_short_name\": null}}",
    )
  telegram.get_callback_data(update) |> should.equal(Some("test"))
}

pub fn get_chat_id_from_message_update_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 100, \"message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": \"Hello\", \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": null}",
    )
  telegram.get_chat_id(update) |> should.equal(Some("123"))
}

pub fn get_chat_id_from_callback_update_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 101, \"message\": null, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": {\"id\": \"cb123\", \"from\": {\"id\": 456, \"is_bot\": false, \"first_name\": \"John\", \"last_name\": null, \"username\": null, \"language_code\": null}, \"message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 456, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": null, \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"inline_message_id\": null, \"chat_instance\": \"12345\", \"data\": \"test\", \"game_short_name\": null}}",
    )
  telegram.get_chat_id(update) |> should.equal(Some("456"))
}

pub fn is_command_with_command_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 100, \"message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": \"/start\", \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": null}",
    )
  telegram.is_command(update) |> should.equal(True)
}

pub fn is_command_with_regular_message_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 100, \"message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": \"Hello\", \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": null}",
    )
  telegram.is_command(update) |> should.equal(False)
}

pub fn parse_command_basic_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 100, \"message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": \"/start\", \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": null}",
    )
  case telegram.parse_command(update) {
    Some(#(cmd, args)) -> {
      cmd |> should.equal("start")
      args |> should.equal([])
    }
    None -> should.fail()
  }
}

pub fn parse_command_with_args_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 100, \"message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": \"/search hello world\", \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": null}",
    )
  case telegram.parse_command(update) {
    Some(#(cmd, args)) -> {
      cmd |> should.equal("search")
      args |> should.equal(["hello", "world"])
    }
    None -> should.fail()
  }
}

pub fn parse_command_not_a_command_test() -> Nil {
  let update =
    decode_update_from_json(
      "{\"update_id\": 100, \"message\": {\"message_id\": 1, \"from\": null, \"sender_chat\": null, \"date\": 1609459200, \"chat\": {\"id\": 123, \"type\": \"private\", \"title\": null, \"username\": null, \"first_name\": null, \"last_name\": null}, \"forward_from\": null, \"forward_date\": null, \"text\": \"Hello\", \"caption\": null, \"entities\": null, \"caption_entities\": null}, \"edited_message\": null, \"channel_post\": null, \"edited_channel_post\": null, \"inline_query\": null, \"chosen_inline_result\": null, \"callback_query\": null}",
    )
  telegram.parse_command(update) |> should.equal(None)
}

// ============================================================================
// Poller Actor Tests
// ============================================================================

pub fn start_poller_test() -> Nil {
  let config = telegram.new_config("test_token")
  case telegram.start_poller(config) {
    Ok(poller) -> {
      let state = telegram.get_poller_state(poller)
      state.offset |> should.equal(0)
      state.is_running |> should.equal(False)
    }
    Error(_) -> should.fail()
  }
}

pub fn get_poller_state_test() -> Nil {
  let config = telegram.new_config("test_token")
  let assert Ok(poller) = telegram.start_poller(config)
  let state = telegram.get_poller_state(poller)
  state.config.token |> should.equal("test_token")
  state.offset |> should.equal(0)
  state.is_running |> should.equal(False)
}

pub fn set_offset_test() -> Nil {
  let config = telegram.new_config("test_token")
  let assert Ok(poller) = telegram.start_poller(config)
  let assert Ok(Nil) = telegram.set_offset(poller, 100)
  let state = telegram.get_poller_state(poller)
  state.offset |> should.equal(100)
}

pub fn stop_polling_test() -> Nil {
  let config = telegram.new_config("test_token")
  let assert Ok(poller) = telegram.start_poller(config)
  let assert Ok(Nil) = telegram.stop_polling(poller)
  let state = telegram.get_poller_state(poller)
  state.is_running |> should.equal(False)
}

// ============================================================================
// Helper Functions for Tests
// ============================================================================

fn decode_user_from_json(json_str: String) -> telegram.User {
  let decoder = {
    use id <- decode.field("id", decode.int)
    use is_bot <- decode.field("is_bot", decode.bool)
    use first_name <- decode.field("first_name", decode.string)
    use last_name <- decode.field("last_name", decode.optional(decode.string))
    use username <- decode.field("username", decode.optional(decode.string))
    use language_code <- decode.field(
      "language_code",
      decode.optional(decode.string),
    )
    decode.success(telegram.User(
      id: int.to_string(id),
      is_bot: is_bot,
      first_name: first_name,
      last_name: last_name,
      username: username,
      language_code: language_code,
    ))
  }
  let assert Ok(user) = json.parse(from: json_str, using: decoder)
  user
}

fn decode_chat_from_json(json_str: String) -> telegram.Chat {
  let decoder = {
    use id <- decode.field("id", decode.int)
    use chat_type_str <- decode.field("type", decode.string)
    use title <- decode.field("title", decode.optional(decode.string))
    use username <- decode.field("username", decode.optional(decode.string))
    use first_name <- decode.field("first_name", decode.optional(decode.string))
    use last_name <- decode.field("last_name", decode.optional(decode.string))

    let chat_type = case chat_type_str {
      "private" -> telegram.PrivateChat
      "group" -> telegram.GroupChat
      "supergroup" -> telegram.SupergroupChat
      "channel" -> telegram.ChannelChat
      _ -> telegram.PrivateChat
    }

    decode.success(telegram.Chat(
      id: int.to_string(id),
      chat_type: chat_type,
      title: title,
      username: username,
      first_name: first_name,
      last_name: last_name,
    ))
  }
  let assert Ok(chat) = json.parse(from: json_str, using: decoder)
  chat
}

fn decode_message_from_json(json_str: String) -> telegram.Message {
  let assert Ok(msg) =
    json.parse(from: json_str, using: decode_message_helper())
  msg
}

fn decode_message_helper() -> decode.Decoder(telegram.Message) {
  use message_id <- decode.field("message_id", decode.int)
  use from <- decode.field("from", decode.optional(decode_user_helper()))
  use sender_chat <- decode.field(
    "sender_chat",
    decode.optional(decode_chat_helper()),
  )
  use date <- decode.field("date", decode.int)
  use chat <- decode.field("chat", decode_chat_helper())
  use forward_from <- decode.field(
    "forward_from",
    decode.optional(decode_user_helper()),
  )
  use forward_date <- decode.field("forward_date", decode.optional(decode.int))
  use text <- decode.field("text", decode.optional(decode.string))
  use caption <- decode.field("caption", decode.optional(decode.string))
  use entities <- decode.field(
    "entities",
    decode.optional(decode.list(decode_message_entity_helper())),
  )
  use caption_entities <- decode.field(
    "caption_entities",
    decode.optional(decode.list(decode_message_entity_helper())),
  )

  decode.success(telegram.Message(
    message_id: message_id,
    from: from,
    sender_chat: sender_chat,
    date: date,
    chat: chat,
    forward_from: forward_from,
    forward_date: forward_date,
    text: text,
    caption: caption,
    entities: option.unwrap(entities, []),
    caption_entities: option.unwrap(caption_entities, []),
    reply_to_message_id: None,
  ))
}

fn decode_user_helper() -> decode.Decoder(telegram.User) {
  use id <- decode.field("id", decode.int)
  use is_bot <- decode.field("is_bot", decode.bool)
  use first_name <- decode.field("first_name", decode.string)
  use last_name <- decode.field("last_name", decode.optional(decode.string))
  use username <- decode.field("username", decode.optional(decode.string))
  use language_code <- decode.field(
    "language_code",
    decode.optional(decode.string),
  )
  decode.success(telegram.User(
    id: int.to_string(id),
    is_bot: is_bot,
    first_name: first_name,
    last_name: last_name,
    username: username,
    language_code: language_code,
  ))
}

fn decode_chat_helper() -> decode.Decoder(telegram.Chat) {
  use id <- decode.field("id", decode.int)
  use chat_type_str <- decode.field("type", decode.string)
  use title <- decode.field("title", decode.optional(decode.string))
  use username <- decode.field("username", decode.optional(decode.string))
  use first_name <- decode.field("first_name", decode.optional(decode.string))
  use last_name <- decode.field("last_name", decode.optional(decode.string))

  let chat_type = case chat_type_str {
    "private" -> telegram.PrivateChat
    "group" -> telegram.GroupChat
    "supergroup" -> telegram.SupergroupChat
    "channel" -> telegram.ChannelChat
    _ -> telegram.PrivateChat
  }

  decode.success(telegram.Chat(
    id: int.to_string(id),
    chat_type: chat_type,
    title: title,
    username: username,
    first_name: first_name,
    last_name: last_name,
  ))
}

fn decode_message_entity_helper() -> decode.Decoder(telegram.MessageEntity) {
  use entity_type_str <- decode.field("type", decode.string)
  use offset <- decode.field("offset", decode.int)
  use length <- decode.field("length", decode.int)
  use url <- decode.field("url", decode.optional(decode.string))
  use user <- decode.field("user", decode.optional(decode_user_helper()))
  use language <- decode.field("language", decode.optional(decode.string))
  use custom_emoji_id <- decode.field(
    "custom_emoji_id",
    decode.optional(decode.string),
  )

  let entity_type = case entity_type_str {
    "mention" -> telegram.MentionEntity
    "hashtag" -> telegram.HashtagEntity
    "cashtag" -> telegram.CashtagEntity
    "bot_command" -> telegram.BotCommandEntity
    "url" -> telegram.UrlEntity
    "email" -> telegram.EmailEntity
    "phone_number" -> telegram.PhoneNumberEntity
    "bold" -> telegram.BoldEntity
    "italic" -> telegram.ItalicEntity
    "underline" -> telegram.UnderlineEntity
    "strikethrough" -> telegram.StrikethroughEntity
    "spoiler" -> telegram.SpoilerEntity
    "code" -> telegram.CodeEntity
    "pre" -> telegram.PreEntity
    "text_link" -> telegram.TextLinkEntity
    "text_mention" -> telegram.TextMentionEntity
    "custom_emoji" -> telegram.CustomEmojiEntity
    _ -> telegram.MentionEntity
  }

  decode.success(telegram.MessageEntity(
    entity_type: entity_type,
    offset: offset,
    length: length,
    url: url,
    user: user,
    language: language,
    custom_emoji_id: custom_emoji_id,
  ))
}

fn decode_callback_query_from_json(json_str: String) -> telegram.CallbackQuery {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use from <- decode.field("from", decode_user_helper())
    use message <- decode.field(
      "message",
      decode.optional(decode_message_helper()),
    )
    use inline_message_id <- decode.field(
      "inline_message_id",
      decode.optional(decode.string),
    )
    use chat_instance <- decode.field("chat_instance", decode.string)
    use data <- decode.field("data", decode.optional(decode.string))
    use game_short_name <- decode.field(
      "game_short_name",
      decode.optional(decode.string),
    )

    decode.success(telegram.CallbackQuery(
      id: id,
      from: from,
      message: message,
      inline_message_id: inline_message_id,
      chat_instance: chat_instance,
      data: data,
      game_short_name: game_short_name,
    ))
  }
  let assert Ok(cb) = json.parse(from: json_str, using: decoder)
  cb
}

fn decode_update() -> decode.Decoder(telegram.Update) {
  use update_id <- decode.field("update_id", decode.int)
  use message <- decode.field(
    "message",
    decode.optional(decode_message_helper()),
  )
  use edited_message <- decode.field(
    "edited_message",
    decode.optional(decode_message_helper()),
  )
  use channel_post <- decode.field(
    "channel_post",
    decode.optional(decode_message_helper()),
  )
  use edited_channel_post <- decode.field(
    "edited_channel_post",
    decode.optional(decode_message_helper()),
  )
  use inline_query <- decode.field(
    "inline_query",
    decode.optional(decode_inline_query_helper()),
  )
  use chosen_inline_result <- decode.field(
    "chosen_inline_result",
    decode.optional(decode_chosen_inline_result_helper()),
  )
  use callback_query <- decode.field(
    "callback_query",
    decode.optional(decode_callback_query_helper()),
  )

  decode.success(telegram.Update(
    update_id: update_id,
    message: message,
    edited_message: edited_message,
    channel_post: channel_post,
    edited_channel_post: edited_channel_post,
    inline_query: inline_query,
    chosen_inline_result: chosen_inline_result,
    callback_query: callback_query,
    poll_answer: None,
    message_reaction: None,
  ))
}

fn decode_inline_query_helper() -> decode.Decoder(telegram.InlineQuery) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", decode_user_helper())
  use query <- decode.field("query", decode.string)
  use offset <- decode.field("offset", decode.string)
  use chat_type <- decode.field("chat_type", decode.optional(decode.string))

  let parsed_chat_type = case chat_type {
    Some(type_str) ->
      Some(case type_str {
        "private" -> telegram.PrivateChat
        "group" -> telegram.GroupChat
        "supergroup" -> telegram.SupergroupChat
        "channel" -> telegram.ChannelChat
        _ -> telegram.PrivateChat
      })
    None -> None
  }

  decode.success(telegram.InlineQuery(
    id: id,
    from: from,
    query: query,
    offset: offset,
    chat_type: parsed_chat_type,
  ))
}

fn decode_chosen_inline_result_helper() -> decode.Decoder(
  telegram.ChosenInlineResult,
) {
  use result_id <- decode.field("result_id", decode.string)
  use from <- decode.field("from", decode_user_helper())
  use location <- decode.field(
    "location",
    decode.optional(decode_location_helper()),
  )
  use inline_message_id <- decode.field(
    "inline_message_id",
    decode.optional(decode.string),
  )
  use query <- decode.field("query", decode.string)

  decode.success(telegram.ChosenInlineResult(
    result_id: result_id,
    from: from,
    location: location,
    inline_message_id: inline_message_id,
    query: query,
  ))
}

fn decode_location_helper() -> decode.Decoder(telegram.Location) {
  use latitude <- decode.field("latitude", decode.float)
  use longitude <- decode.field("longitude", decode.float)
  decode.success(telegram.Location(latitude: latitude, longitude: longitude))
}

fn decode_callback_query_helper() -> decode.Decoder(telegram.CallbackQuery) {
  use id <- decode.field("id", decode.string)
  use from <- decode.field("from", decode_user_helper())
  use message <- decode.field(
    "message",
    decode.optional(decode_message_helper()),
  )
  use inline_message_id <- decode.field(
    "inline_message_id",
    decode.optional(decode.string),
  )
  use chat_instance <- decode.field("chat_instance", decode.string)
  use data <- decode.field("data", decode.optional(decode.string))
  use game_short_name <- decode.field(
    "game_short_name",
    decode.optional(decode.string),
  )

  decode.success(telegram.CallbackQuery(
    id: id,
    from: from,
    message: message,
    inline_message_id: inline_message_id,
    chat_instance: chat_instance,
    data: data,
    game_short_name: game_short_name,
  ))
}

fn decode_update_from_json(json_str: String) -> telegram.Update {
  let assert Ok(update) = json.parse(from: json_str, using: decode_update())
  update
}

fn list_length(list: List(a)) -> Int {
  case list {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

// ============================================================================
// Parse Mode Tests
// ============================================================================

pub fn parse_mode_none_test() -> Nil {
  let options = telegram.new_send_options()
  options.parse_mode |> should.equal(telegram.ParseModeNone)
}

pub fn with_parse_mode_markdown_test() -> Nil {
  let options = telegram.new_send_options()
  let options = telegram.with_parse_mode(options, telegram.ParseModeMarkdown)
  options.parse_mode |> should.equal(telegram.ParseModeMarkdown)
}

pub fn with_parse_mode_html_test() -> Nil {
  let options = telegram.new_send_options()
  let options = telegram.with_parse_mode(options, telegram.ParseModeHTML)
  options.parse_mode |> should.equal(telegram.ParseModeHTML)
}

pub fn with_parse_mode_markdown_v2_test() -> Nil {
  let options = telegram.new_send_options()
  let options = telegram.with_parse_mode(options, telegram.ParseModeMarkdownV2)
  options.parse_mode |> should.equal(telegram.ParseModeMarkdownV2)
}

// ============================================================================
// Chat Action Tests
// ============================================================================

pub fn chat_action_typing_test() -> Nil {
  let action = telegram.TypingAction
  // Just verify the type exists
  case action {
    telegram.TypingAction -> should.equal(True, True)
  }
}

pub fn chat_action_upload_photo_test() -> Nil {
  let action = telegram.UploadPhotoAction
  case action {
    telegram.UploadPhotoAction -> should.equal(True, True)
  }
}

pub fn chat_action_all_types_test() -> Nil {
  // Test all action types exist
  let actions = [
    telegram.TypingAction,
    telegram.UploadPhotoAction,
    telegram.RecordVideoAction,
    telegram.UploadVideoAction,
    telegram.RecordVoiceAction,
    telegram.UploadVoiceAction,
    telegram.UploadDocumentAction,
    telegram.ChooseStickerAction,
    telegram.FindLocationAction,
    telegram.RecordVideoNoteAction,
    telegram.UploadVideoNoteAction,
  ]
  actions |> list_length |> should.equal(11)
}

// ============================================================================
// Send Message Options Tests
// ============================================================================

pub fn new_send_options_defaults_test() -> Nil {
  let options = telegram.new_send_options()
  options.parse_mode |> should.equal(telegram.ParseModeNone)
  options.disable_notification |> should.equal(False)
  options.reply_to_message_id |> should.equal(None)
  options.message_thread_id |> should.equal(None)
  options.protect_content |> should.equal(False)
}

pub fn with_disable_notification_test() -> Nil {
  let options = telegram.new_send_options()
  let options = telegram.with_disable_notification(options, True)
  options.disable_notification |> should.equal(True)
}

pub fn with_reply_to_test() -> Nil {
  let options = telegram.new_send_options()
  let options = telegram.with_reply_to(options, 123)
  options.reply_to_message_id |> should.equal(Some(123))
}

pub fn with_message_thread_id_test() -> Nil {
  let options = telegram.new_send_options()
  let options = telegram.with_message_thread_id(options, 77)
  options.message_thread_id |> should.equal(Some(77))
}

pub fn with_protect_content_test() -> Nil {
  let options = telegram.new_send_options()
  let options = telegram.with_protect_content(options, True)
  options.protect_content |> should.equal(True)
}

pub fn with_reply_markup_test() -> Nil {
  let markup =
    telegram.inline_keyboard([
      [telegram.inline_keyboard_button("OpenAI", "picker_provider:openai")],
      [
        telegram.inline_keyboard_button(
          "GPT-5.1",
          "picker_model_select:openai/gpt-5.1",
        ),
      ],
    ])
  let options =
    telegram.new_send_options()
    |> telegram.with_reply_markup(markup)

  case options.reply_markup {
    Some(telegram.InlineKeyboardMarkup(rows)) ->
      list.length(rows) |> should.equal(2)
    None -> should.fail()
  }
}

pub fn build_send_message_body_with_reply_markup_test() -> Nil {
  let options =
    telegram.new_send_options()
    |> telegram.with_reply_markup(
      telegram.inline_keyboard([
        [telegram.inline_keyboard_button("OpenAI", "picker_provider:openai")],
        [
          telegram.inline_keyboard_button(
            "GPT-5.1",
            "picker_model_select:openai/gpt-5.1",
          ),
          telegram.inline_keyboard_button(
            "GPT-4o",
            "picker_model_select:openai/gpt-4o",
          ),
        ],
      ]),
    )

  let body =
    telegram.build_send_message_body("123456", "Choose provider", options)

  string.contains(body, "\"reply_markup\":{\"inline_keyboard\":")
  |> should.equal(True)
  string.contains(body, "\"text\":\"OpenAI\"") |> should.equal(True)
  string.contains(body, "\"callback_data\":\"picker_provider:openai\"")
  |> should.equal(True)
  string.contains(
    body,
    "\"callback_data\":\"picker_model_select:openai/gpt-5.1\"",
  )
  |> should.equal(True)
}

pub fn build_send_message_body_with_message_thread_id_test() -> Nil {
  let options =
    telegram.new_send_options()
    |> telegram.with_message_thread_id(77)

  let body =
    telegram.build_send_message_body("123456", "Thread message", options)

  string.contains(body, "\"message_thread_id\":77") |> should.equal(True)
}

pub fn combined_options_test() -> Nil {
  let options =
    telegram.new_send_options()
    |> telegram.with_parse_mode(telegram.ParseModeMarkdown)
    |> telegram.with_disable_notification(True)
    |> telegram.with_reply_to(456)
    |> telegram.with_protect_content(True)

  options.parse_mode |> should.equal(telegram.ParseModeMarkdown)
  options.disable_notification |> should.equal(True)
  options.reply_to_message_id |> should.equal(Some(456))
  options.protect_content |> should.equal(True)
}

// ============================================================================
// Message Splitting Tests
// ============================================================================

pub fn split_message_short_test() -> Nil {
  let text = "Short message"
  let parts = telegram.split_message(text)
  parts |> list_length |> should.equal(1)
  case parts {
    [first] -> first |> should.equal("Short message")
    _ -> should.fail()
  }
}

pub fn split_message_exact_limit_test() -> Nil {
  // Create a string of exactly 4096 characters
  let text = string.repeat("a", 4096)
  let parts = telegram.split_message(text)
  parts |> list_length |> should.equal(1)
}

pub fn split_message_over_limit_test() -> Nil {
  // Create a string over 4096 characters
  let text = string.repeat("a", 5000)
  let parts = telegram.split_message(text)
  parts |> list_length |> should.equal(2)
}

pub fn split_message_with_newlines_test() -> Nil {
  // Create message with newlines for natural splitting
  let line = string.repeat("a", 2000)
  let text = line <> "\n" <> line <> "\n" <> line
  let parts = telegram.split_message(text)
  // Should split at newlines
  let len = list_length(parts)
  should.equal(len > 0, True)
}

pub fn split_message_preserves_content_test() -> Nil {
  let text = string.repeat("ab", 3000)
  let parts = telegram.split_message(text)
  let rejoined =
    parts
    |> string.join("")
  rejoined |> should.equal(text)
}

pub fn split_message_custom_max_test() -> Nil {
  let text = string.repeat("a", 100)
  let parts = telegram.split_message_with_max(text, 50)
  parts |> list_length |> should.equal(2)
}

pub fn split_message_empty_test() -> Nil {
  let parts = telegram.split_message("")
  parts |> list_length |> should.equal(1)
  case parts {
    [first] -> first |> should.equal("")
    _ -> should.fail()
  }
}

// ============================================================================
// Max Message Length Constant Test
// ============================================================================

pub fn max_message_length_test() -> Nil {
  telegram.max_message_length |> should.equal(4096)
}

// ============================================================================
// Error Type Tests
// ============================================================================

pub fn message_too_long_error_test() -> Nil {
  let error = telegram.MessageTooLongError
  case error {
    telegram.MessageTooLongError -> should.equal(True, True)
  }
}

pub fn invalid_parse_mode_error_test() -> Nil {
  let error = telegram.InvalidParseModeError
  case error {
    telegram.InvalidParseModeError -> should.equal(True, True)
  }
}

// ============================================================================
// Sent Message Type Test
// ============================================================================

pub fn sent_message_type_test() -> Nil {
  let msg =
    telegram.SentMessage(
      message_id: 123,
      chat: telegram.Chat(
        id: "456",
        chat_type: telegram.PrivateChat,
        title: None,
        username: Some("testuser"),
        first_name: Some("Test"),
        last_name: None,
      ),
      date: 1_609_459_200,
      text: Some("Hello"),
    )
  msg.message_id |> should.equal(123)
}
