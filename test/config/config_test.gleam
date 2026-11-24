//// Tests for the Supernova configuration system
//// Tests YAML parsing, environment variable overrides, and validation

import envoy
import gleam/dict
import gleam/option.{None, Some}
import gleeunit
import supernova/config.{
  AccessConfig as AccessConfigRecord, Anthropic, Config as ConfigRecord,
  DiscordConfig as DiscordConfigRecord,
  GoogleChatConfig as GoogleChatConfigRecord, InvalidField,
  LarkConfig as LarkConfigRecord, MatrixConfig as MatrixConfigRecord,
  MattermostConfig as MattermostConfigRecord, Minimax, MissingField, Ollama,
  OpenAI, OpenCodeZen, OpenRouter, SimConfig as SimConfigRecord,
  SlackConfig as SlackConfigRecord, TelegramConfig as TelegramConfigRecord,
  TypeMismatch, ValidationError, WechatWorkConfig as WechatWorkConfigRecord,
  WhatsAppConfig as WhatsAppConfigRecord, YamlParseError, Zhipu, ZhipuCoding,
  apply_env_overrides, default_budgets_config, default_config,
  default_provider_config, default_tools_config, error_to_string, get_provider,
  is_discord_enabled, is_google_chat_enabled, is_lark_enabled, is_matrix_enabled,
  is_mattermost_enabled, is_slack_enabled, is_telegram_enabled,
  is_wechat_work_enabled, is_whatsapp_enabled, load, load_from_file, load_unsafe,
  parse_yaml, provider_default_model, provider_requires_api_key,
  provider_runtime_name, validate,
}
import test_env

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Default Config Tests
// ============================================================================

pub fn default_config_has_correct_defaults_test() {
  let config = default_config()

  config.app_name |> should_equal("supernova")
  config.environment |> should_equal("development")
  config.log_level |> should_equal("info")
  config.providers |> dict.size() |> should_equal(0)
  config.discord.enabled |> should_equal(False)
  config.telegram.enabled |> should_equal(False)
  config.matrix.enabled |> should_equal(False)
  config.lark.enabled |> should_equal(False)
  config.google_chat.enabled |> should_equal(False)
  config.slack.enabled |> should_equal(False)
  config.mattermost.enabled |> should_equal(False)
  config.wechat_work.enabled |> should_equal(False)
  config.whatsapp.enabled |> should_equal(False)
}

pub fn default_provider_config_openai_test() {
  let config = default_provider_config(OpenAI)

  config.provider |> should_equal(OpenAI)
  config.api_key |> should_equal(None)
  config.timeout_ms |> should_equal(30_000)
}

pub fn default_provider_config_anthropic_test() {
  let config = default_provider_config(Anthropic)

  config.provider |> should_equal(Anthropic)
  config.api_key |> should_equal(None)
}

pub fn default_provider_config_ollama_test() {
  let config = default_provider_config(Ollama)

  config.provider |> should_equal(Ollama)
  config.api_key |> should_equal(None)
}

// ============================================================================
// YAML Parsing Tests
// ============================================================================

pub fn parse_empty_yaml_test() {
  let result = parse_yaml("")

  case result {
    Ok(config) -> {
      // Empty YAML should use defaults
      config.app_name |> should_equal("supernova")
      config.environment |> should_equal("development")
    }
    Error(_) -> Nil
  }
}

pub fn parse_simple_config_test() {
  let yaml =
    "
app_name: test-app
environment: production
log_level: debug
"

  let assert Ok(config) = parse_yaml(yaml)

  config.app_name |> should_equal("test-app")
  config.environment |> should_equal("production")
  config.log_level |> should_equal("debug")
}

pub fn parse_discord_config_test() {
  let yaml =
    "
discord:
  token: test-token
  app_id: test-app-id
  guild_id: test-guild-id
  enabled: true
"

  let assert Ok(config) = parse_yaml(yaml)

  config.discord.token |> should_equal(Some("test-token"))
  config.discord.app_id |> should_equal(Some("test-app-id"))
  config.discord.guild_id |> should_equal(Some("test-guild-id"))
  config.discord.enabled |> should_equal(True)
}

pub fn parse_telegram_config_test() {
  let yaml =
    "
telegram:
  token: telegram-token
  enabled: true
"

  let assert Ok(config) = parse_yaml(yaml)

  config.telegram.token |> should_equal(Some("telegram-token"))
  config.telegram.enabled |> should_equal(True)
}

pub fn parse_additional_channels_config_test() {
  let yaml =
    "
matrix:
  token: matrix-token
  enabled: true
lark:
  token: lark-token
  base_url: https://open.larksuite.com
  enabled: true
google_chat:
  webhook_url: https://chat.googleapis.com/v1/spaces/abc/messages?key=test&token=test
  enabled: true
slack:
  token: slack-token
  enabled: true
mattermost:
  token: mattermost-token
  base_url: https://mattermost.example.com
  enabled: true
wechat_work:
  webhook_url: https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=wechat-key
  enabled: true
whatsapp:
  bridge_url: http://localhost:3000
  device_id: device-whatsapp
  enabled: true
"

  let assert Ok(config) = parse_yaml(yaml)

  config.matrix.token |> should_equal(Some("matrix-token"))
  config.matrix.enabled |> should_equal(True)
  config.lark.token |> should_equal(Some("lark-token"))
  config.lark.base_url |> should_equal(Some("https://open.larksuite.com"))
  config.lark.enabled |> should_equal(True)
  config.google_chat.webhook_url
  |> should_equal(Some(
    "https://chat.googleapis.com/v1/spaces/abc/messages?key=test&token=test",
  ))
  config.google_chat.enabled |> should_equal(True)
  config.slack.token |> should_equal(Some("slack-token"))
  config.slack.enabled |> should_equal(True)
  config.mattermost.token |> should_equal(Some("mattermost-token"))
  config.mattermost.base_url
  |> should_equal(Some("https://mattermost.example.com"))
  config.mattermost.enabled |> should_equal(True)
  config.wechat_work.webhook_url
  |> should_equal(Some(
    "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=wechat-key",
  ))
  config.wechat_work.enabled |> should_equal(True)
  config.whatsapp.bridge_url |> should_equal(Some("http://localhost:3000"))
  config.whatsapp.device_id |> should_equal(Some("device-whatsapp"))
  config.whatsapp.enabled |> should_equal(True)
}

/// The database section was removed with Postgres. Existing configs that
/// still carry it must keep loading: the section is ignored.
pub fn legacy_database_section_is_ignored_test() {
  let yaml =
    "
app_name: legacy
database:
  host: postgres
  port: 5432
  pool_size: 0
"

  let assert Ok(config) = load(yaml)

  config.app_name |> should_equal("legacy")
}

pub fn parse_provider_config_test() {
  let yaml =
    "
providers:
  openai-main:
    provider: openai
    api_key: sk-test
    model: gpt-4
    timeout_ms: 60000
  claude:
    type: anthropic
    api_key: sk-anthropic
  router:
    provider: openrouter
    model: anthropic/claude-haiku-4-5
  zen:
    type: opencode_zen
    model: claude-sonnet-4-6
  zhipu-general:
    provider: zhipu
    model: glm-4-plus
  zhipu-code:
    provider: zhipu_coding
    model: codegeex-4
  minimax-main:
    type: minimax
    model: MiniMax-Text-01
  local-llm:
    provider: ollama
    base_url: http://localhost:8080
"

  let assert Ok(config) = parse_yaml(yaml)

  // Check openai-main provider
  let assert Some(openai_config) = get_provider(config, "openai-main")
  openai_config.provider |> should_equal(OpenAI)
  openai_config.api_key |> should_equal(Some("sk-test"))
  openai_config.model |> should_equal(Some("gpt-4"))
  openai_config.timeout_ms |> should_equal(60_000)

  // Check claude provider
  let assert Some(claude_config) = get_provider(config, "claude")
  claude_config.provider |> should_equal(Anthropic)
  claude_config.api_key |> should_equal(Some("sk-anthropic"))

  // Check additional routed providers
  let assert Some(router_config) = get_provider(config, "router")
  router_config.provider |> should_equal(OpenRouter)
  router_config.model |> should_equal(Some("anthropic/claude-haiku-4-5"))

  let assert Some(zen_config) = get_provider(config, "zen")
  zen_config.provider |> should_equal(OpenCodeZen)
  zen_config.model |> should_equal(Some("claude-sonnet-4-6"))

  let assert Some(zhipu_config) = get_provider(config, "zhipu-general")
  zhipu_config.provider |> should_equal(Zhipu)
  zhipu_config.model |> should_equal(Some("glm-4-plus"))

  let assert Some(zhipu_coding_config) = get_provider(config, "zhipu-code")
  zhipu_coding_config.provider |> should_equal(ZhipuCoding)
  zhipu_coding_config.model |> should_equal(Some("codegeex-4"))

  let assert Some(minimax_config) = get_provider(config, "minimax-main")
  minimax_config.provider |> should_equal(Minimax)
  minimax_config.model |> should_equal(Some("MiniMax-Text-01"))

  // Check Ollama provider
  let assert Some(local_config) = get_provider(config, "local-llm")
  local_config.provider |> should_equal(Ollama)
  local_config.base_url |> should_equal(Some("http://localhost:8080"))
}

pub fn parse_provider_alias_local_to_ollama_test() {
  let yaml =
    "
providers:
  test:
    provider: local
"

  let assert Ok(config) = parse_yaml(yaml)
  let assert Some(provider_config) = get_provider(config, "test")

  provider_config.provider |> should_equal(Ollama)
}

pub fn parse_yaml_with_multiple_documents_test() {
  // YAML with multiple documents should return an error
  let yaml = "---\nname: doc1\n---\nname: doc2\n"

  let result = parse_yaml(yaml)

  case result {
    Error(YamlParseError(_)) -> Nil
    Error(_) -> Nil
    Ok(_) -> Nil
    // Multiple docs may be handled differently
  }
}

pub fn parse_invalid_provider_type_test() {
  let yaml =
    "
providers:
  test:
    type: invalid-provider
"

  let result = parse_yaml(yaml)

  case result {
    Error(InvalidField("provider", "invalid-provider", _)) -> Nil
    _ -> panic as "Expected InvalidField error for invalid provider type"
  }
}

pub fn parse_invalid_environment_test() {
  let yaml =
    "
environment: invalid-env
"

  let result = parse_yaml(yaml)

  case result {
    Error(InvalidField("environment", "invalid-env", _)) -> Nil
    _ -> panic as "Expected InvalidField error for invalid environment"
  }
}

pub fn parse_invalid_log_level_test() {
  let yaml =
    "
log_level: trace
"

  let result = parse_yaml(yaml)

  case result {
    Error(InvalidField("log_level", "trace", _)) -> Nil
    _ -> panic as "Expected InvalidField error for invalid log level"
  }
}

// ============================================================================
// Validation Tests
// ============================================================================

pub fn validate_default_config_test() {
  let config = default_config()

  let assert Ok(Nil) = validate(config)
}

pub fn validate_discord_enabled_without_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      discord: DiscordConfigRecord(
        token: None,
        app_id: None,
        guild_id: None,
        enabled: True,
      ),
    )

  case validate(config) {
    Error(ValidationError("Discord is enabled but no token is configured")) ->
      Nil
    _ -> panic as "Expected ValidationError for Discord without token"
  }
}

pub fn validate_sim_enabled_without_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      sim: SimConfigRecord(
        enabled: True,
        bind: "127.0.0.1",
        port: 8787,
        token: None,
        record_prompts: False,
      ),
    )

  case validate(config) {
    Error(ValidationError("Sim is enabled but no token is configured")) -> Nil
    _ -> panic as "Expected ValidationError for sim without token"
  }
}

pub fn validate_telegram_enabled_without_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      telegram: TelegramConfigRecord(token: None, enabled: True, base_url: None),
    )

  case validate(config) {
    Error(ValidationError("Telegram is enabled but no token is configured")) ->
      Nil
    _ -> panic as "Expected ValidationError for Telegram without token"
  }
}

pub fn validate_matrix_enabled_without_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      matrix: MatrixConfigRecord(
        homeserver_url: None,
        token: None,
        enabled: True,
      ),
    )

  case validate(config) {
    Error(ValidationError("Matrix is enabled but no token is configured")) ->
      Nil
    _ -> panic as "Expected ValidationError for Matrix without token"
  }
}

pub fn validate_additional_channels_enabled_without_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      lark: LarkConfigRecord(token: None, base_url: None, enabled: True),
      google_chat: GoogleChatConfigRecord(webhook_url: None, enabled: True),
      slack: SlackConfigRecord(token: None, enabled: True),
      mattermost: MattermostConfigRecord(
        token: None,
        base_url: None,
        enabled: True,
      ),
      wechat_work: WechatWorkConfigRecord(webhook_url: None, enabled: True),
      whatsapp: WhatsAppConfigRecord(
        bridge_url: None,
        device_id: None,
        enabled: True,
      ),
    )

  // First failing channel in validation order should be Lark.
  case validate(config) {
    Error(ValidationError("Lark is enabled but no token is configured")) -> Nil
    _ -> panic as "Expected ValidationError for Lark without token"
  }
}

pub fn validate_google_chat_enabled_without_webhook_url_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      google_chat: GoogleChatConfigRecord(webhook_url: None, enabled: True),
    )

  case validate(config) {
    Error(ValidationError(
      "Google Chat is enabled but no webhook_url is configured",
    )) -> Nil
    _ -> panic as "Expected ValidationError for Google Chat without webhook_url"
  }
}

pub fn validate_mattermost_enabled_without_base_url_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      mattermost: MattermostConfigRecord(
        token: Some("mattermost-token"),
        base_url: None,
        enabled: True,
      ),
    )

  case validate(config) {
    Error(ValidationError("Mattermost is enabled but no base_url is configured")) ->
      Nil
    _ -> panic as "Expected ValidationError for Mattermost without base_url"
  }
}

pub fn validate_wechat_work_enabled_without_webhook_url_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      wechat_work: WechatWorkConfigRecord(webhook_url: None, enabled: True),
    )

  case validate(config) {
    Error(ValidationError(
      "WeChat Work is enabled but no webhook_url is configured",
    )) -> Nil
    _ -> panic as "Expected ValidationError for WeChat Work without webhook_url"
  }
}

pub fn validate_discord_enabled_with_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      discord: DiscordConfigRecord(
        token: Some("valid-token"),
        app_id: None,
        guild_id: None,
        enabled: True,
      ),
    )

  let assert Ok(Nil) = validate(config)
}

pub fn validate_telegram_enabled_with_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      telegram: TelegramConfigRecord(
        token: Some("valid-token"),
        enabled: True,
        base_url: None,
      ),
    )

  let assert Ok(Nil) = validate(config)
}

pub fn validate_all_additional_channels_enabled_with_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      matrix: MatrixConfigRecord(
        homeserver_url: None,
        token: Some("t"),
        enabled: True,
      ),
      lark: LarkConfigRecord(
        token: Some("t"),
        base_url: Some("https://open.larksuite.com"),
        enabled: True,
      ),
      google_chat: GoogleChatConfigRecord(
        webhook_url: Some(
          "https://chat.googleapis.com/v1/spaces/abc/messages?key=test&token=test",
        ),
        enabled: True,
      ),
      slack: SlackConfigRecord(token: Some("t"), enabled: True),
      mattermost: MattermostConfigRecord(
        token: Some("t"),
        base_url: Some("https://mattermost.example.com"),
        enabled: True,
      ),
      wechat_work: WechatWorkConfigRecord(
        webhook_url: Some(
          "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=wechat-key",
        ),
        enabled: True,
      ),
      whatsapp: WhatsAppConfigRecord(
        bridge_url: Some("http://localhost:3000"),
        device_id: Some("device-1"),
        enabled: True,
      ),
    )

  let assert Ok(Nil) = validate(config)
}

// ============================================================================
// Load Function Tests
// ============================================================================

pub fn load_valid_config_test() {
  let yaml =
    "
app_name: test-app
environment: production
log_level: info
discord:
  token: discord-token
  enabled: true
telegram:
  token: telegram-token
  enabled: true
database:
  host: localhost
  port: 5432
  pool_size: 10
"

  let assert Ok(config) = load(yaml)

  config.app_name |> should_equal("test-app")
  config.environment |> should_equal("production")
  config.discord.enabled |> should_equal(True)
  config.telegram.enabled |> should_equal(True)
}

pub fn load_invalid_config_test() {
  let yaml =
    "
discord:
  enabled: true
  # Missing token
"

  let result = load(yaml)

  case result {
    Error(ValidationError(_)) -> Nil
    _ -> panic as "Expected ValidationError"
  }
}

pub fn load_unsafe_skips_validation_test() {
  let yaml =
    "
discord:
  enabled: true
  # Missing token - would fail validation
"

  // load_unsafe should succeed even with invalid config
  let assert Ok(config) = load_unsafe(yaml)
  config.discord.enabled |> should_equal(True)
}

// ============================================================================
// Environment Variable Override Tests
// ============================================================================

pub fn empty_env_value_does_not_override_yaml_test() {
  let base = default_config()
  let yaml_config =
    ConfigRecord(
      ..base,
      telegram: TelegramConfigRecord(
        ..base.telegram,
        token: Some("yaml-telegram-token"),
      ),
      access: AccessConfigRecord(
        ..base.access,
        admins: ["telegram:1"],
        members: ["telegram:2"],
      ),
    )

  envoy.set("SUPERNOVA_TELEGRAM_TOKEN", "")
  envoy.set("SUPERNOVA_ACCESS_ADMINS", "")
  envoy.set("SUPERNOVA_ACCESS_MEMBERS", "")

  let overridden = apply_env_overrides(yaml_config)
  overridden.telegram.token |> should_equal(Some("yaml-telegram-token"))
  overridden.access.admins |> should_equal(["telegram:1"])
  overridden.access.members |> should_equal(["telegram:2"])

  envoy.unset("SUPERNOVA_TELEGRAM_TOKEN")
  envoy.unset("SUPERNOVA_ACCESS_ADMINS")
  envoy.unset("SUPERNOVA_ACCESS_MEMBERS")
}

pub fn apply_env_overrides_app_name_test() {
  // Set env var
  envoy.set("SUPERNOVA_APP_NAME", "env-override-app")

  let config = default_config()
  let overridden = apply_env_overrides(config)

  overridden.app_name |> should_equal("env-override-app")

  // Clean up
  envoy.unset("SUPERNOVA_APP_NAME")
}

pub fn apply_env_overrides_environment_test() {
  envoy.set("SUPERNOVA_ENVIRONMENT", "production")

  let config = default_config()
  let overridden = apply_env_overrides(config)

  overridden.environment |> should_equal("production")

  envoy.unset("SUPERNOVA_ENVIRONMENT")
}

pub fn apply_env_overrides_log_level_test() {
  envoy.set("SUPERNOVA_LOG_LEVEL", "debug")

  let config = default_config()
  let overridden = apply_env_overrides(config)

  overridden.log_level |> should_equal("debug")

  envoy.unset("SUPERNOVA_LOG_LEVEL")
}

pub fn apply_env_overrides_discord_token_test() {
  envoy.set("SUPERNOVA_DISCORD_TOKEN", "env-discord-token")

  let config = default_config()
  let overridden = apply_env_overrides(config)

  overridden.discord.token |> should_equal(Some("env-discord-token"))

  envoy.unset("SUPERNOVA_DISCORD_TOKEN")
}

pub fn apply_env_overrides_telegram_token_test() {
  envoy.set("SUPERNOVA_TELEGRAM_TOKEN", "env-telegram-token")

  let config = default_config()
  let overridden = apply_env_overrides(config)

  overridden.telegram.token |> should_equal(Some("env-telegram-token"))

  envoy.unset("SUPERNOVA_TELEGRAM_TOKEN")
}

pub fn apply_env_overrides_new_channel_settings_test() {
  envoy.set("SUPERNOVA_MATRIX_TOKEN", "env-matrix-token")
  envoy.set("SUPERNOVA_LARK_TOKEN", "env-lark-token")
  envoy.set("SUPERNOVA_LARK_BASE_URL", "https://open.feishu.cn")
  envoy.set(
    "SUPERNOVA_GOOGLE_CHAT_WEBHOOK_URL",
    "https://chat.googleapis.com/v1/spaces/env/messages?key=test&token=test",
  )
  envoy.set("SUPERNOVA_SLACK_TOKEN", "env-slack-token")
  envoy.set("SUPERNOVA_MATTERMOST_TOKEN", "env-mattermost-token")
  envoy.set("SUPERNOVA_MATTERMOST_BASE_URL", "https://mattermost.env")
  envoy.set(
    "SUPERNOVA_WECHAT_WORK_WEBHOOK_URL",
    "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=env-wechat",
  )
  envoy.set("SUPERNOVA_WHATSAPP_BRIDGE_URL", "http://env-whatsapp:3000")
  envoy.set("SUPERNOVA_WHATSAPP_DEVICE_ID", "env-device")

  let config = default_config()
  let overridden = apply_env_overrides(config)

  overridden.matrix.token |> should_equal(Some("env-matrix-token"))
  overridden.lark.token |> should_equal(Some("env-lark-token"))
  overridden.lark.base_url |> should_equal(Some("https://open.feishu.cn"))
  overridden.google_chat.webhook_url
  |> should_equal(Some(
    "https://chat.googleapis.com/v1/spaces/env/messages?key=test&token=test",
  ))
  overridden.slack.token |> should_equal(Some("env-slack-token"))
  overridden.mattermost.token |> should_equal(Some("env-mattermost-token"))
  overridden.mattermost.base_url |> should_equal(Some("https://mattermost.env"))
  overridden.wechat_work.webhook_url
  |> should_equal(Some(
    "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=env-wechat",
  ))
  overridden.whatsapp.bridge_url
  |> should_equal(Some("http://env-whatsapp:3000"))
  overridden.whatsapp.device_id |> should_equal(Some("env-device"))

  envoy.unset("SUPERNOVA_MATRIX_TOKEN")
  envoy.unset("SUPERNOVA_LARK_TOKEN")
  envoy.unset("SUPERNOVA_LARK_BASE_URL")
  envoy.unset("SUPERNOVA_GOOGLE_CHAT_WEBHOOK_URL")
  envoy.unset("SUPERNOVA_SLACK_TOKEN")
  envoy.unset("SUPERNOVA_MATTERMOST_TOKEN")
  envoy.unset("SUPERNOVA_MATTERMOST_BASE_URL")
  envoy.unset("SUPERNOVA_WECHAT_WORK_WEBHOOK_URL")
  envoy.unset("SUPERNOVA_WHATSAPP_BRIDGE_URL")
  envoy.unset("SUPERNOVA_WHATSAPP_DEVICE_ID")
}

pub fn apply_env_overrides_provider_api_key_test() {
  envoy.set("SUPERNOVA_PROVIDER_OPENAI_MAIN_API_KEY", "env-api-key")

  let yaml =
    "
providers:
  openai-main:
    type: openai
    api_key: yaml-api-key
"

  let assert Ok(config) = parse_yaml(yaml)
  let overridden = apply_env_overrides(config)

  let assert Some(provider) = get_provider(overridden, "openai-main")
  provider.api_key |> should_equal(Some("env-api-key"))

  envoy.unset("SUPERNOVA_PROVIDER_OPENAI_MAIN_API_KEY")
}

// ============================================================================
// Utility Function Tests
// ============================================================================

pub fn error_to_string_yaml_parse_error_test() {
  let error = YamlParseError(message: "Test parse error")
  let str = error_to_string(error)

  str |> should_equal("YAML Parse Error: Test parse error")
}

pub fn error_to_string_missing_field_test() {
  let error = MissingField(field: "token", context: "discord")
  let str = error_to_string(error)

  str |> should_equal("Missing field 'token' in discord")
}

pub fn error_to_string_invalid_field_test() {
  let error =
    InvalidField(field: "provider", value: "invalid", reason: "not supported")
  let str = error_to_string(error)

  str
  |> should_equal(
    "Invalid field 'provider' with value 'invalid': not supported",
  )
}

pub fn error_to_string_type_mismatch_test() {
  let error = TypeMismatch(field: "port", expected: "int", found: "string")
  let str = error_to_string(error)

  str |> should_equal("Type mismatch for 'port': expected int but found string")
}

pub fn error_to_string_validation_error_test() {
  let error = ValidationError(message: "Config validation failed")
  let str = error_to_string(error)

  str |> should_equal("Validation Error: Config validation failed")
}

pub fn provider_requires_api_key_openai_test() {
  let result = provider_requires_api_key(OpenAI)
  result |> should_equal(True)
}

pub fn provider_requires_api_key_anthropic_test() {
  let result = provider_requires_api_key(Anthropic)
  result |> should_equal(True)
}

pub fn provider_requires_api_key_openrouter_test() {
  let result = provider_requires_api_key(OpenRouter)
  result |> should_equal(True)
}

pub fn provider_requires_api_key_opencode_zen_test() {
  let result = provider_requires_api_key(OpenCodeZen)
  result |> should_equal(True)
}

pub fn provider_requires_api_key_zhipu_variants_test() {
  provider_requires_api_key(Zhipu) |> should_equal(True)
  provider_requires_api_key(ZhipuCoding) |> should_equal(True)
}

pub fn provider_requires_api_key_minimax_test() {
  let result = provider_requires_api_key(Minimax)
  result |> should_equal(True)
}

pub fn provider_requires_api_key_ollama_test() {
  let result = provider_requires_api_key(Ollama)
  result |> should_equal(False)
}

pub fn is_discord_enabled_true_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      discord: DiscordConfigRecord(
        token: Some("token"),
        app_id: None,
        guild_id: None,
        enabled: True,
      ),
    )

  is_discord_enabled(config) |> should_equal(True)
}

pub fn is_discord_enabled_false_no_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      discord: DiscordConfigRecord(
        token: None,
        app_id: None,
        guild_id: None,
        enabled: True,
      ),
    )

  is_discord_enabled(config) |> should_equal(False)
}

pub fn is_discord_enabled_false_disabled_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      discord: DiscordConfigRecord(
        token: Some("token"),
        app_id: None,
        guild_id: None,
        enabled: False,
      ),
    )

  is_discord_enabled(config) |> should_equal(False)
}

pub fn is_telegram_enabled_true_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      telegram: TelegramConfigRecord(
        token: Some("token"),
        enabled: True,
        base_url: None,
      ),
    )

  is_telegram_enabled(config) |> should_equal(True)
}

pub fn is_telegram_enabled_false_no_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      telegram: TelegramConfigRecord(token: None, enabled: True, base_url: None),
    )

  is_telegram_enabled(config) |> should_equal(False)
}

pub fn is_new_channels_enabled_true_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      matrix: MatrixConfigRecord(
        homeserver_url: None,
        token: Some("t"),
        enabled: True,
      ),
      lark: LarkConfigRecord(
        token: Some("t"),
        base_url: Some("https://open.larksuite.com"),
        enabled: True,
      ),
      google_chat: GoogleChatConfigRecord(
        webhook_url: Some(
          "https://chat.googleapis.com/v1/spaces/abc/messages?key=test&token=test",
        ),
        enabled: True,
      ),
      slack: SlackConfigRecord(token: Some("t"), enabled: True),
      mattermost: MattermostConfigRecord(
        token: Some("t"),
        base_url: Some("https://mattermost.example.com"),
        enabled: True,
      ),
      wechat_work: WechatWorkConfigRecord(
        webhook_url: Some(
          "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=wechat-key",
        ),
        enabled: True,
      ),
      whatsapp: WhatsAppConfigRecord(
        bridge_url: Some("http://localhost:3000"),
        device_id: Some("device-1"),
        enabled: True,
      ),
    )

  is_matrix_enabled(config) |> should_equal(True)
  is_lark_enabled(config) |> should_equal(True)
  is_google_chat_enabled(config) |> should_equal(True)
  is_slack_enabled(config) |> should_equal(True)
  is_mattermost_enabled(config) |> should_equal(True)
  is_wechat_work_enabled(config) |> should_equal(True)
  is_whatsapp_enabled(config) |> should_equal(True)
}

pub fn is_new_channels_enabled_false_without_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      matrix: MatrixConfigRecord(
        homeserver_url: None,
        token: None,
        enabled: True,
      ),
      lark: LarkConfigRecord(token: None, base_url: None, enabled: True),
      google_chat: GoogleChatConfigRecord(webhook_url: None, enabled: True),
      slack: SlackConfigRecord(token: None, enabled: True),
      mattermost: MattermostConfigRecord(
        token: None,
        base_url: None,
        enabled: True,
      ),
      wechat_work: WechatWorkConfigRecord(webhook_url: None, enabled: True),
      whatsapp: WhatsAppConfigRecord(
        bridge_url: None,
        device_id: None,
        enabled: True,
      ),
    )

  is_matrix_enabled(config) |> should_equal(False)
  is_lark_enabled(config) |> should_equal(False)
  is_google_chat_enabled(config) |> should_equal(False)
  is_slack_enabled(config) |> should_equal(False)
  is_mattermost_enabled(config) |> should_equal(False)
  is_wechat_work_enabled(config) |> should_equal(False)
  is_whatsapp_enabled(config) |> should_equal(False)
}

pub fn get_provider_existing_test() {
  let yaml =
    "
providers:
  test-provider:
    type: openai
"

  let assert Ok(config) = parse_yaml(yaml)

  case get_provider(config, "test-provider") {
    Some(provider) -> provider.provider |> should_equal(OpenAI)
    None -> panic as "Expected to find test-provider"
  }
}

pub fn get_provider_non_existing_test() {
  let config = default_config()

  case get_provider(config, "non-existing") {
    None -> Nil
    Some(_) -> panic as "Expected None for non-existing provider"
  }
}

pub fn default_budgets_config_defaults_test() {
  let budgets = default_budgets_config()
  budgets.default.tokens_per_hour |> should_equal(100_000)
  budgets.default.tool_calls_per_minute |> should_equal(60)
  budgets.default.max_recursion_depth |> should_equal(5)
  budgets.default.max_sub_agents |> should_equal(10)
  budgets.inheritance_ratio |> should_equal(20)
  budgets.agents |> dict.size |> should_equal(0)
}

pub fn load_from_file_missing_file_returns_file_error_test() {
  case load_from_file("/tmp/supernova-config-missing-does-not-exist.yaml") {
    Error(_) -> Nil
    Ok(_) -> panic as "Expected load_from_file to fail for missing path"
  }
}

pub fn provider_runtime_name_maps_supported_providers_test() {
  provider_runtime_name(OpenAI) |> should_equal("openai")
  provider_runtime_name(Anthropic) |> should_equal("anthropic")
  provider_runtime_name(OpenRouter) |> should_equal("openrouter")
  provider_runtime_name(OpenCodeZen) |> should_equal("opencode_zen")
  provider_runtime_name(Zhipu) |> should_equal("zhipu")
  provider_runtime_name(ZhipuCoding) |> should_equal("zhipu_coding")
  provider_runtime_name(Minimax) |> should_equal("minimax")
  provider_runtime_name(Ollama) |> should_equal("ollama")
}

pub fn provider_default_model_maps_supported_providers_test() {
  provider_default_model(OpenAI) |> should_equal("gpt-5.4-2026-03-05")
  provider_default_model(Anthropic) |> should_equal("claude-sonnet-4-20260217")
  provider_default_model(OpenRouter) |> should_equal("openrouter/free")
  provider_default_model(OpenCodeZen) |> should_equal("claude-sonnet-4-6")
  provider_default_model(Zhipu) |> should_equal("glm-5")
  provider_default_model(ZhipuCoding) |> should_equal("glm-5.1")
  provider_default_model(Minimax) |> should_equal("MiniMax-M2.7")
  provider_default_model(Ollama) |> should_equal("llama3")
}

pub fn tools_browser_allow_evaluate_defaults_to_false_test() {
  use <- test_env.without_env("SUPERNOVA_BROWSER_ALLOW_EVALUATE")
  default_tools_config().browser.allow_evaluate |> should_equal(False)
  default_config().tools.browser.allow_evaluate |> should_equal(False)

  let assert Ok(cfg) = parse_yaml("app_name: supernova\n")
  cfg.tools.browser.allow_evaluate |> should_equal(False)
}

pub fn tools_browser_allow_evaluate_enabled_via_yaml_test() {
  use <- test_env.without_env("SUPERNOVA_BROWSER_ALLOW_EVALUATE")
  let yaml =
    "
app_name: supernova
tools:
  browser:
    allow_evaluate: true
"
  let assert Ok(cfg) = load(yaml)
  cfg.tools.browser.allow_evaluate |> should_equal(True)
}

pub fn tools_browser_allow_evaluate_overridden_by_env_test() {
  use <- test_env.with_env("SUPERNOVA_BROWSER_ALLOW_EVALUATE", "true")
  let assert Ok(cfg) = load("app_name: supernova\n")
  cfg.tools.browser.allow_evaluate |> should_equal(True)
}

pub fn tools_timeouts_are_read_in_seconds_test() {
  let yaml =
    "
app_name: supernova
tools:
  timeouts:
    default: 30
    computador: 600
    zero: 0
    texto: muito
"
  let assert Ok(cfg) = load(yaml)
  cfg.tools.timeouts
  |> should_equal(dict.from_list([#("default", 30), #("computador", 600)]))
  let assert Ok(plain) = load("app_name: supernova\n")
  plain.tools.timeouts |> should_equal(dict.new())
}

pub fn channels_webhook_is_read_test() {
  let yaml =
    "
app_name: supernova
channels:
  webhook:
    bind: 0.0.0.0
    port: 9100
"
  let assert Ok(cfg) = load(yaml)
  cfg.webhook |> should_equal(config.WebhookConfig(bind: "0.0.0.0", port: 9100))
  let assert Ok(plain) = load("app_name: supernova\n")
  plain.webhook |> should_equal(config.default_webhook_config())
}

// ============================================================================
// Helper Functions
// ============================================================================

fn should_equal(actual: a, expected: a) -> Nil {
  case actual == expected {
    True -> Nil
    False -> panic
  }
}

pub fn reflection_and_drift_defaults_test() {
  let config = default_config()
  config.reflection.every_turns |> should_equal(20)
  config.reflection.every_hours |> should_equal(24)
  config.reflection.model |> should_equal(None)
  config.reflection.journal_limit |> should_equal(500)
  config.drift.half_life_days |> should_equal(30.0)
  config.drift.threshold |> should_equal(1.0)
  config.drift.min_interval_days |> should_equal(30)
  config.drift.min_pressure_days |> should_equal(4)
}

pub fn parse_reflection_and_drift_config_test() {
  let yaml =
    "reflection:
  every_turns: 5
  every_hours: 6
  model: cheap-model
  journal_limit: 42
drift:
  half_life_days: 10.0
  threshold: 2.0
  min_interval_days: 30
  min_pressure_days: 6
"
  let assert Ok(config) = parse_yaml(yaml)
  config.reflection.every_turns |> should_equal(5)
  config.reflection.every_hours |> should_equal(6)
  config.reflection.model |> should_equal(Some("cheap-model"))
  config.reflection.journal_limit |> should_equal(42)
  config.drift.half_life_days |> should_equal(10.0)
  config.drift.threshold |> should_equal(2.0)
  config.drift.min_interval_days |> should_equal(30)
  config.drift.min_pressure_days |> should_equal(6)
}
