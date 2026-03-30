//// Telegram Channel Tests — Fixture-Based Update Parsing
//// Fixtures source: test/fixtures/telegram/ (sanitized real captures)
////
//// The adapter uses gleam/dynamic/decode (proper JSON decoder), so field order
//// does not matter. Unknown fields are silently ignored. Missing optional
//// fields return None.
////
//// Known gaps documented inline:
////   - poll_answer and message_reaction update types are not in the Update
////     type; those updates parse successfully but all content fields are None.
////   - getUpdates_Media.json contains raw Message objects (no update_id) and
////     cannot be parsed as Update objects.

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/adapters/telegram

// ============================================================================
// getUpdates_All — single text message
// ============================================================================

pub fn fixture_get_updates_all_parses_one_update_test() {
  // Source: test/fixtures/telegram/getUpdates_All.json
  let json =
    "[{\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":171,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"text\":\"Anonymized message content\",\"date\":1774569232},\"update_id\":737343144}]"

  let assert Ok(updates) = telegram.parse_updates_array(json)
  list.length(updates) |> should.equal(1)

  let assert [update] = updates
  update.update_id |> should.equal(737_343_144)

  case update.message {
    Some(msg) -> {
      msg.message_id |> should.equal(171)
      msg.text |> should.equal(Some("Anonymized message content"))
      msg.chat.id |> should.equal("12345678")
      msg.chat.chat_type |> should.equal(telegram.PrivateChat)
    }
    None -> should.fail()
  }
}

pub fn fixture_get_updates_all_sender_fields_test() {
  let json =
    "[{\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":171,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"text\":\"Anonymized message content\",\"date\":1774569232},\"update_id\":737343144}]"

  let assert Ok([update]) = telegram.parse_updates_array(json)
  let assert Some(msg) = update.message
  let assert Some(from) = msg.from
  from.id |> should.equal("12345678")
  from.is_bot |> should.equal(False)
  from.username |> should.equal(Some("anonymized_bot"))
  from.language_code |> should.equal(Some("pt-br"))
}

// ============================================================================
// getUpdates_EditedMessage — single Update object (not an array)
// ============================================================================

pub fn fixture_edited_message_parses_as_single_update_test() {
  // Source: test/fixtures/telegram/getUpdates_EditedMessage.json
  // This fixture is a single Update object, not wrapped in an array.
  let json =
    "{\"edited_message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":150,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"text\":\"Anonymized message content\",\"edit_date\":1774567900,\"date\":1774567800},\"update_id\":123456789}"

  let assert Ok(update) = telegram.parse_update(json)
  update.update_id |> should.equal(123_456_789)
  update.message |> should.equal(None)

  case update.edited_message {
    Some(msg) -> {
      msg.message_id |> should.equal(150)
      msg.text |> should.equal(Some("Anonymized message content"))
    }
    None -> should.fail()
  }
}

// ============================================================================
// getUpdates_MessageReaction — unknown update type parsed with empty content
// ============================================================================

pub fn fixture_message_reaction_update_parses_correctly_test() {
  // Source: test/fixtures/telegram/getUpdates_MessageReaction.json
  let json =
    "{\"message_reaction\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":150,\"user\":{\"is_bot\":false,\"id\":12345678,\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"old_reaction\":[],\"date\":1774567800,\"new_reaction\":[{\"emoji\":\"\\u2764\\ufe0f\",\"type\":\"emoji\"}]},\"update_id\":123456790}"

  let assert Ok(update) = telegram.parse_update(json)
  update.update_id |> should.equal(123_456_790)
  update.message |> should.equal(None)

  case update.message_reaction {
    Some(reaction) -> {
      reaction.message_id |> should.equal(150)
      reaction.chat.id |> should.equal("12345678")
      reaction.date |> should.equal(1_774_567_800)
      reaction.old_reaction |> should.equal([])
      case reaction.new_reaction {
        [r] -> {
          r.reaction_type |> should.equal("emoji")
          r.emoji |> should.equal(Some("❤️"))
        }
        _ -> should.fail()
      }
      case reaction.user {
        Some(u) -> u.id |> should.equal("12345678")
        None -> should.fail()
      }
    }
    None -> should.fail()
  }
}

// ============================================================================
// getUpdates_Collection — mixed update types
// ============================================================================

pub fn fixture_collection_parses_all_seven_updates_test() {
  // Source: test/fixtures/telegram/getUpdates_Collection.json
  // Contains: poll_answer, text message, 2x message_reaction,
  //           edited_message, photo message, pinned message.
  let json = fixture_collection()

  let assert Ok(updates) = telegram.parse_updates_array(json)
  list.length(updates) |> should.equal(7)
}

pub fn fixture_collection_update_ids_in_order_test() {
  let assert Ok(updates) = telegram.parse_updates_array(fixture_collection())
  let ids = list.map(updates, fn(u) { u.update_id })
  ids
  |> should.equal([
    893_360_550, 893_360_551, 893_360_552, 893_360_553, 893_360_554, 893_360_555,
    893_360_556,
  ])
}

pub fn fixture_collection_poll_answer_update_parses_correctly_test() {
  let assert Ok(updates) = telegram.parse_updates_array(fixture_collection())
  let assert [poll_answer_update, ..] = updates
  poll_answer_update.update_id |> should.equal(893_360_550)
  poll_answer_update.message |> should.equal(None)

  case poll_answer_update.poll_answer {
    Some(answer) -> {
      answer.poll_id |> should.equal("4974743598277853446")
      answer.option_ids |> should.equal([2])
      case answer.user {
        Some(u) -> u.username |> should.equal(Some("anonymized_bot"))
        None -> should.fail()
      }
    }
    None -> should.fail()
  }
}

pub fn fixture_collection_text_message_parsed_correctly_test() {
  let assert Ok(updates) = telegram.parse_updates_array(fixture_collection())
  let assert [_, text_update, ..] = updates
  text_update.update_id |> should.equal(893_360_551)
  case text_update.message {
    Some(msg) -> {
      msg.message_id |> should.equal(1474)
      msg.text |> should.equal(Some("Anonymized message content"))
    }
    None -> should.fail()
  }
}

pub fn fixture_collection_message_reaction_updates_parse_correctly_test() {
  let assert Ok(updates) = telegram.parse_updates_array(fixture_collection())
  let assert [_, _, reaction1, reaction2, ..] = updates
  reaction1.update_id |> should.equal(893_360_552)
  reaction1.message |> should.equal(None)
  reaction2.update_id |> should.equal(893_360_553)
  reaction2.message |> should.equal(None)

  case reaction1.message_reaction {
    Some(r) -> {
      r.message_id |> should.equal(1472)
      case r.new_reaction {
        [emoji] -> emoji.reaction_type |> should.equal("emoji")
        _ -> should.fail()
      }
    }
    None -> should.fail()
  }

  case reaction2.message_reaction {
    Some(r) -> r.message_id |> should.equal(1471)
    None -> should.fail()
  }
}

pub fn fixture_collection_edited_message_parsed_correctly_test() {
  let assert Ok(updates) = telegram.parse_updates_array(fixture_collection())
  let assert [_, _, _, _, edited_update, ..] = updates
  edited_update.update_id |> should.equal(893_360_554)
  case edited_update.edited_message {
    Some(msg) -> {
      msg.message_id |> should.equal(1474)
      msg.text |> should.equal(Some("Anonymized message content"))
    }
    None -> should.fail()
  }
}

pub fn fixture_collection_photo_message_has_no_text_test() {
  // Photo messages have no text field.
  let assert Ok(updates) = telegram.parse_updates_array(fixture_collection())
  let assert [_, _, _, _, _, photo_update, _] = updates
  photo_update.update_id |> should.equal(893_360_555)
  case photo_update.message {
    Some(msg) -> {
      msg.message_id |> should.equal(1475)
      msg.text |> should.equal(None)
    }
    None -> should.fail()
  }
}

pub fn fixture_collection_pinned_message_has_no_text_test() {
  // Pinned-message notifications have no direct text (the inner pinned_message
  // object is not decoded — it is not a field on Message).
  let assert Ok(updates) = telegram.parse_updates_array(fixture_collection())
  let assert [_, _, _, _, _, _, pinned_update] = updates
  pinned_update.update_id |> should.equal(893_360_556)
  case pinned_update.message {
    Some(msg) -> {
      msg.message_id |> should.equal(1476)
      msg.text |> should.equal(None)
    }
    None -> should.fail()
  }
}

// ============================================================================
// getUpdates_Interactive — contact / poll / venue messages
// ============================================================================

pub fn fixture_interactive_updates_parse_three_updates_test() {
  // Source: test/fixtures/telegram/getUpdates_Interactive.json
  // Contact, poll, and venue messages — none have a text field.
  let json = fixture_interactive()

  let assert Ok(updates) = telegram.parse_updates_array(json)
  list.length(updates) |> should.equal(3)
}

pub fn fixture_interactive_contact_message_has_no_text_test() {
  let assert Ok(updates) = telegram.parse_updates_array(fixture_interactive())
  let assert [contact_update, ..] = updates
  contact_update.update_id |> should.equal(737_343_134)
  case contact_update.message {
    Some(msg) -> {
      msg.message_id |> should.equal(155)
      msg.text |> should.equal(None)
    }
    None -> should.fail()
  }
}

pub fn fixture_interactive_poll_message_has_no_text_test() {
  let assert Ok(updates) = telegram.parse_updates_array(fixture_interactive())
  let assert [_, poll_update, _] = updates
  poll_update.update_id |> should.equal(737_343_135)
  case poll_update.message {
    Some(msg) -> msg.text |> should.equal(None)
    None -> should.fail()
  }
}

pub fn fixture_interactive_venue_message_has_no_text_test() {
  let assert Ok(updates) = telegram.parse_updates_array(fixture_interactive())
  let assert [_, _, venue_update] = updates
  venue_update.update_id |> should.equal(737_343_136)
  case venue_update.message {
    Some(msg) -> msg.text |> should.equal(None)
    None -> should.fail()
  }
}

// ============================================================================
// getUpdates_Media — raw Message objects, cannot be parsed as Updates
// ============================================================================

pub fn fixture_media_raw_messages_fail_as_update_array_test() {
  // Source: test/fixtures/telegram/getUpdates_Media.json
  // These are raw Message objects (no update_id) rather than Update objects.
  // Parsing them as a list of Updates must fail.
  let json = fixture_media()
  telegram.parse_updates_array(json) |> should.be_error()
}

// ============================================================================
// callbackQuery_choice_a / callbackQuery_choice_b
// ============================================================================

pub fn fixture_callback_query_choice_a_parses_correctly_test() {
  // Source: test/fixtures/telegram/callbackQuery_choice_a.json
  // Note: The fixture uses an integer for the callback query id (sanitization
  // artifact). The decoder accepts both string and integer ids.
  let json = fixture_callback_query_a()

  let assert Ok(cb) = telegram.parse_callback_query(json)
  cb.data |> should.equal(Some("choice_a"))
  cb.chat_instance |> should.equal("123456789012345678")
  cb.from.username |> should.equal(Some("anonymized_bot"))
  cb.from.is_bot |> should.equal(False)
}

pub fn fixture_callback_query_choice_a_message_test() {
  let assert Ok(cb) = telegram.parse_callback_query(fixture_callback_query_a())
  case cb.message {
    Some(msg) -> {
      msg.message_id |> should.equal(159)
      msg.text |> should.equal(Some("Anonymized message content"))
    }
    None -> should.fail()
  }
}

pub fn fixture_callback_query_choice_b_parses_correctly_test() {
  // Source: test/fixtures/telegram/callbackQuery_choice_b.json
  let assert Ok(cb) = telegram.parse_callback_query(fixture_callback_query_b())
  cb.data |> should.equal(Some("choice_b"))
  cb.chat_instance |> should.equal("123456789012345679")
}

pub fn fixture_callback_query_choice_b_message_shared_test() {
  // Both callbacks reference the same original message (message_id 159).
  let assert Ok(cb) = telegram.parse_callback_query(fixture_callback_query_b())
  let assert Some(msg) = cb.message
  msg.message_id |> should.equal(159)
}

// ============================================================================
// Fixture strings
// ============================================================================

fn fixture_collection() -> String {
  "[{\"poll_answer\":{\"option_ids\":[2],\"user\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"poll_id\":\"4974743598277853446\"},\"update_id\":893360550},{\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":1474,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"text\":\"Anonymized message content\",\"date\":1772154459},\"update_id\":893360551},{\"message_reaction\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":1472,\"user\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"old_reaction\":[],\"date\":1772154465,\"new_reaction\":[{\"emoji\":\"\\ud83e\\udd21\",\"type\":\"emoji\"}]},\"update_id\":893360552},{\"message_reaction\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":1471,\"user\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"old_reaction\":[],\"date\":1772154467,\"new_reaction\":[{\"emoji\":\"\\u2764\",\"type\":\"emoji\"}]},\"update_id\":893360553},{\"edited_message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":1474,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"text\":\"Anonymized message content\",\"edit_date\":1772154476,\"date\":1772154459},\"update_id\":893360554},{\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"photo\":[{\"file_unique_id\":\"FILE_UNIQUE_ID_REDACTED\",\"file_size\":1356,\"height\":90,\"file_id\":\"FILE_ID_ANONYMIZED_REDACTED\",\"width\":76}],\"message_id\":1475,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"date\":1772154487},\"update_id\":893360555},{\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"pinned_message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":1475,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"date\":1772154487},\"message_id\":1476,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"date\":1772154491},\"update_id\":893360556}]"
}

fn fixture_interactive() -> String {
  "[{\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"contact\":{\"phone_number\":\"+5511999999999\",\"vcard\":\"Anonymized VCard Data\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\"},\"message_id\":155,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"date\":1774563548},\"update_id\":737343134},{\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":156,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"poll\":{\"question\":\"B\\u00e3o?\",\"total_voter_count\":0,\"id\":12345678,\"type\":\"regular\",\"is_anonymous\":true,\"options\":[{\"voter_count\":0,\"text\":\"Anonymized message content\"},{\"voter_count\":0,\"text\":\"Anonymized message content\"}],\"is_closed\":false,\"allows_multiple_answers\":false},\"date\":1774563551},\"update_id\":737343135},{\"message\":{\"venue\":{\"address\":\"Anonymized Address\",\"location\":{\"longitude\":0.0,\"latitude\":0.0},\"foursquare_type\":\"food/bakery\",\"title\":\"Anonymized Chat Title\",\"foursquare_id\":\"4c8d39585e048cfafcd9d3cd\"},\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"location\":{\"longitude\":0.0,\"latitude\":0.0},\"message_id\":157,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"date\":1774563556},\"update_id\":737343136}]"
}

fn fixture_media() -> String {
  "[{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"forward_date\":1774562669,\"forward_from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":151,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"photo\":[],\"date\":1774563216}]"
}

fn fixture_callback_query_a() -> String {
  "{\"id\":12345678,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":159,\"from\":{\"is_bot\":true,\"id\":12345678,\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"text\":\"Anonymized message content\",\"date\":1774567811},\"chat_instance\":\"123456789012345678\",\"data\":\"choice_a\"}"
}

fn fixture_callback_query_b() -> String {
  "{\"id\":12345678,\"from\":{\"is_bot\":false,\"id\":12345678,\"language_code\":\"pt-br\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"last_name\":\"Name\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":159,\"from\":{\"is_bot\":true,\"id\":12345678,\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"text\":\"Anonymized message content\",\"date\":1774567811},\"chat_instance\":\"123456789012345679\",\"data\":\"choice_b\"}"
}
