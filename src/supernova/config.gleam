//// Configuration system for Supernova
//// Provides YAML-based configuration with environment variable overrides
//// and validation on startup.
////
//// This module provides:
//// - YAML parsing from supernova.yaml files
//// - Environment variable overrides for sensitive values
//// - Schema validation with clear error messages
//// - Support for routed providers (OpenAI, Anthropic, OpenRouter,
////   OpenCode Zen, Zhipu, Minimax, Ollama)
//// - Discord and Telegram bot configuration
//// - Database configuration

import envoy
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import yay

// ============================================================================
// Types
// ============================================================================

/// Supported LLM providers
pub type Provider {
  /// OpenAI API (GPT models)
  OpenAI
  /// Anthropic API (Claude models)
  Anthropic
  /// OpenRouter gateway
  OpenRouter
  /// OpenCode Zen gateway
  OpenCodeZen
  /// Zhipu general chat endpoint
  Zhipu
  /// Zhipu coding endpoint
  ZhipuCoding
  /// MiniMax chat endpoint
  Minimax
  /// Local/self-hosted Ollama
  Ollama
}

/// Provider configuration
pub type ProviderConfig {
  ProviderConfig(
    /// Provider type
    provider: Provider,
    /// API key for authentication
    api_key: Option(String),
    /// Base URL override (optional)
    base_url: Option(String),
    /// Model to use
    model: Option(String),
    /// Request timeout in milliseconds
    timeout_ms: Int,
  )
}

/// Discord bot configuration
pub type DiscordConfig {
  DiscordConfig(
    /// Bot token
    token: Option(String),
    /// Application ID
    app_id: Option(String),
    /// Guild ID for development server
    guild_id: Option(String),
    /// Enabled status
    enabled: Bool,
  )
}

/// Telegram bot configuration
pub type TelegramConfig {
  TelegramConfig(
    /// Bot token
    token: Option(String),
    /// Enabled status
    enabled: Bool,
  )
}

/// Matrix channel configuration
pub type MatrixConfig {
  MatrixConfig(
    /// Matrix homeserver URL (e.g. https://matrix.org)
    homeserver_url: Option(String),
    /// Bot access token
    token: Option(String),
    /// Enabled status
    enabled: Bool,
  )
}

/// Lark channel configuration
pub type LarkConfig {
  LarkConfig(
    /// Tenant access token / credential
    token: Option(String),
    /// Optional Open API base URL override
    base_url: Option(String),
    /// Enabled status
    enabled: Bool,
  )
}

/// Google Chat channel configuration
pub type GoogleChatConfig {
  GoogleChatConfig(
    /// Incoming webhook URL used to post messages
    webhook_url: Option(String),
    /// Enabled status
    enabled: Bool,
  )
}

/// Slack channel configuration
pub type SlackConfig {
  SlackConfig(
    /// Bot token
    token: Option(String),
    /// Enabled status
    enabled: Bool,
  )
}

/// Mattermost channel configuration
pub type MattermostConfig {
  MattermostConfig(
    /// Access token
    token: Option(String),
    /// Mattermost instance base URL
    base_url: Option(String),
    /// Enabled status
    enabled: Bool,
  )
}

/// WeChat Work channel configuration
pub type WechatWorkConfig {
  WechatWorkConfig(
    /// Robot webhook URL for posting messages
    webhook_url: Option(String),
    /// Enabled status
    enabled: Bool,
  )
}

/// WhatsApp channel configuration
pub type WhatsAppConfig {
  WhatsAppConfig(
    /// Base URL for the Whatsmeow bridge REST API
    bridge_url: Option(String),
    /// Optional bridge device ID for multi-device deployments
    device_id: Option(String),
    /// Enabled status
    enabled: Bool,
  )
}

/// Database configuration
pub type DatabaseConfig {
  DatabaseConfig(
    /// Database URL (connection string)
    url: Option(String),
    /// Database host
    host: String,
    /// Database port
    port: Int,
    /// Database name
    database: String,
    /// Database user
    user: Option(String),
    /// Database password
    password: Option(String),
    /// Connection pool size
    pool_size: Int,
  )
}

/// Budget configuration for an agent
pub type BudgetConfigYaml {
  BudgetConfigYaml(
    /// Maximum LLM tokens per hour (-1 = unlimited)
    tokens_per_hour: Int,
    /// Maximum tool calls per minute (-1 = unlimited)
    tool_calls_per_minute: Int,
    /// Maximum recursion depth for sub-agents
    max_recursion_depth: Int,
    /// Maximum number of concurrent sub-agents
    max_sub_agents: Int,
  )
}

/// Budgets section configuration
pub type BudgetsConfig {
  BudgetsConfig(
    /// Default budget for agents without explicit config
    default: BudgetConfigYaml,
    /// Inheritance ratio for sub-agents (percentage of parent, e.g., 20)
    inheritance_ratio: Int,
    /// Per-agent budget overrides
    agents: Dict(String, BudgetConfigYaml),
  )
}

/// Main application configuration
pub type Config {
  Config(
    /// Application name
    app_name: String,
    /// Application environment (development, staging, production)
    environment: String,
    /// Log level (debug, info, warn, error)
    log_level: String,
    /// Provider configurations by name
    providers: Dict(String, ProviderConfig),
    /// Discord configuration
    discord: DiscordConfig,
    /// Telegram configuration
    telegram: TelegramConfig,
    /// Matrix configuration
    matrix: MatrixConfig,
    /// Lark configuration
    lark: LarkConfig,
    /// Google Chat configuration
    google_chat: GoogleChatConfig,
    /// Slack configuration
    slack: SlackConfig,
    /// Mattermost configuration
    mattermost: MattermostConfig,
    /// WeChat Work configuration
    wechat_work: WechatWorkConfig,
    /// WhatsApp configuration
    whatsapp: WhatsAppConfig,
    /// Database configuration
    database: DatabaseConfig,
    /// Budget configuration
    budgets: BudgetsConfig,
  )
}

/// Configuration error type
pub type ConfigError {
  /// YAML parsing error
  YamlParseError(message: String)
  /// Missing required field
  MissingField(field: String, context: String)
  /// Invalid field value
  InvalidField(field: String, value: String, reason: String)
  /// Type mismatch
  TypeMismatch(field: String, expected: String, found: String)
  /// Validation error
  ValidationError(message: String)
  /// File read error
  FileError(message: String)
}

// ============================================================================
// Default Values
// ============================================================================

/// Create a default configuration
pub fn default_config() -> Config {
  Config(
    app_name: "supernova",
    environment: "development",
    log_level: "info",
    providers: dict.new(),
    discord: DiscordConfig(
      token: None,
      app_id: None,
      guild_id: None,
      enabled: False,
    ),
    telegram: TelegramConfig(token: None, enabled: False),
    matrix: MatrixConfig(homeserver_url: None, token: None, enabled: False),
    lark: LarkConfig(token: None, base_url: None, enabled: False),
    google_chat: GoogleChatConfig(webhook_url: None, enabled: False),
    slack: SlackConfig(token: None, enabled: False),
    mattermost: MattermostConfig(token: None, base_url: None, enabled: False),
    wechat_work: WechatWorkConfig(webhook_url: None, enabled: False),
    whatsapp: WhatsAppConfig(bridge_url: None, device_id: None, enabled: False),
    database: DatabaseConfig(
      url: None,
      host: "localhost",
      port: 5432,
      database: "supernova",
      user: None,
      password: None,
      pool_size: 10,
    ),
    budgets: default_budgets_config(),
  )
}

/// Create a default budgets configuration
pub fn default_budgets_config() -> BudgetsConfig {
  BudgetsConfig(
    default: BudgetConfigYaml(
      tokens_per_hour: 100_000,
      tool_calls_per_minute: 60,
      max_recursion_depth: 5,
      max_sub_agents: 10,
    ),
    inheritance_ratio: 20,
    agents: dict.new(),
  )
}

/// Create a default provider configuration
pub fn default_provider_config(provider: Provider) -> ProviderConfig {
  ProviderConfig(
    provider: provider,
    api_key: None,
    base_url: None,
    model: None,
    timeout_ms: 30_000,
  )
}

// ============================================================================
// YAML Parsing Helpers
// ============================================================================

/// Parse provider type from string
fn parse_provider(s: String) -> Result(Provider, ConfigError) {
  case string.lowercase(s) {
    "openai" -> Ok(OpenAI)
    "anthropic" -> Ok(Anthropic)
    "openrouter" -> Ok(OpenRouter)
    "opencode_zen" -> Ok(OpenCodeZen)
    "zhipu" -> Ok(Zhipu)
    "zhipu_coding" -> Ok(ZhipuCoding)
    "minimax" -> Ok(Minimax)
    "ollama" | "local" -> Ok(Ollama)
    _ ->
      Error(InvalidField(
        "provider",
        s,
        "must be openai, anthropic, openrouter, opencode_zen, zhipu, zhipu_coding, minimax, or ollama",
      ))
  }
}

/// Parse log level from string
fn parse_log_level(s: String) -> Result(String, ConfigError) {
  let lower = string.lowercase(s)
  case lower {
    "debug" | "info" | "warn" | "error" -> Ok(lower)
    _ ->
      Error(InvalidField("log_level", s, "must be debug, info, warn, or error"))
  }
}

/// Parse environment from string
fn parse_environment(s: String) -> Result(String, ConfigError) {
  let lower = string.lowercase(s)
  case lower {
    "development" | "staging" | "production" | "test" -> Ok(lower)
    _ ->
      Error(InvalidField(
        "environment",
        s,
        "must be development, staging, production, or test",
      ))
  }
}

/// Convert yay extraction error to ConfigError
fn to_config_error(e: yay.ExtractionError, context: String) -> ConfigError {
  case e {
    yay.KeyMissing(key, _) -> MissingField(key, context)
    yay.KeyValueEmpty(key) -> InvalidField(key, "", "value is empty")
    yay.KeyTypeMismatch(key, expected, found) ->
      TypeMismatch(context <> "." <> key, expected, found)
    yay.DuplicateKeysDetected(key, _) ->
      InvalidField(key, "", "duplicate key detected")
  }
}

/// Get a string from a node, with default if missing
fn get_string_or(node: yay.Node, key: String, default: String) -> String {
  case yay.extract_string_or(node, key, default) {
    Ok(value) -> value
    Error(_) -> default
  }
}

/// Get an int from a node, with default if missing
fn get_int_or(node: yay.Node, key: String, default: Int) -> Int {
  case yay.extract_int_or(node, key, default) {
    Ok(value) -> value
    Error(_) -> default
  }
}

/// Get a bool from a node, with default if missing
fn get_bool_or(node: yay.Node, key: String, default: Bool) -> Bool {
  case yay.extract_bool_or(node, key, default) {
    Ok(value) -> value
    Error(_) -> default
  }
}

/// Get an optional string from a node
fn get_optional_string(node: yay.Node, key: String) -> Option(String) {
  case yay.extract_optional_string(node, key) {
    Ok(Some(value)) -> Some(value)
    _ -> None
  }
}

/// Convert a Node to a string key
fn node_to_string_key(node: yay.Node) -> Option(String) {
  case node {
    yay.NodeStr(s) -> Some(s)
    _ -> None
  }
}

// ============================================================================
// YAML Decoding
// ============================================================================

/// Decode a provider configuration from YAML node
fn decode_provider_config(
  node: yay.Node,
  name: String,
) -> Result(ProviderConfig, ConfigError) {
  use provider_str <- result.try(extract_provider_name(node, name))

  use provider <- result.try(parse_provider(provider_str))

  let api_key = get_optional_string(node, "api_key")
  let base_url = get_optional_string(node, "base_url")
  let model = get_optional_string(node, "model")
  let timeout_ms = get_int_or(node, "timeout_ms", 30_000)

  Ok(ProviderConfig(
    provider: provider,
    api_key: api_key,
    base_url: base_url,
    model: model,
    timeout_ms: timeout_ms,
  ))
}

fn extract_provider_name(
  node: yay.Node,
  name: String,
) -> Result(String, ConfigError) {
  let context = "providers." <> name

  case yay.extract_string(node, "provider") {
    Ok(value) -> Ok(value)
    Error(yay.KeyMissing(_, _)) ->
      case yay.extract_string(node, "type") {
        Ok(value) -> Ok(value)
        Error(yay.KeyMissing(_, _)) -> Error(MissingField("provider", context))
        Error(e) -> Error(to_config_error(e, context))
      }
    Error(e) -> Error(to_config_error(e, context))
  }
}

/// Decode providers section from YAML
fn decode_providers(
  root: yay.Node,
) -> Result(Dict(String, ProviderConfig), ConfigError) {
  // Try to get the providers map node
  case yay.select_sugar(root, "providers") {
    Ok(yay.NodeMap(pairs)) -> decode_provider_pairs(pairs, [])
    _ -> Ok(dict.new())
  }
}

fn decode_provider_pairs(
  pairs: List(#(yay.Node, yay.Node)),
  acc: List(#(String, ProviderConfig)),
) -> Result(Dict(String, ProviderConfig), ConfigError) {
  case pairs {
    [] -> Ok(acc |> list.reverse |> dict.from_list)
    [pair, ..rest] -> {
      let #(key_node, value_node) = pair
      case node_to_string_key(key_node) {
        Some(name) -> {
          use config <- result.try(decode_provider_config(value_node, name))
          decode_provider_pairs(rest, [#(name, config), ..acc])
        }
        None -> decode_provider_pairs(rest, acc)
      }
    }
  }
}

/// Decode Discord configuration from YAML
fn decode_discord(root: yay.Node) -> DiscordConfig {
  case yay.select_sugar(root, "discord") {
    Ok(discord_node) -> {
      DiscordConfig(
        token: get_optional_string(discord_node, "token"),
        app_id: get_optional_string(discord_node, "app_id"),
        guild_id: get_optional_string(discord_node, "guild_id"),
        enabled: get_bool_or(discord_node, "enabled", False),
      )
    }
    Error(_) ->
      DiscordConfig(token: None, app_id: None, guild_id: None, enabled: False)
  }
}

/// Decode Telegram configuration from YAML
fn decode_telegram(root: yay.Node) -> TelegramConfig {
  case yay.select_sugar(root, "telegram") {
    Ok(telegram_node) -> {
      TelegramConfig(
        token: get_optional_string(telegram_node, "token"),
        enabled: get_bool_or(telegram_node, "enabled", False),
      )
    }
    Error(_) -> TelegramConfig(token: None, enabled: False)
  }
}

/// Decode Matrix configuration from YAML
fn decode_matrix(root: yay.Node) -> MatrixConfig {
  case yay.select_sugar(root, "matrix") {
    Ok(node) ->
      MatrixConfig(
        homeserver_url: get_optional_string(node, "homeserver_url"),
        token: get_optional_string(node, "token"),
        enabled: get_bool_or(node, "enabled", False),
      )
    Error(_) -> MatrixConfig(homeserver_url: None, token: None, enabled: False)
  }
}

/// Decode Lark configuration from YAML
fn decode_lark(root: yay.Node) -> LarkConfig {
  case yay.select_sugar(root, "lark") {
    Ok(node) ->
      LarkConfig(
        token: get_optional_string(node, "token"),
        base_url: get_optional_string(node, "base_url"),
        enabled: get_bool_or(node, "enabled", False),
      )
    Error(_) -> LarkConfig(token: None, base_url: None, enabled: False)
  }
}

/// Decode Google Chat configuration from YAML
fn decode_google_chat(root: yay.Node) -> GoogleChatConfig {
  case yay.select_sugar(root, "google_chat") {
    Ok(node) ->
      GoogleChatConfig(
        webhook_url: get_optional_string(node, "webhook_url"),
        enabled: get_bool_or(node, "enabled", False),
      )
    Error(_) -> GoogleChatConfig(webhook_url: None, enabled: False)
  }
}

/// Decode Slack configuration from YAML
fn decode_slack(root: yay.Node) -> SlackConfig {
  case yay.select_sugar(root, "slack") {
    Ok(node) ->
      SlackConfig(
        token: get_optional_string(node, "token"),
        enabled: get_bool_or(node, "enabled", False),
      )
    Error(_) -> SlackConfig(token: None, enabled: False)
  }
}

/// Decode Mattermost configuration from YAML
fn decode_mattermost(root: yay.Node) -> MattermostConfig {
  case yay.select_sugar(root, "mattermost") {
    Ok(node) ->
      MattermostConfig(
        token: get_optional_string(node, "token"),
        base_url: get_optional_string(node, "base_url"),
        enabled: get_bool_or(node, "enabled", False),
      )
    Error(_) -> MattermostConfig(token: None, base_url: None, enabled: False)
  }
}

/// Decode WeChat Work configuration from YAML
fn decode_wechat_work(root: yay.Node) -> WechatWorkConfig {
  case yay.select_sugar(root, "wechat_work") {
    Ok(node) ->
      WechatWorkConfig(
        webhook_url: get_optional_string(node, "webhook_url"),
        enabled: get_bool_or(node, "enabled", False),
      )
    Error(_) -> WechatWorkConfig(webhook_url: None, enabled: False)
  }
}

/// Decode WhatsApp configuration from YAML
fn decode_whatsapp(root: yay.Node) -> WhatsAppConfig {
  case yay.select_sugar(root, "whatsapp") {
    Ok(node) ->
      WhatsAppConfig(
        bridge_url: get_optional_string(node, "bridge_url"),
        device_id: get_optional_string(node, "device_id"),
        enabled: get_bool_or(node, "enabled", False),
      )
    Error(_) ->
      WhatsAppConfig(bridge_url: None, device_id: None, enabled: False)
  }
}

/// Decode Database configuration from YAML
fn decode_database(root: yay.Node) -> DatabaseConfig {
  case yay.select_sugar(root, "database") {
    Ok(db_node) -> {
      DatabaseConfig(
        url: get_optional_string(db_node, "url"),
        host: get_string_or(db_node, "host", "localhost"),
        port: get_int_or(db_node, "port", 5432),
        database: get_string_or(db_node, "database", "supernova"),
        user: get_optional_string(db_node, "user"),
        password: get_optional_string(db_node, "password"),
        pool_size: get_int_or(db_node, "pool_size", 10),
      )
    }
    Error(_) ->
      DatabaseConfig(
        url: None,
        host: "localhost",
        port: 5432,
        database: "supernova",
        user: None,
        password: None,
        pool_size: 10,
      )
  }
}

/// Decode a single budget config from YAML node
fn decode_budget_config(node: yay.Node) -> BudgetConfigYaml {
  BudgetConfigYaml(
    tokens_per_hour: get_int_or(node, "tokens_per_hour", 100_000),
    tool_calls_per_minute: get_int_or(node, "tool_calls_per_minute", 60),
    max_recursion_depth: get_int_or(node, "max_recursion_depth", 5),
    max_sub_agents: get_int_or(node, "max_sub_agents", 10),
  )
}

/// Decode Budgets configuration from YAML
fn decode_budgets(root: yay.Node) -> BudgetsConfig {
  case yay.select_sugar(root, "budgets") {
    Ok(budgets_node) -> {
      // Decode default budget
      let default_config = case yay.select_sugar(budgets_node, "default") {
        Ok(default_node) -> decode_budget_config(default_node)
        Error(_) ->
          BudgetConfigYaml(
            tokens_per_hour: 100_000,
            tool_calls_per_minute: 60,
            max_recursion_depth: 5,
            max_sub_agents: 10,
          )
      }

      // Decode inheritance ratio
      let inheritance_ratio = get_int_or(budgets_node, "inheritance_ratio", 20)

      // Decode per-agent overrides
      let agents = case yay.select_sugar(budgets_node, "agents") {
        Ok(yay.NodeMap(pairs)) ->
          pairs
          |> list.filter(fn(pair) {
            let #(key_node, _value_node) = pair
            case node_to_string_key(key_node) {
              Some(_) -> True
              None -> False
            }
          })
          |> list.map(fn(pair) {
            let #(key_node, value_node) = pair
            let assert Some(name) = node_to_string_key(key_node)
            #(name, decode_budget_config(value_node))
          })
          |> dict.from_list
        _ -> dict.new()
      }

      BudgetsConfig(
        default: default_config,
        inheritance_ratio: inheritance_ratio,
        agents: agents,
      )
    }
    Error(_) -> default_budgets_config()
  }
}

/// Decode full configuration from YAML root node
fn decode_config(root: yay.Node) -> Result(Config, ConfigError) {
  // Parse app_name (optional, defaults to "supernova")
  let app_name = get_string_or(root, "app_name", "supernova")

  // Parse environment (optional, defaults to "development")
  let environment = get_string_or(root, "environment", "development")
  use environment <- result.try(parse_environment(environment))

  // Parse log_level (optional, defaults to "info")
  let log_level = get_string_or(root, "log_level", "info")
  use log_level <- result.try(parse_log_level(log_level))

  // Parse providers
  use providers <- result.try(decode_providers(root))

  // Parse discord
  let discord = decode_discord(root)

  // Parse telegram
  let telegram = decode_telegram(root)

  // Parse additional channels
  let matrix = decode_matrix(root)
  let lark = decode_lark(root)
  let google_chat = decode_google_chat(root)
  let slack = decode_slack(root)
  let mattermost = decode_mattermost(root)
  let wechat_work = decode_wechat_work(root)
  let whatsapp = decode_whatsapp(root)

  // Parse database
  let database = decode_database(root)

  // Parse budgets
  let budgets = decode_budgets(root)

  Ok(Config(
    app_name: app_name,
    environment: environment,
    log_level: log_level,
    providers: providers,
    discord: discord,
    telegram: telegram,
    matrix: matrix,
    lark: lark,
    google_chat: google_chat,
    slack: slack,
    mattermost: mattermost,
    wechat_work: wechat_work,
    whatsapp: whatsapp,
    database: database,
    budgets: budgets,
  ))
}

/// Convert yay YAML error to ConfigError
fn convert_yaml_error(e: yay.YamlError) -> ConfigError {
  case e {
    yay.UnexpectedParsingError -> YamlParseError("Unexpected parsing error")
    yay.ParsingError(msg, loc) -> {
      // Extract line and column from YamlErrorLoc
      let yay.YamlErrorLoc(line: line, column: column) = loc
      YamlParseError(
        msg
        <> " at line "
        <> int.to_string(line)
        <> ", column "
        <> int.to_string(column),
      )
    }
  }
}

// ============================================================================
// Public YAML Parsing API
// ============================================================================

/// Parse configuration from YAML string
pub fn parse_yaml(yaml_string: String) -> Result(Config, ConfigError) {
  case yay.parse_string(yaml_string) {
    Ok([doc]) -> {
      let root = yay.document_root(doc)
      decode_config(root)
    }
    Ok(docs) ->
      Error(YamlParseError(
        "Expected 1 YAML document, got " <> int.to_string(list.length(docs)),
      ))
    Error(e) -> Error(convert_yaml_error(e))
  }
}

// ============================================================================
// Environment Variable Overrides
// ============================================================================

/// Get environment variable value
fn get_env(key: String) -> Option(String) {
  case envoy.get(key) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

/// Apply environment variable overrides to configuration
pub fn apply_env_overrides(config: Config) -> Config {
  // App-level overrides
  let app_name = option.unwrap(get_env("SUPERNOVA_APP_NAME"), config.app_name)

  let environment =
    option.unwrap(get_env("SUPERNOVA_ENVIRONMENT"), config.environment)

  let log_level =
    option.unwrap(get_env("SUPERNOVA_LOG_LEVEL"), config.log_level)

  // Discord overrides
  let discord_token =
    option.or(get_env("SUPERNOVA_DISCORD_TOKEN"), config.discord.token)
  let discord_app_id =
    option.or(get_env("SUPERNOVA_DISCORD_APP_ID"), config.discord.app_id)
  let discord_enabled = case get_env("SUPERNOVA_DISCORD_ENABLED") {
    Some("true") -> True
    Some("false") -> False
    _ -> config.discord.enabled
  }

  // Telegram overrides
  let telegram_token =
    option.or(get_env("SUPERNOVA_TELEGRAM_TOKEN"), config.telegram.token)
  let telegram_enabled = case get_env("SUPERNOVA_TELEGRAM_ENABLED") {
    Some("true") -> True
    Some("false") -> False
    _ -> config.telegram.enabled
  }

  // Additional channel overrides
  let matrix_homeserver_url =
    option.or(
      get_env("SUPERNOVA_MATRIX_HOMESERVER_URL"),
      config.matrix.homeserver_url,
    )
  let matrix_token =
    option.or(get_env("SUPERNOVA_MATRIX_TOKEN"), config.matrix.token)
  let matrix_enabled = case get_env("SUPERNOVA_MATRIX_ENABLED") {
    Some("true") -> True
    Some("false") -> False
    _ -> config.matrix.enabled
  }

  let lark_token = option.or(get_env("SUPERNOVA_LARK_TOKEN"), config.lark.token)
  let lark_base_url =
    option.or(get_env("SUPERNOVA_LARK_BASE_URL"), config.lark.base_url)
  let lark_enabled = case get_env("SUPERNOVA_LARK_ENABLED") {
    Some("true") -> True
    Some("false") -> False
    _ -> config.lark.enabled
  }

  let google_chat_webhook_url =
    option.or(
      get_env("SUPERNOVA_GOOGLE_CHAT_WEBHOOK_URL"),
      config.google_chat.webhook_url,
    )
  let google_chat_enabled = case get_env("SUPERNOVA_GOOGLE_CHAT_ENABLED") {
    Some("true") -> True
    Some("false") -> False
    _ -> config.google_chat.enabled
  }

  let slack_token =
    option.or(get_env("SUPERNOVA_SLACK_TOKEN"), config.slack.token)
  let slack_enabled = case get_env("SUPERNOVA_SLACK_ENABLED") {
    Some("true") -> True
    Some("false") -> False
    _ -> config.slack.enabled
  }

  let mattermost_token =
    option.or(get_env("SUPERNOVA_MATTERMOST_TOKEN"), config.mattermost.token)
  let mattermost_base_url =
    option.or(
      get_env("SUPERNOVA_MATTERMOST_BASE_URL"),
      config.mattermost.base_url,
    )
  let mattermost_enabled = case get_env("SUPERNOVA_MATTERMOST_ENABLED") {
    Some("true") -> True
    Some("false") -> False
    _ -> config.mattermost.enabled
  }

  let wechat_work_webhook_url =
    option.or(
      get_env("SUPERNOVA_WECHAT_WORK_WEBHOOK_URL"),
      config.wechat_work.webhook_url,
    )
  let wechat_work_enabled = case get_env("SUPERNOVA_WECHAT_WORK_ENABLED") {
    Some("true") -> True
    Some("false") -> False
    _ -> config.wechat_work.enabled
  }

  let whatsapp_bridge_url =
    option.or(
      get_env("SUPERNOVA_WHATSAPP_BRIDGE_URL"),
      config.whatsapp.bridge_url,
    )
  let whatsapp_device_id =
    option.or(
      get_env("SUPERNOVA_WHATSAPP_DEVICE_ID"),
      config.whatsapp.device_id,
    )
  let whatsapp_enabled = case get_env("SUPERNOVA_WHATSAPP_ENABLED") {
    Some("true") -> True
    Some("false") -> False
    _ -> config.whatsapp.enabled
  }

  // Database overrides
  let db_url = option.or(get_env("SUPERNOVA_DATABASE_URL"), config.database.url)
  let db_host =
    option.unwrap(get_env("SUPERNOVA_DATABASE_HOST"), config.database.host)
  let db_port = case get_env("SUPERNOVA_DATABASE_PORT") {
    Some(value) ->
      case int.parse(value) {
        Ok(port) -> port
        Error(_) -> config.database.port
      }
    None -> config.database.port
  }
  let db_name =
    option.unwrap(get_env("SUPERNOVA_DATABASE_NAME"), config.database.database)
  let db_user =
    option.or(get_env("SUPERNOVA_DATABASE_USER"), config.database.user)
  let db_password =
    option.or(get_env("SUPERNOVA_DATABASE_PASSWORD"), config.database.password)
  let db_pool_size = case get_env("SUPERNOVA_DATABASE_POOL_SIZE") {
    Some(value) ->
      case int.parse(value) {
        Ok(size) -> size
        Error(_) -> config.database.pool_size
      }
    None -> config.database.pool_size
  }

  // Provider API key overrides (for each provider in config)
  let providers = apply_provider_env_overrides(config.providers)

  Config(
    app_name: app_name,
    environment: environment,
    log_level: log_level,
    providers: providers,
    discord: DiscordConfig(
      token: discord_token,
      app_id: discord_app_id,
      guild_id: config.discord.guild_id,
      enabled: discord_enabled,
    ),
    telegram: TelegramConfig(token: telegram_token, enabled: telegram_enabled),
    matrix: MatrixConfig(
      homeserver_url: matrix_homeserver_url,
      token: matrix_token,
      enabled: matrix_enabled,
    ),
    lark: LarkConfig(
      token: lark_token,
      base_url: lark_base_url,
      enabled: lark_enabled,
    ),
    google_chat: GoogleChatConfig(
      webhook_url: google_chat_webhook_url,
      enabled: google_chat_enabled,
    ),
    slack: SlackConfig(token: slack_token, enabled: slack_enabled),
    mattermost: MattermostConfig(
      token: mattermost_token,
      base_url: mattermost_base_url,
      enabled: mattermost_enabled,
    ),
    wechat_work: WechatWorkConfig(
      webhook_url: wechat_work_webhook_url,
      enabled: wechat_work_enabled,
    ),
    whatsapp: WhatsAppConfig(
      bridge_url: whatsapp_bridge_url,
      device_id: whatsapp_device_id,
      enabled: whatsapp_enabled,
    ),
    database: DatabaseConfig(
      url: db_url,
      host: db_host,
      port: db_port,
      database: db_name,
      user: db_user,
      password: db_password,
      pool_size: db_pool_size,
    ),
    budgets: config.budgets,
  )
}

/// Apply environment variable overrides to provider configurations
fn apply_provider_env_overrides(
  providers: Dict(String, ProviderConfig),
) -> Dict(String, ProviderConfig) {
  providers
  |> dict.to_list
  |> list.map(fn(pair) {
    let #(name, config) = pair
    // Provider-specific env var: SUPERNOVA_PROVIDER_{NAME}_API_KEY
    let env_name = string.uppercase(name) |> string.replace("-", "_")
    let env_key = "SUPERNOVA_PROVIDER_" <> env_name <> "_API_KEY"

    let api_key = option.or(get_env(env_key), config.api_key)

    #(name, ProviderConfig(..config, api_key: api_key))
  })
  |> dict.from_list
}

// ============================================================================
// Validation
// ============================================================================

/// Validate the configuration
pub fn validate(config: Config) -> Result(Nil, ConfigError) {
  // Validate environment
  use _ <- result.try(
    parse_environment(config.environment)
    |> result.replace_error(InvalidField(
      "environment",
      config.environment,
      "must be development, staging, production, or test",
    )),
  )

  // Validate log level
  use _ <- result.try(
    parse_log_level(config.log_level)
    |> result.replace_error(InvalidField(
      "log_level",
      config.log_level,
      "must be debug, info, warn, or error",
    )),
  )

  // Validate Discord config if enabled
  use _ <- result.try(validate_discord(config.discord))

  // Validate Telegram config if enabled
  use _ <- result.try(validate_telegram(config.telegram))

  // Validate additional channel configs if enabled
  use _ <- result.try(validate_matrix(config.matrix))
  use _ <- result.try(validate_lark(config.lark))
  use _ <- result.try(validate_google_chat(config.google_chat))
  use _ <- result.try(validate_slack(config.slack))
  use _ <- result.try(validate_mattermost(config.mattermost))
  use _ <- result.try(validate_wechat_work(config.wechat_work))
  use _ <- result.try(validate_whatsapp(config.whatsapp))

  // Validate database configuration
  use _ <- result.try(validate_database(config.database))

  // Validate provider configurations
  use _ <- result.try(validate_providers(config.providers))

  Ok(Nil)
}

/// Validate Discord configuration
fn validate_discord(config: DiscordConfig) -> Result(Nil, ConfigError) {
  case config.enabled {
    True -> {
      case config.token {
        Some(_) -> Ok(Nil)
        None ->
          Error(ValidationError("Discord is enabled but no token is configured"))
      }
    }
    False -> Ok(Nil)
  }
}

/// Validate Telegram configuration
fn validate_telegram(config: TelegramConfig) -> Result(Nil, ConfigError) {
  case config.enabled {
    True -> {
      case config.token {
        Some(_) -> Ok(Nil)
        None ->
          Error(ValidationError(
            "Telegram is enabled but no token is configured",
          ))
      }
    }
    False -> Ok(Nil)
  }
}

fn validate_matrix(config: MatrixConfig) -> Result(Nil, ConfigError) {
  case config.enabled {
    True ->
      case config.token {
        Some(_) -> Ok(Nil)
        None ->
          Error(ValidationError("Matrix is enabled but no token is configured"))
      }
    False -> Ok(Nil)
  }
}

fn validate_lark(config: LarkConfig) -> Result(Nil, ConfigError) {
  case config.enabled {
    True ->
      case config.token {
        Some(_) -> Ok(Nil)
        None ->
          Error(ValidationError("Lark is enabled but no token is configured"))
      }
    False -> Ok(Nil)
  }
}

fn validate_google_chat(config: GoogleChatConfig) -> Result(Nil, ConfigError) {
  case config.enabled {
    True ->
      case config.webhook_url {
        Some(_) -> Ok(Nil)
        None ->
          Error(ValidationError(
            "Google Chat is enabled but no webhook_url is configured",
          ))
      }
    False -> Ok(Nil)
  }
}

fn validate_slack(config: SlackConfig) -> Result(Nil, ConfigError) {
  case config.enabled {
    True ->
      case config.token {
        Some(_) -> Ok(Nil)
        None ->
          Error(ValidationError("Slack is enabled but no token is configured"))
      }
    False -> Ok(Nil)
  }
}

fn validate_mattermost(config: MattermostConfig) -> Result(Nil, ConfigError) {
  case config.enabled {
    True ->
      case config.token {
        Some(_) ->
          case config.base_url {
            Some(_) -> Ok(Nil)
            None ->
              Error(ValidationError(
                "Mattermost is enabled but no base_url is configured",
              ))
          }
        None ->
          Error(ValidationError(
            "Mattermost is enabled but no token is configured",
          ))
      }
    False -> Ok(Nil)
  }
}

fn validate_wechat_work(config: WechatWorkConfig) -> Result(Nil, ConfigError) {
  case config.enabled {
    True ->
      case config.webhook_url {
        Some(_) -> Ok(Nil)
        None ->
          Error(ValidationError(
            "WeChat Work is enabled but no webhook_url is configured",
          ))
      }
    False -> Ok(Nil)
  }
}

fn validate_whatsapp(config: WhatsAppConfig) -> Result(Nil, ConfigError) {
  case config.enabled {
    True ->
      case config.bridge_url {
        Some(_) -> Ok(Nil)
        None ->
          Error(ValidationError(
            "WhatsApp is enabled but no bridge_url is configured",
          ))
      }
    False -> Ok(Nil)
  }
}

/// Validate database configuration
fn validate_database(config: DatabaseConfig) -> Result(Nil, ConfigError) {
  case config.pool_size > 0 {
    True -> Ok(Nil)
    False -> Error(ValidationError("Database pool_size must be greater than 0"))
  }
}

/// Validate all provider configurations
fn validate_providers(
  providers: Dict(String, ProviderConfig),
) -> Result(Nil, ConfigError) {
  providers
  |> dict.to_list
  |> list.each(fn(pair) {
    let #(name, config) = pair
    let _ = validate_provider_config(name, config)
    Nil
  })

  Ok(Nil)
}

/// Validate a provider configuration
fn validate_provider_config(name: String, config: ProviderConfig) {
  case config.provider {
    OpenAI -> {
      case config.api_key {
        Some(_) -> Nil
        None -> {
          // Log warning - in production this would be logged
          let _ = "OpenAI provider '" <> name <> "' requires an API key"
          Nil
        }
      }
    }
    Anthropic -> {
      case config.api_key {
        Some(_) -> Nil
        None -> {
          let _ = "Anthropic provider '" <> name <> "' requires an API key"
          Nil
        }
      }
    }
    OpenRouter -> {
      case config.api_key {
        Some(_) -> Nil
        None -> {
          let _ = "OpenRouter provider '" <> name <> "' requires an API key"
          Nil
        }
      }
    }
    OpenCodeZen -> {
      case config.api_key {
        Some(_) -> Nil
        None -> {
          let _ = "OpenCode Zen provider '" <> name <> "' requires an API key"
          Nil
        }
      }
    }
    Zhipu | ZhipuCoding -> {
      case config.api_key {
        Some(_) -> Nil
        None -> {
          let _ = "Zhipu provider '" <> name <> "' requires an API key"
          Nil
        }
      }
    }
    Minimax -> {
      case config.api_key {
        Some(_) -> Nil
        None -> {
          let _ = "MiniMax provider '" <> name <> "' requires an API key"
          Nil
        }
      }
    }
    Ollama -> Nil
  }
}

// ============================================================================
// Main Loading Functions
// ============================================================================

/// Load and validate configuration from YAML string with env overrides
pub fn load(yaml_string: String) -> Result(Config, ConfigError) {
  use config <- result.try(parse_yaml(yaml_string))

  let config_with_env = apply_env_overrides(config)

  use _ <- result.try(validate(config_with_env))

  Ok(config_with_env)
}

/// Load configuration from file path
pub fn load_from_file(path: String) -> Result(Config, ConfigError) {
  case yay.parse_file(path) {
    Ok([doc]) -> {
      let root = yay.document_root(doc)
      use config <- result.try(decode_config(root))

      let config_with_env = apply_env_overrides(config)

      use _ <- result.try(validate(config_with_env))

      Ok(config_with_env)
    }
    Ok(docs) ->
      Error(YamlParseError(
        "Expected 1 YAML document, got " <> int.to_string(list.length(docs)),
      ))
    Error(e) -> Error(convert_yaml_error(e))
  }
}

/// Load configuration from YAML string without validation
/// Useful for debugging or when validation should be deferred
pub fn load_unsafe(yaml_string: String) -> Result(Config, ConfigError) {
  use config <- result.try(parse_yaml(yaml_string))
  let config_with_env = apply_env_overrides(config)
  Ok(config_with_env)
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Format configuration error to a human-readable string
pub fn error_to_string(error: ConfigError) -> String {
  case error {
    YamlParseError(message) -> "YAML Parse Error: " <> message
    MissingField(field, context) ->
      "Missing field '" <> field <> "' in " <> context
    InvalidField(field, value, reason) ->
      "Invalid field '" <> field <> "' with value '" <> value <> "': " <> reason
    TypeMismatch(field, expected, found) ->
      "Type mismatch for '"
      <> field
      <> "': expected "
      <> expected
      <> " but found "
      <> found
    ValidationError(message) -> "Validation Error: " <> message
    FileError(message) -> "File Error: " <> message
  }
}

/// Check if a provider requires an API key
pub fn provider_requires_api_key(provider: Provider) -> Bool {
  case provider {
    OpenAI -> True
    Anthropic -> True
    OpenRouter -> True
    OpenCodeZen -> True
    Zhipu -> True
    ZhipuCoding -> True
    Minimax -> True
    Ollama -> False
  }
}

/// Convert config provider enum to runtime dispatcher name.
pub fn provider_runtime_name(provider: Provider) -> String {
  case provider {
    OpenAI -> "openai"
    Anthropic -> "anthropic"
    OpenRouter -> "openrouter"
    OpenCodeZen -> "opencode_zen"
    Zhipu -> "zhipu"
    ZhipuCoding -> "zhipu_coding"
    Minimax -> "minimax"
    Ollama -> "ollama"
  }
}

/// Default model used when a config provider omits `model`.
pub fn provider_default_model(provider: Provider) -> String {
  case provider {
    OpenAI -> "gpt-4o"
    Anthropic -> "claude-sonnet-4-20250514"
    OpenRouter -> "anthropic/claude-haiku-4-5"
    OpenCodeZen -> "claude-sonnet-4-6"
    Zhipu -> "glm-4-plus"
    ZhipuCoding -> "codegeex-4"
    Minimax -> "MiniMax-Text-01"
    Ollama -> "llama3"
  }
}

/// Get provider by name from configuration
pub fn get_provider(config: Config, name: String) -> Option(ProviderConfig) {
  case dict.get(config.providers, name) {
    Ok(config) -> Some(config)
    Error(_) -> None
  }
}

/// Check if Discord is configured and enabled
pub fn is_discord_enabled(config: Config) -> Bool {
  config.discord.enabled && config.discord.token != None
}

/// Check if Telegram is configured and enabled
pub fn is_telegram_enabled(config: Config) -> Bool {
  config.telegram.enabled && config.telegram.token != None
}

/// Check if Matrix is configured and enabled
pub fn is_matrix_enabled(config: Config) -> Bool {
  config.matrix.enabled && config.matrix.token != None
}

/// Check if Lark is configured and enabled
pub fn is_lark_enabled(config: Config) -> Bool {
  config.lark.enabled && config.lark.token != None
}

/// Check if Google Chat is configured and enabled
pub fn is_google_chat_enabled(config: Config) -> Bool {
  config.google_chat.enabled && config.google_chat.webhook_url != None
}

/// Check if Slack is configured and enabled
pub fn is_slack_enabled(config: Config) -> Bool {
  config.slack.enabled && config.slack.token != None
}

/// Check if Mattermost is configured and enabled
pub fn is_mattermost_enabled(config: Config) -> Bool {
  config.mattermost.enabled
  && config.mattermost.token != None
  && config.mattermost.base_url != None
}

/// Check if WeChat Work is configured and enabled
pub fn is_wechat_work_enabled(config: Config) -> Bool {
  config.wechat_work.enabled && config.wechat_work.webhook_url != None
}

/// Check if WhatsApp is configured and enabled
pub fn is_whatsapp_enabled(config: Config) -> Bool {
  config.whatsapp.enabled && config.whatsapp.bridge_url != None
}
