//// Tests for Discord Slash Commands Module

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/adapters/discord_commands as cmds

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Configuration Tests
// ============================================================================

pub fn new_config_test() {
  let config = cmds.new_config("test-token", "app-id-123")

  config.bot_token |> should.equal("test-token")
  config.application_id |> should.equal("app-id-123")
  config.base_url |> should.equal(None)
  config.timeout_ms |> should.equal(30_000)
}

pub fn with_base_url_test() {
  let config =
    cmds.new_config("test-token", "app-id")
    |> cmds.with_base_url("https://custom.api.url")

  config.base_url |> should.equal(Some("https://custom.api.url"))
}

pub fn with_timeout_test() {
  let config =
    cmds.new_config("test-token", "app-id")
    |> cmds.with_timeout(60_000)

  config.timeout_ms |> should.equal(60_000)
}

// ============================================================================
// Command Builder Tests
// ============================================================================

pub fn new_command_test() {
  let cmd = cmds.new_command("ping", "Ping command")

  cmd.name |> should.equal("ping")
  cmd.description |> should.equal("Ping command")
  cmd.command_type |> should.equal(cmds.ChatInputCommand)
  list.length(cmd.options) |> should.equal(0)
  cmd.dm_permission |> should.equal(Some(True))
  cmd.nsfw |> should.equal(Some(False))
}

pub fn command_with_option_test() {
  let opt = cmds.string_option("name", "The name", True)
  let cmd =
    cmds.new_command("greet", "Greet someone")
    |> cmds.command_with_option(opt)

  list.length(cmd.options) |> should.equal(1)
}

pub fn command_with_options_test() {
  let opt1 = cmds.string_option("name", "The name", True)
  let opt2 = cmds.integer_option("count", "The count", False)
  let cmd =
    cmds.new_command("test", "Test command")
    |> cmds.command_with_options([opt1, opt2])

  list.length(cmd.options) |> should.equal(2)
}

pub fn command_with_dm_permission_test() {
  let cmd =
    cmds.new_command("test", "Test")
    |> cmds.command_with_dm_permission(False)

  cmd.dm_permission |> should.equal(Some(False))
}

pub fn command_with_nsfw_test() {
  let cmd =
    cmds.new_command("test", "Test")
    |> cmds.command_with_nsfw(True)

  cmd.nsfw |> should.equal(Some(True))
}

// ============================================================================
// Command Option Builder Tests
// ============================================================================

pub fn string_option_test() {
  let opt = cmds.string_option("name", "Your name", True)

  opt.name |> should.equal("name")
  opt.description |> should.equal("Your name")
  opt.required |> should.equal(True)
  opt.option_type |> should.equal(cmds.CmdStringOption)
  list.length(opt.choices) |> should.equal(0)
}

pub fn integer_option_test() {
  let opt = cmds.integer_option("count", "Number of items", False)

  opt.name |> should.equal("count")
  opt.option_type |> should.equal(cmds.CmdIntegerOption)
  opt.required |> should.equal(False)
}

pub fn boolean_option_test() {
  let opt = cmds.boolean_option("verbose", "Enable verbose output", False)

  opt.name |> should.equal("verbose")
  opt.option_type |> should.equal(cmds.CmdBooleanOption)
}

pub fn user_option_test() {
  let opt = cmds.user_option("target", "User to target", True)

  opt.name |> should.equal("target")
  opt.option_type |> should.equal(cmds.CmdUserOption)
}

pub fn channel_option_test() {
  let opt = cmds.channel_option("channel", "Channel to use", False)

  opt.name |> should.equal("channel")
  opt.option_type |> should.equal(cmds.CmdChannelOption)
}

pub fn role_option_test() {
  let opt = cmds.role_option("role", "Role to assign", False)

  opt.name |> should.equal("role")
  opt.option_type |> should.equal(cmds.CmdRoleOption)
}

pub fn with_choices_test() {
  let opt =
    cmds.string_option("color", "Pick a color", True)
    |> cmds.with_choices([
      cmds.string_choice("Red", "red"),
      cmds.string_choice("Blue", "blue"),
    ])

  list.length(opt.choices) |> should.equal(2)
}

pub fn string_choice_test() {
  let choice = cmds.string_choice("Red", "red")

  choice.name |> should.equal("Red")
  case choice.value {
    cmds.StringChoiceValue(v) -> v |> should.equal("red")
    _ -> should.fail()
  }
}

pub fn int_choice_test() {
  let choice = cmds.int_choice("One", 1)

  choice.name |> should.equal("One")
  case choice.value {
    cmds.IntChoiceValue(v) -> v |> should.equal(1)
    _ -> should.fail()
  }
}

// ============================================================================
// Response Builder Tests
// ============================================================================

pub fn message_response_test() {
  let response = cmds.message_response("Hello!")

  response.response_type |> should.equal(cmds.ChannelMessageWithSource)
  case response.data {
    Some(data) -> {
      data.content |> should.equal(Some("Hello!"))
      data.ephemeral |> should.equal(False)
    }
    None -> should.fail()
  }
}

pub fn ephemeral_response_test() {
  let response = cmds.ephemeral_response("Secret message")

  response.response_type |> should.equal(cmds.ChannelMessageWithSource)
  case response.data {
    Some(data) -> {
      data.content |> should.equal(Some("Secret message"))
      data.ephemeral |> should.equal(True)
    }
    None -> should.fail()
  }
}

pub fn deferred_response_test() {
  let response = cmds.deferred_response()

  response.response_type |> should.equal(cmds.DeferredChannelMessageWithSource)
  case response.data {
    Some(data) -> data.ephemeral |> should.equal(False)
    None -> should.fail()
  }
}

pub fn deferred_ephemeral_response_test() {
  let response = cmds.deferred_ephemeral_response()

  response.response_type |> should.equal(cmds.DeferredChannelMessageWithSource)
  case response.data {
    Some(data) -> data.ephemeral |> should.equal(True)
    None -> should.fail()
  }
}

pub fn pong_response_test() {
  let response = cmds.pong_response()

  response.response_type |> should.equal(cmds.PongResponse)
  response.data |> should.equal(None)
}

pub fn with_embed_response_test() {
  let embed = cmds.new_embed() |> cmds.embed_title("Test")
  let response =
    cmds.message_response("Hello!")
    |> cmds.with_embed(embed)

  case response.data {
    Some(data) -> list.length(data.embeds) |> should.equal(1)
    None -> should.fail()
  }
}

pub fn with_components_response_test() {
  let response =
    cmds.message_response("Hello!")
    |> cmds.with_components([])

  case response.data {
    Some(data) -> list.length(data.components) |> should.equal(0)
    None -> should.fail()
  }
}

pub fn make_ephemeral_test() {
  let response =
    cmds.message_response("Hello!")
    |> cmds.make_ephemeral()

  case response.data {
    Some(data) -> data.ephemeral |> should.equal(True)
    None -> should.fail()
  }
}

// ============================================================================
// Embed Builder Tests
// ============================================================================

pub fn new_embed_test() {
  let embed = cmds.new_embed()

  embed.title |> should.equal(None)
  embed.description |> should.equal(None)
  embed.color |> should.equal(None)
  list.length(embed.fields) |> should.equal(0)
}

pub fn embed_title_test() {
  let embed = cmds.new_embed() |> cmds.embed_title("Test Title")

  embed.title |> should.equal(Some("Test Title"))
}

pub fn embed_description_test() {
  let embed = cmds.new_embed() |> cmds.embed_description("Test Description")

  embed.description |> should.equal(Some("Test Description"))
}

pub fn embed_color_test() {
  let embed = cmds.new_embed() |> cmds.embed_color(0xff5733)

  embed.color |> should.equal(Some(0xff5733))
}

pub fn embed_field_test() {
  let field = cmds.new_field("Name", "Value")
  let embed = cmds.new_embed() |> cmds.embed_field(field)

  list.length(embed.fields) |> should.equal(1)
}

pub fn new_field_test() {
  let field = cmds.new_field("Test", "Value")

  field.name |> should.equal("Test")
  field.value |> should.equal("Value")
  field.inline |> should.equal(None)
}

pub fn field_inline_test() {
  let field = cmds.new_field("Test", "Value") |> cmds.field_inline(True)

  field.inline |> should.equal(Some(True))
}

// ============================================================================
// Encode Response Tests
// ============================================================================

pub fn encode_pong_response_test() {
  let response = cmds.pong_response()
  let encoded = cmds.encode_response(response)

  encoded |> should.equal("{\"type\":1}")
}

pub fn encode_message_response_test() {
  let response = cmds.message_response("Hello!")
  let encoded = cmds.encode_response(response)

  string.contains(encoded, "\"type\":4") |> should.equal(True)
  string.contains(encoded, "\"content\":\"Hello!\"") |> should.equal(True)
}

pub fn encode_ephemeral_response_test() {
  let response = cmds.ephemeral_response("Secret")
  let encoded = cmds.encode_response(response)

  string.contains(encoded, "\"flags\":64") |> should.equal(True)
}

pub fn encode_deferred_response_test() {
  let response = cmds.deferred_response()
  let encoded = cmds.encode_response(response)

  string.contains(encoded, "\"type\":5") |> should.equal(True)
}

pub fn encode_response_with_embed_test() {
  let embed =
    cmds.new_embed()
    |> cmds.embed_title("Title")
    |> cmds.embed_description("Description")
    |> cmds.embed_color(0xff0000)

  let response =
    cmds.message_response("Hello!")
    |> cmds.with_embed(embed)

  let encoded = cmds.encode_response(response)

  string.contains(encoded, "\"embeds\":") |> should.equal(True)
  string.contains(encoded, "\"title\":\"Title\"") |> should.equal(True)
}

// ============================================================================
// Option Value Extraction Tests
// ============================================================================

pub fn get_string_option_test() {
  let data =
    cmds.CommandPayload(
      id: "cmd-123",
      name: "test",
      options: [
        cmds.CommandOptionPayload(
          name: "name",
          value: Some(cmds.StringVal("John")),
          options: [],
        ),
      ],
      target_id: None,
    )

  cmds.get_string_option(data, "name") |> should.equal(Some("John"))
}

pub fn get_string_option_missing_test() {
  let data =
    cmds.CommandPayload(
      id: "cmd-123",
      name: "test",
      options: [],
      target_id: None,
    )

  cmds.get_string_option(data, "name") |> should.equal(None)
}

pub fn get_int_option_test() {
  let data =
    cmds.CommandPayload(
      id: "cmd-123",
      name: "test",
      options: [
        cmds.CommandOptionPayload(
          name: "count",
          value: Some(cmds.IntVal(42)),
          options: [],
        ),
      ],
      target_id: None,
    )

  cmds.get_int_option(data, "count") |> should.equal(Some(42))
}

pub fn get_bool_option_test() {
  let data =
    cmds.CommandPayload(
      id: "cmd-123",
      name: "test",
      options: [
        cmds.CommandOptionPayload(
          name: "verbose",
          value: Some(cmds.BoolVal(True)),
          options: [],
        ),
      ],
      target_id: None,
    )

  cmds.get_bool_option(data, "verbose") |> should.equal(Some(True))
}

pub fn get_user_option_test() {
  let data =
    cmds.CommandPayload(
      id: "cmd-123",
      name: "test",
      options: [
        cmds.CommandOptionPayload(
          name: "target",
          value: Some(cmds.UserVal("user-123")),
          options: [],
        ),
      ],
      target_id: None,
    )

  cmds.get_user_option(data, "target") |> should.equal(Some("user-123"))
}

pub fn get_channel_option_test() {
  let data =
    cmds.CommandPayload(
      id: "cmd-123",
      name: "test",
      options: [
        cmds.CommandOptionPayload(
          name: "channel",
          value: Some(cmds.ChannelVal("channel-456")),
          options: [],
        ),
      ],
      target_id: None,
    )

  cmds.get_channel_option(data, "channel") |> should.equal(Some("channel-456"))
}

pub fn get_role_option_test() {
  let data =
    cmds.CommandPayload(
      id: "cmd-123",
      name: "test",
      options: [
        cmds.CommandOptionPayload(
          name: "role",
          value: Some(cmds.RoleVal("role-789")),
          options: [],
        ),
      ],
      target_id: None,
    )

  cmds.get_role_option(data, "role") |> should.equal(Some("role-789"))
}

// ============================================================================
// Client Handler Tests
// ============================================================================

pub fn start_client_test() {
  let config = cmds.new_config("test-token", "app-id")
  let result = cmds.start(config)

  case result {
    Ok(client) -> {
      // Test that handler count starts at 0
      cmds.handler_count(client) |> should.equal(0)
      // Clean up
      cmds.clear_handlers(client)
    }
    Error(_) -> should.fail()
  }
}

pub fn register_handler_test() {
  let config = cmds.new_config("test-token", "app-id")
  let assert Ok(client) = cmds.start(config)

  let handler = fn(_interaction, _data) { cmds.message_response("Pong!") }
  cmds.register_handler(client, "ping", handler)

  cmds.handler_count(client) |> should.equal(1)
  cmds.clear_handlers(client)
}

pub fn register_multiple_handlers_test() {
  let config = cmds.new_config("test-token", "app-id")
  let assert Ok(client) = cmds.start(config)

  let handler1 = fn(_interaction, _data) { cmds.message_response("One") }
  let handler2 = fn(_interaction, _data) { cmds.message_response("Two") }

  cmds.register_handler(client, "cmd1", handler1)
  cmds.register_handler(client, "cmd2", handler2)

  cmds.handler_count(client) |> should.equal(2)
  cmds.clear_handlers(client)
}

pub fn register_guild_handler_test() {
  let config = cmds.new_config("test-token", "app-id")
  let assert Ok(client) = cmds.start(config)

  let handler = fn(_interaction, _data) { cmds.message_response("Guild!") }
  cmds.register_guild_handler(client, "ping", handler, "guild-123")

  cmds.handler_count(client) |> should.equal(1)
  cmds.clear_handlers(client)
}

pub fn clear_handlers_test() {
  let config = cmds.new_config("test-token", "app-id")
  let assert Ok(client) = cmds.start(config)

  let handler = fn(_interaction, _data) { cmds.message_response("Test") }
  cmds.register_handler(client, "test", handler)
  cmds.handler_count(client) |> should.equal(1)

  cmds.clear_handlers(client)
  cmds.handler_count(client) |> should.equal(0)
}

pub fn handle_interaction_test() {
  let config = cmds.new_config("test-token", "app-id")
  let assert Ok(client) = cmds.start(config)

  let handler = fn(_interaction, _data) { cmds.message_response("Pong!") }
  cmds.register_handler(client, "ping", handler)

  let interaction =
    cmds.InteractionPayload(
      id: "int-123",
      application_id: "app-123",
      interaction_type: cmds.ApplicationCommandInteraction,
      data: Some(cmds.CommandPayload(
        id: "cmd-123",
        name: "ping",
        options: [],
        target_id: None,
      )),
      guild_id: None,
      channel_id: Some("channel-123"),
      member: None,
      user: Some(cmds.UserPayload(
        id: "user-123",
        username: "testuser",
        discriminator: "0001",
        bot: None,
        avatar: None,
      )),
      token: "token-123",
      version: 1,
    )

  let response = cmds.handle_interaction(client, interaction)

  case response {
    Some(resp) -> {
      resp.response_type |> should.equal(cmds.ChannelMessageWithSource)
      case resp.data {
        Some(data) -> data.content |> should.equal(Some("Pong!"))
        None -> should.fail()
      }
    }
    None -> should.fail()
  }

  cmds.clear_handlers(client)
}

pub fn handle_interaction_no_handler_test() {
  let config = cmds.new_config("test-token", "app-id")
  let assert Ok(client) = cmds.start(config)

  // No handler registered
  let interaction =
    cmds.InteractionPayload(
      id: "int-123",
      application_id: "app-123",
      interaction_type: cmds.ApplicationCommandInteraction,
      data: Some(cmds.CommandPayload(
        id: "cmd-123",
        name: "unknown",
        options: [],
        target_id: None,
      )),
      guild_id: None,
      channel_id: Some("channel-123"),
      member: None,
      user: None,
      token: "token-123",
      version: 1,
    )

  let response = cmds.handle_interaction(client, interaction)
  response |> should.equal(None)
}

pub fn handle_interaction_guild_handler_priority_test() {
  let config = cmds.new_config("test-token", "app-id")
  let assert Ok(client) = cmds.start(config)

  // Global handler
  let global_handler = fn(_interaction, _data) {
    cmds.message_response("Global")
  }
  cmds.register_handler(client, "test", global_handler)

  // Guild-specific handler (should take priority)
  let guild_handler = fn(_interaction, _data) { cmds.message_response("Guild") }
  cmds.register_guild_handler(client, "test", guild_handler, "guild-123")

  let interaction =
    cmds.InteractionPayload(
      id: "int-123",
      application_id: "app-123",
      interaction_type: cmds.ApplicationCommandInteraction,
      data: Some(cmds.CommandPayload(
        id: "cmd-123",
        name: "test",
        options: [],
        target_id: None,
      )),
      guild_id: Some("guild-123"),
      channel_id: Some("channel-123"),
      member: None,
      user: None,
      token: "token-123",
      version: 1,
    )

  let response = cmds.handle_interaction(client, interaction)

  case response {
    Some(resp) -> {
      case resp.data {
        Some(data) -> data.content |> should.equal(Some("Guild"))
        None -> should.fail()
      }
    }
    None -> should.fail()
  }

  cmds.clear_handlers(client)
}

// ============================================================================
// Type Conversion Tests
// ============================================================================

pub fn command_type_int_conversion_test() {
  // ChatInputCommand -> 1
  let cmd = cmds.new_command("test", "Test")
  cmd.command_type |> should.equal(cmds.ChatInputCommand)
}

pub fn response_type_int_conversion_test() {
  // Verify response types encode correctly
  let pong = cmds.pong_response()
  pong.response_type |> should.equal(cmds.PongResponse)

  let msg = cmds.message_response("test")
  msg.response_type |> should.equal(cmds.ChannelMessageWithSource)

  let deferred = cmds.deferred_response()
  deferred.response_type |> should.equal(cmds.DeferredChannelMessageWithSource)
}

// ============================================================================
// Button Builder Tests
// ============================================================================

pub fn primary_button_test() {
  let button = cmds.primary_button("btn-1", "Click Me")

  case button {
    cmds.ResponseButton(style, label, _, custom_id, url, disabled) -> {
      style |> should.equal(cmds.PrimaryButton)
      label |> should.equal(Some("Click Me"))
      custom_id |> should.equal(Some("btn-1"))
      url |> should.equal(None)
      disabled |> should.equal(None)
    }
    _ -> should.fail()
  }
}

pub fn secondary_button_test() {
  let button = cmds.secondary_button("btn-2", "Cancel")

  case button {
    cmds.ResponseButton(style, _, _, custom_id, _, _) -> {
      style |> should.equal(cmds.SecondaryButton)
      custom_id |> should.equal(Some("btn-2"))
    }
    _ -> should.fail()
  }
}

pub fn success_button_test() {
  let button = cmds.success_button("btn-3", "Confirm")

  case button {
    cmds.ResponseButton(style, _, _, _, _, _) ->
      style |> should.equal(cmds.SuccessButton)
    _ -> should.fail()
  }
}

pub fn danger_button_test() {
  let button = cmds.danger_button("btn-4", "Delete")

  case button {
    cmds.ResponseButton(style, _, _, _, _, _) ->
      style |> should.equal(cmds.DangerButton)
    _ -> should.fail()
  }
}

pub fn link_button_test() {
  let button = cmds.link_button("https://example.com", "Visit")

  case button {
    cmds.ResponseButton(style, _, _, custom_id, url, _) -> {
      style |> should.equal(cmds.LinkButton)
      custom_id |> should.equal(None)
      url |> should.equal(Some("https://example.com"))
    }
    _ -> should.fail()
  }
}

pub fn button_with_emoji_test() {
  let emoji = cmds.ResponseEmoji(id: None, name: Some("👍"), animated: None)
  let button =
    cmds.primary_button("btn-1", "Like")
    |> cmds.button_with_emoji(emoji)

  case button {
    cmds.ResponseButton(_, _, Some(e), _, _, _) ->
      e.name |> should.equal(Some("👍"))
    _ -> should.fail()
  }
}

pub fn button_disabled_test() {
  let button =
    cmds.primary_button("btn-1", "Click")
    |> cmds.button_disabled(True)

  case button {
    cmds.ResponseButton(_, _, _, _, _, Some(disabled)) ->
      disabled |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn action_row_test() {
  let buttons = [
    cmds.primary_button("btn-1", "Yes"),
    cmds.secondary_button("btn-2", "No"),
  ]
  let row = cmds.action_row(buttons)

  list.length(row.components) |> should.equal(2)
}

pub fn button_row_test() {
  let row =
    cmds.button_row([
      cmds.primary_button("btn-1", "One"),
      cmds.primary_button("btn-2", "Two"),
    ])

  list.length(row.components) |> should.equal(2)
}

// ============================================================================
// Select Menu Builder Tests
// ============================================================================

pub fn string_select_test() {
  let select =
    cmds.string_select("select-1", [
      cmds.select_option("Option A", "a"),
      cmds.select_option("Option B", "b"),
    ])

  case select {
    cmds.ResponseStringSelect(custom_id, options, _, _, _, _) -> {
      custom_id |> should.equal("select-1")
      list.length(options) |> should.equal(2)
    }
    _ -> should.fail()
  }
}

pub fn select_option_test() {
  let option = cmds.select_option("Label", "value")

  option.label |> should.equal("Label")
  option.value |> should.equal("value")
  option.description |> should.equal(None)
}

pub fn option_with_description_test() {
  let option =
    cmds.select_option("Label", "value")
    |> cmds.option_with_description("A description")

  option.description |> should.equal(Some("A description"))
}

pub fn select_with_placeholder_test() {
  let select =
    cmds.string_select("select-1", [cmds.select_option("A", "a")])
    |> cmds.select_with_placeholder("Choose...")

  case select {
    cmds.ResponseStringSelect(_, _, Some(ph), _, _, _) ->
      ph |> should.equal("Choose...")
    _ -> should.fail()
  }
}

// ============================================================================
// Modal Builder Tests
// ============================================================================

pub fn modal_response_test() {
  let modal =
    cmds.modal_response("modal-1", "Survey Form", [
      cmds.input_row(cmds.short_input("name", "Your Name")),
    ])

  modal.response_type |> should.equal(cmds.ModalResponse)
  case modal.data {
    Some(data) -> {
      data.custom_id |> should.equal(Some("modal-1"))
      data.title |> should.equal(Some("Survey Form"))
      list.length(data.components) |> should.equal(1)
    }
    None -> should.fail()
  }
}

pub fn short_input_test() {
  let input = cmds.short_input("username", "Username")

  case input {
    cmds.ResponseTextInput(custom_id, label, style, _, _, _, _, _) -> {
      custom_id |> should.equal("username")
      label |> should.equal("Username")
      style |> should.equal(cmds.ShortInput)
    }
    _ -> should.fail()
  }
}

pub fn paragraph_input_test() {
  let input = cmds.paragraph_input("bio", "Your Bio")

  case input {
    cmds.ResponseTextInput(_, _, style, _, _, _, _, _) ->
      style |> should.equal(cmds.ParagraphInput)
    _ -> should.fail()
  }
}

pub fn input_with_placeholder_test() {
  let input =
    cmds.short_input("name", "Name")
    |> cmds.input_with_placeholder("Enter your name...")

  case input {
    cmds.ResponseTextInput(_, _, _, Some(ph), _, _, _, _) ->
      ph |> should.equal("Enter your name...")
    _ -> should.fail()
  }
}

pub fn input_with_value_test() {
  let input =
    cmds.short_input("name", "Name")
    |> cmds.input_with_value("Default")

  case input {
    cmds.ResponseTextInput(_, _, _, _, Some(v), _, _, _) ->
      v |> should.equal("Default")
    _ -> should.fail()
  }
}

pub fn input_required_test() {
  let input =
    cmds.short_input("name", "Name")
    |> cmds.input_required(True)

  case input {
    cmds.ResponseTextInput(_, _, _, _, _, Some(req), _, _) ->
      req |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn input_min_length_test() {
  let input =
    cmds.short_input("name", "Name")
    |> cmds.input_min_length(3)

  case input {
    cmds.ResponseTextInput(_, _, _, _, _, _, Some(min), _) ->
      min |> should.equal(3)
    _ -> should.fail()
  }
}

pub fn input_max_length_test() {
  let input =
    cmds.short_input("name", "Name")
    |> cmds.input_max_length(100)

  case input {
    cmds.ResponseTextInput(_, _, _, _, _, _, _, Some(max)) ->
      max |> should.equal(100)
    _ -> should.fail()
  }
}

pub fn input_row_test() {
  let input = cmds.short_input("name", "Name")
  let row = cmds.input_row(input)

  list.length(row.components) |> should.equal(1)
}

// ============================================================================
// Update Message Response Tests
// ============================================================================

pub fn update_message_response_test() {
  let response = cmds.update_message_response()

  response.response_type |> should.equal(cmds.UpdateMessage)
  case response.data {
    Some(data) -> {
      data.content |> should.equal(None)
      list.length(data.components) |> should.equal(0)
    }
    None -> should.fail()
  }
}

pub fn deferred_update_response_test() {
  let response = cmds.deferred_update_response()

  response.response_type |> should.equal(cmds.DeferredUpdateMessage)
}

pub fn update_with_content_test() {
  let response =
    cmds.update_message_response()
    |> cmds.update_with_content("Updated!")

  case response.data {
    Some(data) -> data.content |> should.equal(Some("Updated!"))
    None -> should.fail()
  }
}

// ============================================================================
// Modal Value Extraction Tests
// ============================================================================

pub fn get_modal_value_test() {
  let data =
    cmds.ModalPayload(custom_id: "modal-1", components: [
      cmds.ResponseActionRow(components: [
        cmds.ResponseTextInput(
          custom_id: "name",
          label: "Name",
          style: cmds.ShortInput,
          placeholder: None,
          value: Some("John"),
          required: None,
          min_length: None,
          max_length: None,
        ),
      ]),
    ])

  cmds.get_modal_value(data, "name") |> should.equal(Some("John"))
}

pub fn get_modal_value_missing_test() {
  let data =
    cmds.ModalPayload(custom_id: "modal-1", components: [
      cmds.ResponseActionRow(components: [
        cmds.ResponseTextInput(
          custom_id: "name",
          label: "Name",
          style: cmds.ShortInput,
          placeholder: None,
          value: Some("John"),
          required: None,
          min_length: None,
          max_length: None,
        ),
      ]),
    ])

  cmds.get_modal_value(data, "email") |> should.equal(None)
}

pub fn get_modal_values_test() {
  let data =
    cmds.ModalPayload(custom_id: "modal-1", components: [
      cmds.ResponseActionRow(components: [
        cmds.ResponseTextInput(
          custom_id: "name",
          label: "Name",
          style: cmds.ShortInput,
          placeholder: None,
          value: Some("John"),
          required: None,
          min_length: None,
          max_length: None,
        ),
      ]),
      cmds.ResponseActionRow(components: [
        cmds.ResponseTextInput(
          custom_id: "email",
          label: "Email",
          style: cmds.ShortInput,
          placeholder: None,
          value: Some("john@example.com"),
          required: None,
          min_length: None,
          max_length: None,
        ),
      ]),
    ])

  let values = cmds.get_modal_values(data)
  dict.size(values) |> should.equal(2)
  dict.get(values, "name") |> should.equal(Ok("John"))
  dict.get(values, "email") |> should.equal(Ok("john@example.com"))
}

pub fn get_modal_values_not_modal_test() {
  let data =
    cmds.CommandPayload(id: "cmd-1", name: "test", options: [], target_id: None)

  let values = cmds.get_modal_values(data)
  dict.size(values) |> should.equal(0)
}

// ============================================================================
// Input Validation Tests
// ============================================================================

pub fn validate_required_valid_test() {
  let result = cmds.validate_required(Some("value"), "Field")
  result |> should.equal(cmds.ValidInput)
}

pub fn validate_required_empty_test() {
  let result = cmds.validate_required(Some(""), "Field")
  case result {
    cmds.InvalidInput(error) ->
      string.contains(error, "required") |> should.equal(True)
    cmds.ValidInput -> should.fail()
  }
}

pub fn validate_required_none_test() {
  let result = cmds.validate_required(None, "Field")
  case result {
    cmds.InvalidInput(error) ->
      string.contains(error, "required") |> should.equal(True)
    cmds.ValidInput -> should.fail()
  }
}

pub fn validate_min_length_valid_test() {
  let result = cmds.validate_min_length(Some("hello"), 3, "Field")
  result |> should.equal(cmds.ValidInput)
}

pub fn validate_min_length_invalid_test() {
  let result = cmds.validate_min_length(Some("hi"), 3, "Field")
  case result {
    cmds.InvalidInput(error) ->
      string.contains(error, "3") |> should.equal(True)
    cmds.ValidInput -> should.fail()
  }
}

pub fn validate_max_length_valid_test() {
  let result = cmds.validate_max_length(Some("hi"), 10, "Field")
  result |> should.equal(cmds.ValidInput)
}

pub fn validate_max_length_invalid_test() {
  let result = cmds.validate_max_length(Some("hello world"), 5, "Field")
  case result {
    cmds.InvalidInput(error) ->
      string.contains(error, "5") |> should.equal(True)
    cmds.ValidInput -> should.fail()
  }
}

pub fn validate_contains_valid_test() {
  let result = cmds.validate_contains(Some("hello@world.com"), "@", "Email")
  result |> should.equal(cmds.ValidInput)
}

pub fn validate_contains_invalid_test() {
  let result = cmds.validate_contains(Some("helloworld.com"), "@", "Email")
  case result {
    cmds.InvalidInput(error) ->
      string.contains(error, "@") |> should.equal(True)
    cmds.ValidInput -> should.fail()
  }
}

pub fn validate_is_number_valid_test() {
  let result = cmds.validate_is_number(Some("42"), "Count")
  result |> should.equal(cmds.ValidInput)
}

pub fn validate_is_number_invalid_test() {
  let result = cmds.validate_is_number(Some("abc"), "Count")
  case result {
    cmds.InvalidInput(error) ->
      string.contains(error, "number") |> should.equal(True)
    cmds.ValidInput -> should.fail()
  }
}

pub fn validate_range_valid_test() {
  let result = cmds.validate_range(Some("50"), 0, 100, "Percent")
  result |> should.equal(cmds.ValidInput)
}

pub fn validate_range_invalid_low_test() {
  let result = cmds.validate_range(Some("-5"), 0, 100, "Percent")
  case result {
    cmds.InvalidInput(error) ->
      string.contains(error, "0") |> should.equal(True)
    cmds.ValidInput -> should.fail()
  }
}

pub fn validate_range_invalid_high_test() {
  let result = cmds.validate_range(Some("150"), 0, 100, "Percent")
  case result {
    cmds.InvalidInput(error) ->
      string.contains(error, "100") |> should.equal(True)
    cmds.ValidInput -> should.fail()
  }
}

pub fn combine_validations_all_valid_test() {
  let result =
    cmds.combine_validations([
      cmds.ValidInput,
      cmds.ValidInput,
      cmds.ValidInput,
    ])
  result |> should.equal(cmds.ValidInput)
}

pub fn combine_validations_with_error_test() {
  let result =
    cmds.combine_validations([
      cmds.ValidInput,
      cmds.InvalidInput(error: "Error!"),
      cmds.ValidInput,
    ])
  case result {
    cmds.InvalidInput(error) -> error |> should.equal("Error!")
    cmds.ValidInput -> should.fail()
  }
}

pub fn validation_error_response_test() {
  let result = cmds.InvalidInput(error: "Invalid field")
  let response = cmds.validation_error_response(result)

  case response.data {
    Some(data) -> {
      data.ephemeral |> should.equal(True)
      case data.content {
        Some(content) ->
          string.contains(content, "Invalid field") |> should.equal(True)
        None -> should.fail()
      }
    }
    None -> should.fail()
  }
}

// ============================================================================
// Button Interaction Handler Tests
// ============================================================================

pub fn handle_button_interaction_test() {
  let config = cmds.new_config("test-token", "app-id")
  let assert Ok(client) = cmds.start(config)

  let handler = fn(_interaction, _data) {
    cmds.update_message_response()
    |> cmds.update_with_content("Button clicked!")
  }
  cmds.register_handler(client, "btn-confirm", handler)

  let interaction =
    cmds.InteractionPayload(
      id: "int-123",
      application_id: "app-123",
      interaction_type: cmds.MessageComponentInteraction,
      data: Some(cmds.ComponentPayload(custom_id: "btn-confirm", values: None)),
      guild_id: None,
      channel_id: Some("channel-123"),
      member: None,
      user: Some(cmds.UserPayload(
        id: "user-123",
        username: "testuser",
        discriminator: "0001",
        bot: None,
        avatar: None,
      )),
      token: "token-123",
      version: 1,
    )

  let response = cmds.handle_interaction(client, interaction)

  case response {
    Some(resp) -> {
      resp.response_type |> should.equal(cmds.UpdateMessage)
      case resp.data {
        Some(data) -> data.content |> should.equal(Some("Button clicked!"))
        None -> should.fail()
      }
    }
    None -> should.fail()
  }

  cmds.clear_handlers(client)
}

pub fn handle_modal_submit_test() {
  let config = cmds.new_config("test-token", "app-id")
  let assert Ok(client) = cmds.start(config)

  let handler = fn(_interaction, data) {
    let name = cmds.get_modal_value(data, "name")
    case name {
      Some(n) -> cmds.ephemeral_response("Hello, " <> n <> "!")
      None -> cmds.ephemeral_response("No name provided")
    }
  }
  cmds.register_handler(client, "modal-greeting", handler)

  let interaction =
    cmds.InteractionPayload(
      id: "int-123",
      application_id: "app-123",
      interaction_type: cmds.ModalSubmitInteraction,
      data: Some(
        cmds.ModalPayload(custom_id: "modal-greeting", components: [
          cmds.ResponseActionRow(components: [
            cmds.ResponseTextInput(
              custom_id: "name",
              label: "Name",
              style: cmds.ShortInput,
              placeholder: None,
              value: Some("Alice"),
              required: None,
              min_length: None,
              max_length: None,
            ),
          ]),
        ]),
      ),
      guild_id: None,
      channel_id: Some("channel-123"),
      member: None,
      user: Some(cmds.UserPayload(
        id: "user-123",
        username: "testuser",
        discriminator: "0001",
        bot: None,
        avatar: None,
      )),
      token: "token-123",
      version: 1,
    )

  let response = cmds.handle_interaction(client, interaction)

  case response {
    Some(resp) -> {
      resp.response_type |> should.equal(cmds.ChannelMessageWithSource)
      case resp.data {
        Some(data) -> {
          data.ephemeral |> should.equal(True)
          case data.content {
            Some(content) ->
              string.contains(content, "Alice") |> should.equal(True)
            None -> should.fail()
          }
        }
        None -> should.fail()
      }
    }
    None -> should.fail()
  }

  cmds.clear_handlers(client)
}

// ============================================================================
// Encode Component Tests
// ============================================================================

pub fn encode_button_test() {
  let button = cmds.primary_button("btn-1", "Click")
  let row = cmds.action_row([button])
  let response =
    cmds.message_response("Test")
    |> cmds.with_components([row])

  let encoded = cmds.encode_response(response)

  string.contains(encoded, "\"type\":2") |> should.equal(True)
  string.contains(encoded, "\"style\":1") |> should.equal(True)
  string.contains(encoded, "\"custom_id\":\"btn-1\"") |> should.equal(True)
  string.contains(encoded, "\"label\":\"Click\"") |> should.equal(True)
}

pub fn encode_link_button_test() {
  let button = cmds.link_button("https://example.com", "Visit")
  let row = cmds.action_row([button])
  let response =
    cmds.message_response("Test")
    |> cmds.with_components([row])

  let encoded = cmds.encode_response(response)

  string.contains(encoded, "\"type\":2") |> should.equal(True)
  string.contains(encoded, "\"style\":5") |> should.equal(True)
  string.contains(encoded, "\"url\":\"https://example.com\"")
  |> should.equal(True)
}

pub fn encode_select_menu_test() {
  let select =
    cmds.string_select("select-1", [
      cmds.select_option("A", "a"),
      cmds.select_option("B", "b"),
    ])
  let row = cmds.action_row([select])
  let response =
    cmds.message_response("Test")
    |> cmds.with_components([row])

  let encoded = cmds.encode_response(response)

  string.contains(encoded, "\"type\":3") |> should.equal(True)
  string.contains(encoded, "\"custom_id\":\"select-1\"") |> should.equal(True)
  string.contains(encoded, "\"options\":") |> should.equal(True)
}

pub fn encode_modal_test() {
  let modal =
    cmds.modal_response("modal-1", "Form", [
      cmds.input_row(cmds.short_input("name", "Name")),
    ])

  let encoded = cmds.encode_response(modal)

  string.contains(encoded, "\"type\":9") |> should.equal(True)
  string.contains(encoded, "\"custom_id\":\"modal-1\"") |> should.equal(True)
  string.contains(encoded, "\"title\":\"Form\"") |> should.equal(True)
}

pub fn encode_text_input_test() {
  let input =
    cmds.short_input("username", "Username")
    |> cmds.input_required(True)
    |> cmds.input_min_length(3)
    |> cmds.input_max_length(20)
    |> cmds.input_with_placeholder("Enter username")

  let row = cmds.input_row(input)
  let modal = cmds.modal_response("modal-1", "Form", [row])

  let encoded = cmds.encode_response(modal)

  string.contains(encoded, "\"type\":4") |> should.equal(True)
  string.contains(encoded, "\"custom_id\":\"username\"") |> should.equal(True)
  string.contains(encoded, "\"label\":\"Username\"") |> should.equal(True)
  string.contains(encoded, "\"required\":true") |> should.equal(True)
  string.contains(encoded, "\"min_length\":3") |> should.equal(True)
  string.contains(encoded, "\"max_length\":20") |> should.equal(True)
}
