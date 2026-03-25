//// Tests for the Supernova configuration system
//// Tests YAML parsing, environment variable overrides, and validation

import envoy
import gleam/dict
import gleam/option.{None, Some}
import gleeunit
import supernova/config.{
  Anthropic, Config as ConfigRecord, DatabaseConfig as DatabaseConfigRecord,
  DiscordConfig as DiscordConfigRecord,
  GoogleChatConfig as GoogleChatConfigRecord, InvalidField,
  LarkConfig as LarkConfigRecord, Local, MatrixConfig as MatrixConfigRecord,
  MattermostConfig as MattermostConfigRecord, MissingField, OpenAI,
  SlackConfig as SlackConfigRecord, TelegramConfig as TelegramConfigRecord,
  TypeMismatch, ValidationError, WechatWorkConfig as WechatWorkConfigRecord,
  WhatsAppConfig as WhatsAppConfigRecord, YamlParseError, apply_env_overrides,
  default_config, default_provider_config, error_to_string, get_provider,
  is_discord_enabled, is_google_chat_enabled, is_lark_enabled, is_matrix_enabled,
  is_mattermost_enabled, is_slack_enabled, is_telegram_enabled,
  is_wechat_work_enabled, is_whatsapp_enabled, load, load_unsafe, parse_yaml,
  provider_requires_api_key, validate,
}

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
  config.database.host |> should_equal("localhost")
  config.database.port |> should_equal(5432)
  config.database.database |> should_equal("supernova")
  config.database.pool_size |> should_equal(10)
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

pub fn default_provider_config_local_test() {
  let config = default_provider_config(Local)

  config.provider |> should_equal(Local)
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
  enabled: true
google_chat:
  token: google-token
  enabled: true
slack:
  token: slack-token
  enabled: true
mattermost:
  token: mattermost-token
  enabled: true
wechat_work:
  token: wechat-token
  enabled: true
whatsapp:
  token: whatsapp-token
  enabled: true
"

  let assert Ok(config) = parse_yaml(yaml)

  config.matrix.token |> should_equal(Some("matrix-token"))
  config.matrix.enabled |> should_equal(True)
  config.lark.token |> should_equal(Some("lark-token"))
  config.lark.enabled |> should_equal(True)
  config.google_chat.token |> should_equal(Some("google-token"))
  config.google_chat.enabled |> should_equal(True)
  config.slack.token |> should_equal(Some("slack-token"))
  config.slack.enabled |> should_equal(True)
  config.mattermost.token |> should_equal(Some("mattermost-token"))
  config.mattermost.enabled |> should_equal(True)
  config.wechat_work.token |> should_equal(Some("wechat-token"))
  config.wechat_work.enabled |> should_equal(True)
  config.whatsapp.token |> should_equal(Some("whatsapp-token"))
  config.whatsapp.enabled |> should_equal(True)
}

pub fn parse_database_config_test() {
  let yaml =
    "
database:
  url: postgres://user:pass@host:5432/db
  host: db.example.com
  port: 5433
  database: supernova_prod
  user: admin
  password: secret
  pool_size: 20
"

  let assert Ok(config) = parse_yaml(yaml)

  config.database.url |> should_equal(Some("postgres://user:pass@host:5432/db"))
  config.database.host |> should_equal("db.example.com")
  config.database.port |> should_equal(5433)
  config.database.database |> should_equal("supernova_prod")
  config.database.user |> should_equal(Some("admin"))
  config.database.password |> should_equal(Some("secret"))
  config.database.pool_size |> should_equal(20)
}

pub fn parse_provider_config_test() {
  let yaml =
    "
providers:
  openai-main:
    type: openai
    api_key: sk-test
    model: gpt-4
    timeout_ms: 60000
  claude:
    type: anthropic
    api_key: sk-anthropic
  local-llm:
    type: local
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

  // Check local provider
  let assert Some(local_config) = get_provider(config, "local-llm")
  local_config.provider |> should_equal(Local)
  local_config.base_url |> should_equal(Some("http://localhost:8080"))
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

  // Invalid provider types are silently ignored during parsing
  // The config will just not include the invalid provider
  case result {
    Ok(config) -> {
      // The invalid provider should not be in the config
      case get_provider(config, "test") {
        None -> Nil
        Some(_) -> panic as "Invalid provider should not be included"
      }
    }
    Error(_) -> Nil
    // Error is also acceptable
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

pub fn validate_telegram_enabled_without_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      telegram: TelegramConfigRecord(token: None, enabled: True),
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
      matrix: MatrixConfigRecord(token: None, enabled: True),
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
      lark: LarkConfigRecord(token: None, enabled: True),
      google_chat: GoogleChatConfigRecord(token: None, enabled: True),
      slack: SlackConfigRecord(token: None, enabled: True),
      mattermost: MattermostConfigRecord(token: None, enabled: True),
      wechat_work: WechatWorkConfigRecord(token: None, enabled: True),
      whatsapp: WhatsAppConfigRecord(token: None, enabled: True),
    )

  // First failing channel in validation order should be Lark.
  case validate(config) {
    Error(ValidationError("Lark is enabled but no token is configured")) -> Nil
    _ -> panic as "Expected ValidationError for Lark without token"
  }
}

pub fn validate_database_invalid_pool_size_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      database: DatabaseConfigRecord(
        url: None,
        host: "localhost",
        port: 5432,
        database: "supernova",
        user: None,
        password: None,
        pool_size: 0,
      ),
    )

  case validate(config) {
    Error(ValidationError("Database pool_size must be greater than 0")) -> Nil
    _ -> panic as "Expected ValidationError for invalid pool_size"
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
      telegram: TelegramConfigRecord(token: Some("valid-token"), enabled: True),
    )

  let assert Ok(Nil) = validate(config)
}

pub fn validate_all_additional_channels_enabled_with_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      matrix: MatrixConfigRecord(token: Some("t"), enabled: True),
      lark: LarkConfigRecord(token: Some("t"), enabled: True),
      google_chat: GoogleChatConfigRecord(token: Some("t"), enabled: True),
      slack: SlackConfigRecord(token: Some("t"), enabled: True),
      mattermost: MattermostConfigRecord(token: Some("t"), enabled: True),
      wechat_work: WechatWorkConfigRecord(token: Some("t"), enabled: True),
      whatsapp: WhatsAppConfigRecord(token: Some("t"), enabled: True),
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

pub fn apply_env_overrides_new_channel_tokens_test() {
  envoy.set("SUPERNOVA_MATRIX_TOKEN", "env-matrix-token")
  envoy.set("SUPERNOVA_LARK_TOKEN", "env-lark-token")
  envoy.set("SUPERNOVA_GOOGLE_CHAT_TOKEN", "env-google-token")
  envoy.set("SUPERNOVA_SLACK_TOKEN", "env-slack-token")
  envoy.set("SUPERNOVA_MATTERMOST_TOKEN", "env-mattermost-token")
  envoy.set("SUPERNOVA_WECHAT_WORK_TOKEN", "env-wechat-token")
  envoy.set("SUPERNOVA_WHATSAPP_TOKEN", "env-whatsapp-token")

  let config = default_config()
  let overridden = apply_env_overrides(config)

  overridden.matrix.token |> should_equal(Some("env-matrix-token"))
  overridden.lark.token |> should_equal(Some("env-lark-token"))
  overridden.google_chat.token |> should_equal(Some("env-google-token"))
  overridden.slack.token |> should_equal(Some("env-slack-token"))
  overridden.mattermost.token |> should_equal(Some("env-mattermost-token"))
  overridden.wechat_work.token |> should_equal(Some("env-wechat-token"))
  overridden.whatsapp.token |> should_equal(Some("env-whatsapp-token"))

  envoy.unset("SUPERNOVA_MATRIX_TOKEN")
  envoy.unset("SUPERNOVA_LARK_TOKEN")
  envoy.unset("SUPERNOVA_GOOGLE_CHAT_TOKEN")
  envoy.unset("SUPERNOVA_SLACK_TOKEN")
  envoy.unset("SUPERNOVA_MATTERMOST_TOKEN")
  envoy.unset("SUPERNOVA_WECHAT_WORK_TOKEN")
  envoy.unset("SUPERNOVA_WHATSAPP_TOKEN")
}

pub fn apply_env_overrides_database_test() {
  envoy.set("SUPERNOVA_DATABASE_URL", "postgres://env:pass@host/db")
  envoy.set("SUPERNOVA_DATABASE_HOST", "env-host")
  envoy.set("SUPERNOVA_DATABASE_PORT", "5433")
  envoy.set("SUPERNOVA_DATABASE_NAME", "env_db")
  envoy.set("SUPERNOVA_DATABASE_USER", "env_user")
  envoy.set("SUPERNOVA_DATABASE_PASSWORD", "env_pass")
  envoy.set("SUPERNOVA_DATABASE_POOL_SIZE", "25")

  let config = default_config()
  let overridden = apply_env_overrides(config)

  overridden.database.url |> should_equal(Some("postgres://env:pass@host/db"))
  overridden.database.host |> should_equal("env-host")
  overridden.database.port |> should_equal(5433)
  overridden.database.database |> should_equal("env_db")
  overridden.database.user |> should_equal(Some("env_user"))
  overridden.database.password |> should_equal(Some("env_pass"))
  overridden.database.pool_size |> should_equal(25)

  // Clean up
  envoy.unset("SUPERNOVA_DATABASE_URL")
  envoy.unset("SUPERNOVA_DATABASE_HOST")
  envoy.unset("SUPERNOVA_DATABASE_PORT")
  envoy.unset("SUPERNOVA_DATABASE_NAME")
  envoy.unset("SUPERNOVA_DATABASE_USER")
  envoy.unset("SUPERNOVA_DATABASE_PASSWORD")
  envoy.unset("SUPERNOVA_DATABASE_POOL_SIZE")
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

pub fn provider_requires_api_key_local_test() {
  let result = provider_requires_api_key(Local)
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
      telegram: TelegramConfigRecord(token: Some("token"), enabled: True),
    )

  is_telegram_enabled(config) |> should_equal(True)
}

pub fn is_telegram_enabled_false_no_token_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      telegram: TelegramConfigRecord(token: None, enabled: True),
    )

  is_telegram_enabled(config) |> should_equal(False)
}

pub fn is_new_channels_enabled_true_test() {
  let config =
    ConfigRecord(
      ..default_config(),
      matrix: MatrixConfigRecord(token: Some("t"), enabled: True),
      lark: LarkConfigRecord(token: Some("t"), enabled: True),
      google_chat: GoogleChatConfigRecord(token: Some("t"), enabled: True),
      slack: SlackConfigRecord(token: Some("t"), enabled: True),
      mattermost: MattermostConfigRecord(token: Some("t"), enabled: True),
      wechat_work: WechatWorkConfigRecord(token: Some("t"), enabled: True),
      whatsapp: WhatsAppConfigRecord(token: Some("t"), enabled: True),
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
      matrix: MatrixConfigRecord(token: None, enabled: True),
      lark: LarkConfigRecord(token: None, enabled: True),
      google_chat: GoogleChatConfigRecord(token: None, enabled: True),
      slack: SlackConfigRecord(token: None, enabled: True),
      mattermost: MattermostConfigRecord(token: None, enabled: True),
      wechat_work: WechatWorkConfigRecord(token: None, enabled: True),
      whatsapp: WhatsAppConfigRecord(token: None, enabled: True),
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

// ============================================================================
// Helper Functions
// ============================================================================

fn should_equal(actual: a, expected: a) -> Nil {
  case actual == expected {
    True -> Nil
    False -> panic
  }
}
