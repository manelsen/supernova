//// Tests for the Supernova setup wizard
//// Tests cover pure functions: YAML generation and guide content

import gleam/option.{None, Some}
import gleam/string
import gleeunit
import supernova/wizard.{
  WizardState, discord_guide_steps, empty_state, format_guide, generate_yaml,
  telegram_guide_steps,
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// empty_state Tests
// ============================================================================

pub fn empty_state_defaults_test() {
  let state = empty_state()

  state.app_name |> should_equal("my-bot")
  state.discord_token |> should_equal(None)
  state.discord_app_id |> should_equal(None)
  state.discord_guild_id |> should_equal(None)
  state.telegram_token |> should_equal(None)
  state.matrix_token |> should_equal(None)
  state.lark_token |> should_equal(None)
  state.lark_base_url |> should_equal(None)
  state.google_chat_webhook_url |> should_equal(None)
  state.slack_token |> should_equal(None)
  state.mattermost_token |> should_equal(None)
  state.mattermost_base_url |> should_equal(None)
  state.wechat_work_webhook_url |> should_equal(None)
  state.whatsapp_bridge_url |> should_equal(None)
  state.whatsapp_device_id |> should_equal(None)
  state.output_path |> should_equal("/config/supernova.yaml")
}

// ============================================================================
// discord_guide_steps Tests
// ============================================================================

pub fn discord_guide_steps_returns_list_test() {
  let steps = discord_guide_steps()

  // Should have a reasonable number of steps
  let count = list_length(steps)
  case count > 5 {
    True -> Nil
    False -> panic as "Expected more than 5 Discord guide steps"
  }
}

pub fn discord_guide_steps_starts_with_portal_url_test() {
  let steps = discord_guide_steps()

  // First step should mention the Discord developer portal
  case steps {
    [first, ..] -> {
      case
        string.contains(first, "discord.com/developers")
        || string.contains(first, "Developer")
      {
        True -> Nil
        False ->
          panic as "First Discord step should mention discord.com/developers"
      }
    }
    [] -> panic as "Discord guide steps should not be empty"
  }
}

pub fn discord_guide_steps_mentions_bot_token_test() {
  let steps = discord_guide_steps()
  let combined = string.join(steps, " ")

  case
    string.contains(combined, "Token") || string.contains(combined, "token")
  {
    True -> Nil
    False -> panic as "Discord guide steps should mention Token"
  }
}

pub fn discord_guide_steps_mentions_bot_section_test() {
  let steps = discord_guide_steps()
  let combined = string.join(steps, " ")

  case string.contains(combined, "Bot") || string.contains(combined, "bot") {
    True -> Nil
    False -> panic as "Discord guide steps should mention Bot"
  }
}

// ============================================================================
// telegram_guide_steps Tests
// ============================================================================

pub fn telegram_guide_steps_returns_list_test() {
  let steps = telegram_guide_steps()

  let count = list_length(steps)
  case count > 3 {
    True -> Nil
    False -> panic as "Expected more than 3 Telegram guide steps"
  }
}

pub fn telegram_guide_steps_mentions_botfather_test() {
  let steps = telegram_guide_steps()
  let combined = string.join(steps, " ")

  case string.contains(combined, "BotFather") {
    True -> Nil
    False -> panic as "Telegram guide steps should mention BotFather"
  }
}

pub fn telegram_guide_steps_mentions_newbot_test() {
  let steps = telegram_guide_steps()
  let combined = string.join(steps, " ")

  case
    string.contains(combined, "newbot") || string.contains(combined, "/new")
  {
    True -> Nil
    False -> panic as "Telegram guide steps should mention /newbot command"
  }
}

pub fn telegram_guide_steps_mentions_token_test() {
  let steps = telegram_guide_steps()
  let combined = string.join(steps, " ")

  case
    string.contains(combined, "token") || string.contains(combined, "Token")
  {
    True -> Nil
    False -> panic as "Telegram guide steps should mention token"
  }
}

// ============================================================================
// format_guide Tests
// ============================================================================

pub fn format_guide_indents_steps_test() {
  let steps = ["Step 1", "Step 2"]
  let formatted = format_guide(steps)

  case string.contains(formatted, "  Step 1") {
    True -> Nil
    False -> panic as "Steps should be indented with 2 spaces"
  }
}

pub fn format_guide_joins_with_newlines_test() {
  let steps = ["Alpha", "Beta"]
  let formatted = format_guide(steps)

  case string.contains(formatted, "\n") {
    True -> Nil
    False -> panic as "Steps should be separated by newlines"
  }
}

pub fn format_guide_empty_steps_test() {
  let formatted = format_guide([])
  formatted |> should_equal("")
}

pub fn format_guide_single_step_test() {
  let formatted = format_guide(["Only step"])
  case string.contains(formatted, "Only step") {
    True -> Nil
    False -> panic as "Single step should appear in output"
  }
}

// ============================================================================
// generate_yaml Tests
// ============================================================================

pub fn generate_yaml_discord_only_test() {
  let state =
    WizardState(
      ..empty_state(),
      app_name: "my-discord-bot",
      discord_token: Some("Bot.my-discord-token"),
      discord_app_id: Some("123456789"),
    )

  let yaml = generate_yaml(state)

  case string.contains(yaml, "app_name: \"my-discord-bot\"") {
    True -> Nil
    False -> panic as "YAML should contain app_name"
  }

  case string.contains(yaml, "token: \"Bot.my-discord-token\"") {
    True -> Nil
    False -> panic as "YAML should contain discord token"
  }

  case string.contains(yaml, "app_id: \"123456789\"") {
    True -> Nil
    False -> panic as "YAML should contain discord app_id"
  }

  case string.contains(yaml, "enabled: true") {
    True -> Nil
    False -> panic as "YAML should mark discord as enabled"
  }
}

pub fn generate_yaml_telegram_only_test() {
  let state =
    WizardState(
      ..empty_state(),
      app_name: "my-telegram-bot",
      telegram_token: Some("1234567890:ABCDEfghij"),
    )

  let yaml = generate_yaml(state)

  case string.contains(yaml, "token: \"1234567890:ABCDEfghij\"") {
    True -> Nil
    False -> panic as "YAML should contain telegram token"
  }

  case string.contains(yaml, "telegram:") {
    True -> Nil
    False -> panic as "YAML should have telegram section"
  }
}

pub fn generate_yaml_includes_new_channel_sections_test() {
  let state = empty_state()
  let yaml = generate_yaml(state)

  case
    string.contains(yaml, "matrix:")
    && string.contains(yaml, "lark:")
    && string.contains(yaml, "google_chat:")
    && string.contains(yaml, "slack:")
    && string.contains(yaml, "mattermost:")
    && string.contains(yaml, "wechat_work:")
    && string.contains(yaml, "whatsapp:")
  {
    True -> Nil
    False -> panic as "YAML should include all new channel sections"
  }
}

pub fn generate_yaml_includes_whatsapp_bridge_fields_test() {
  let state =
    WizardState(
      ..empty_state(),
      whatsapp_bridge_url: Some("http://localhost:3000"),
      whatsapp_device_id: Some("device-1"),
    )

  let yaml = generate_yaml(state)

  case
    string.contains(yaml, "bridge_url: \"http://localhost:3000\"")
    && string.contains(yaml, "device_id: \"device-1\"")
  {
    True -> Nil
    False -> panic as "WhatsApp section should include bridge_url and device_id"
  }
}

pub fn generate_yaml_includes_native_channel_runtime_fields_test() {
  let state =
    WizardState(
      ..empty_state(),
      lark_token: Some("lark-token"),
      lark_base_url: Some("https://open.larksuite.com"),
      google_chat_webhook_url: Some(
        "https://chat.googleapis.com/v1/spaces/abc/messages?key=test&token=test",
      ),
      mattermost_token: Some("mattermost-token"),
      mattermost_base_url: Some("https://mattermost.example.com"),
      wechat_work_webhook_url: Some(
        "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=wechat-key",
      ),
    )

  let yaml = generate_yaml(state)

  case
    string.contains(yaml, "lark:")
    && string.contains(yaml, "base_url: \"https://open.larksuite.com\"")
    && string.contains(
      yaml,
      "webhook_url: \"https://chat.googleapis.com/v1/spaces/abc/messages?key=test&token=test\"",
    )
    && string.contains(yaml, "mattermost:")
    && string.contains(yaml, "base_url: \"https://mattermost.example.com\"")
    && string.contains(
      yaml,
      "webhook_url: \"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=wechat-key\"",
    )
  {
    True -> Nil
    False ->
      panic as "YAML should include runtime fields for native channel adapters"
  }
}

pub fn generate_yaml_uses_providers_map_schema_test() {
  let state =
    WizardState(
      ..empty_state(),
      provider_key: Some("openrouter"),
      provider_api_key: Some("sk-router"),
      model: Some("anthropic/claude-haiku-4-5"),
      memory_backend: Some("sqlite"),
    )

  let yaml = generate_yaml(state)

  case
    string.contains(yaml, "providers:")
    && string.contains(yaml, "default:")
    && string.contains(yaml, "provider: \"openrouter\"")
    && string.contains(yaml, "api_key: \"sk-router\"")
    && string.contains(yaml, "model: \"anthropic/claude-haiku-4-5\"")
    && string.contains(yaml, "memory_backend: \"sqlite\"")
    && !string.contains(yaml, "\nprovider:\n")
  {
    True -> Nil
    False ->
      panic as "YAML should use the providers.default schema used by config parsing"
  }
}

pub fn generate_yaml_both_platforms_test() {
  let state =
    WizardState(
      ..empty_state(),
      app_name: "dual-bot",
      discord_token: Some("discord-token-123"),
      discord_app_id: Some("app-999"),
      discord_guild_id: Some("guild-888"),
      telegram_token: Some("telegram-token-456"),
      output_path: "supernova.yaml",
    )

  let yaml = generate_yaml(state)

  case string.contains(yaml, "discord:") {
    True -> Nil
    False -> panic as "YAML should have discord section"
  }

  case string.contains(yaml, "telegram:") {
    True -> Nil
    False -> panic as "YAML should have telegram section"
  }

  case string.contains(yaml, "guild_id: \"guild-888\"") {
    True -> Nil
    False -> panic as "YAML should contain guild_id"
  }
}

pub fn generate_yaml_no_platforms_test() {
  let state = empty_state()
  let yaml = generate_yaml(state)

  case string.contains(yaml, "enabled: false") {
    True -> Nil
    False -> panic as "YAML should mark platforms as disabled when no tokens"
  }
}

pub fn generate_yaml_has_header_comment_test() {
  let state = empty_state()
  let yaml = generate_yaml(state)

  case string.contains(yaml, "#") {
    True -> Nil
    False -> panic as "YAML should have a comment header"
  }
}

pub fn generate_yaml_has_environment_field_test() {
  let state = empty_state()
  let yaml = generate_yaml(state)

  case string.contains(yaml, "environment:") {
    True -> Nil
    False -> panic as "YAML should contain environment field"
  }
}

pub fn generate_yaml_has_log_level_field_test() {
  let state = empty_state()
  let yaml = generate_yaml(state)

  case string.contains(yaml, "log_level:") {
    True -> Nil
    False -> panic as "YAML should contain log_level field"
  }
}

pub fn generate_yaml_discord_no_guild_id_test() {
  let state =
    WizardState(
      ..empty_state(),
      discord_token: Some("tok"),
      discord_guild_id: None,
    )

  let yaml = generate_yaml(state)

  // guild_id line should be absent when not set
  case string.contains(yaml, "guild_id:") {
    True -> panic as "YAML should not contain guild_id when not set"
    False -> Nil
  }
}

pub fn generate_yaml_discord_with_guild_id_test() {
  let state =
    WizardState(
      ..empty_state(),
      discord_token: Some("tok"),
      discord_guild_id: Some("my-guild"),
    )

  let yaml = generate_yaml(state)

  case string.contains(yaml, "guild_id: \"my-guild\"") {
    True -> Nil
    False -> panic as "YAML should contain guild_id when set"
  }
}

// ============================================================================
// Helpers
// ============================================================================

fn should_equal(actual: a, expected: a) -> Nil {
  case actual == expected {
    True -> Nil
    False -> panic
  }
}

fn list_length(lst: List(a)) -> Int {
  case lst {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}
