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
  /// Z.AI platform (智谱AI new platform, z.ai)
  Zai
  /// Z.AI coding plan
  ZaiCoding
  /// Mistral API (OpenAI-compatible), which also serves DeepSeek models
  Mistral
  /// Deterministic mock provider (tests and CI harness)
  Mock
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

/// HTTP-driven sim channel configuration.
pub type SimConfig {
  SimConfig(
    enabled: Bool,
    bind: String,
    port: Int,
    token: Option(String),
    record_prompts: Bool,
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

/// Access policy mode for the closed group.
pub type AccessMode {
  /// Only principals explicitly listed as admins or members may use the bot.
  Allowlist
  /// Anyone may use the bot (still subject to budgets and capabilities).
  Open
}

/// Closed-group access configuration.
pub type AccessConfig {
  AccessConfig(
    /// Allowlist (default) or open.
    mode: AccessMode,
    /// Admin principals in `<channel>:<user_id>` form.
    admins: List(String),
    /// Member principals in `<channel>:<user_id>` form.
    members: List(String),
    /// Reply sent at most once per day to denied principals.
    denied_reply: String,
    /// Authorized group chats / guilds in `<channel>:<id>` form.
    /// Private conversations with authorized principals are always allowed.
    allowed_chats: List(String),
  )
}

/// Per-role budget limits. `-1` means unlimited.
pub type RoleBudgetConfig {
  RoleBudgetConfig(tokens_per_hour: Int, tool_calls_per_hour: Int)
}

/// Budget section grouped by role.
pub type RoleBudgetsConfig {
  RoleBudgetsConfig(member: RoleBudgetConfig, admin: RoleBudgetConfig)
}

/// Per-role capability (tool) manifest configuration.
pub type RoleCapabilitiesConfig {
  RoleCapabilitiesConfig(allowed: List(String), denied: List(String))
}

/// Capabilities section grouped by role.
pub type CapabilitiesConfig {
  CapabilitiesConfig(
    member: RoleCapabilitiesConfig,
    admin: RoleCapabilitiesConfig,
  )
}

/// Per-role message rate limit. `-1` means unlimited.
pub type RoleRateLimitConfig {
  RoleRateLimitConfig(messages_per_minute: Int)
}

/// Anti-flood configuration grouped by role.
pub type RateLimitConfig {
  RateLimitConfig(member: RoleRateLimitConfig, admin: RoleRateLimitConfig)
}

/// USD price per one million tokens for a model.
pub type PricingEntry {
  PricingEntry(input_per_mtok: Float, output_per_mtok: Float)
}

/// Model pricing table used to estimate LLM spend.
pub type PricingConfig {
  PricingConfig(default: PricingEntry, models: Dict(String, PricingEntry))
}

/// Instance-wide daily spend cap.
pub type InstanceBudgetConfig {
  InstanceBudgetConfig(
    daily_usd: Float,
    timezone: String,
    reserve_output_tokens: Int,
  )
}

pub type ReflectionConfig {
  ReflectionConfig(
    every_turns: Int,
    every_hours: Int,
    model: Option(String),
    journal_limit: Int,
  )
}

pub type DriftConfig {
  DriftConfig(
    half_life_days: Float,
    threshold: Float,
    min_interval_days: Int,
    /// Distinct days with pressure in the same direction, within one half
    /// life, before a change. One strong push is never enough.
    min_pressure_days: Int,
  )
}

/// Support level for a channel adapter.
pub type ChannelSupport {
  Supported
  Experimental
}

/// Browser tool configuration
pub type BrowserToolsConfig {
  BrowserToolsConfig(
    /// Allow arbitrary JS evaluation via browser evaluate (disabled by default)
    allow_evaluate: Bool,
  )
}

/// Tools configuration section
pub type ToolsConfig {
  ToolsConfig(
    /// Browser tool configuration
    browser: BrowserToolsConfig,
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
    /// HTTP-driven sim channel configuration
    sim: SimConfig,
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
    /// Closed-group access policy
    access: AccessConfig,
    /// Per-role budget limits (tokens and tool calls per hour)
    role_budgets: RoleBudgetsConfig,
    /// Per-role tool capabilities
    capabilities: CapabilitiesConfig,
    /// Per-role anti-flood limits
    rate_limit: RateLimitConfig,
    /// Model pricing used for cost estimates
    pricing: PricingConfig,
    /// Instance-wide daily spend cap
    instance_budget: InstanceBudgetConfig,
    /// Periodic reflection configuration
    reflection: ReflectionConfig,
    /// Slow trait drift configuration
    drift: DriftConfig,
    /// Writable directory for runtime state (access.json, ledger/)
    data_dir: String,
    /// Tools configuration
    tools: ToolsConfig,
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
    sim: SimConfig(
      enabled: False,
      bind: "127.0.0.1",
      port: 8787,
      token: None,
      record_prompts: False,
    ),
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
    access: default_access_config(),
    role_budgets: default_role_budgets_config(),
    capabilities: default_capabilities_config(),
    rate_limit: default_rate_limit_config(),
    pricing: default_pricing_config(),
    instance_budget: default_instance_budget_config(),
    reflection: default_reflection_config(),
    drift: default_drift_config(),
    data_dir: "data",
    tools: default_tools_config(),
  )
}

/// Closed-group defaults: deny everyone until explicitly configured.
pub fn default_access_config() -> AccessConfig {
  AccessConfig(
    mode: Allowlist,
    admins: [],
    members: [],
    denied_reply: "Esta instância é privada.",
    allowed_chats: [],
  )
}

pub fn default_role_budgets_config() -> RoleBudgetsConfig {
  RoleBudgetsConfig(
    // 200k: a reasoning model uses ~4k tokens per turn; 50k allowed about
    // 12 messages an hour (maintainer decision after the first battery).
    member: RoleBudgetConfig(tokens_per_hour: 200_000, tool_calls_per_hour: 60),
    admin: RoleBudgetConfig(tokens_per_hour: -1, tool_calls_per_hour: -1),
  )
}

pub fn default_capabilities_config() -> CapabilitiesConfig {
  CapabilitiesConfig(
    member: RoleCapabilitiesConfig(
      allowed: ["web", "web_fetch", "file_system", "canvas", "github"],
      denied: ["safe_shell", "process", "browser", "gateway"],
    ),
    admin: RoleCapabilitiesConfig(allowed: ["*"], denied: []),
  )
}

pub fn default_rate_limit_config() -> RateLimitConfig {
  RateLimitConfig(
    member: RoleRateLimitConfig(messages_per_minute: 10),
    admin: RoleRateLimitConfig(messages_per_minute: -1),
  )
}

pub fn default_pricing_config() -> PricingConfig {
  PricingConfig(
    default: PricingEntry(input_per_mtok: 1.0, output_per_mtok: 4.0),
    models: dict.new(),
  )
}

pub fn default_instance_budget_config() -> InstanceBudgetConfig {
  InstanceBudgetConfig(
    daily_usd: 5.0,
    timezone: "America/Sao_Paulo",
    reserve_output_tokens: 1000,
  )
}

/// Create a default tools configuration
pub fn default_reflection_config() -> ReflectionConfig {
  ReflectionConfig(
    every_turns: 20,
    every_hours: 24,
    model: None,
    journal_limit: 500,
  )
}

pub fn default_drift_config() -> DriftConfig {
  // A month of steady living is enough for a nudge (maintainer decision): a
  // weekly pressure of 0.25 crosses 1.0 in about five weeks.
  DriftConfig(
    half_life_days: 30.0,
    threshold: 1.0,
    min_interval_days: 30,
    min_pressure_days: 4,
  )
}

pub fn default_tools_config() -> ToolsConfig {
  ToolsConfig(browser: BrowserToolsConfig(allow_evaluate: False))
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
    "zai" -> Ok(Zai)
    "zai_coding" -> Ok(ZaiCoding)
    "mistral" -> Ok(Mistral)
    "mock" -> Ok(Mock)
    _ ->
      Error(InvalidField(
        "provider",
        s,
        "must be openai, anthropic, openrouter, opencode_zen, zhipu, zhipu_coding, minimax, ollama, zai, zai_coding, or mistral",
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
        // Provider names are also provider identifiers in the example
        // configuration (`openai:`, `anthropic:`, ...).
        Error(yay.KeyMissing(_, _)) -> Ok(name)
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

/// Decode sim configuration from `channels.sim` (or top-level `sim`).
fn decode_sim(root: yay.Node) -> SimConfig {
  let node = case yay.select_sugar(root, "channels") {
    Ok(channels) -> yay.select_sugar(channels, "sim")
    Error(_) -> yay.select_sugar(root, "sim")
  }
  case node {
    Ok(sim) ->
      SimConfig(
        enabled: get_bool_or(sim, "enabled", False),
        bind: get_string_or(sim, "bind", "127.0.0.1"),
        port: get_int_or(sim, "port", 8787),
        token: get_optional_string(sim, "token"),
        record_prompts: get_bool_or(sim, "record_prompts", False),
      )
    Error(_) ->
      SimConfig(
        enabled: False,
        bind: "127.0.0.1",
        port: 8787,
        token: None,
        record_prompts: False,
      )
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

fn get_float_or(node: yay.Node, key: String, default: Float) -> Float {
  case yay.extract_float_or(node, key, default) {
    Ok(value) -> value
    Error(_) -> default
  }
}

fn get_string_list(node: yay.Node, key: String) -> List(String) {
  case yay.extract_string_list(node, key) {
    Ok(values) -> values
    Error(_) -> []
  }
}

fn decode_access(root: yay.Node) -> AccessConfig {
  let default = default_access_config()
  case yay.select_sugar(root, "access") {
    Ok(node) -> {
      let mode = case
        string.lowercase(get_string_or(node, "mode", "allowlist"))
      {
        "open" -> Open
        _ -> Allowlist
      }
      AccessConfig(
        mode: mode,
        admins: get_string_list(node, "admins"),
        members: get_string_list(node, "members"),
        denied_reply: get_string_or(node, "denied_reply", default.denied_reply),
        allowed_chats: get_string_list(node, "allowed_chats"),
      )
    }
    Error(_) -> default
  }
}

fn decode_role_budget(
  node: yay.Node,
  default: RoleBudgetConfig,
) -> RoleBudgetConfig {
  RoleBudgetConfig(
    tokens_per_hour: get_int_or(
      node,
      "tokens_per_hour",
      default.tokens_per_hour,
    ),
    tool_calls_per_hour: get_int_or(
      node,
      "tool_calls_per_hour",
      default.tool_calls_per_hour,
    ),
  )
}

fn decode_role_budgets(root: yay.Node) -> RoleBudgetsConfig {
  let default = default_role_budgets_config()
  case yay.select_sugar(root, "budget") {
    Ok(node) -> {
      let member = case yay.select_sugar(node, "member") {
        Ok(member_node) -> decode_role_budget(member_node, default.member)
        Error(_) -> default.member
      }
      let admin = case yay.select_sugar(node, "admin") {
        Ok(admin_node) -> decode_role_budget(admin_node, default.admin)
        Error(_) -> default.admin
      }
      RoleBudgetsConfig(member: member, admin: admin)
    }
    Error(_) -> default
  }
}

fn decode_role_capabilities(
  node: yay.Node,
  default: RoleCapabilitiesConfig,
) -> RoleCapabilitiesConfig {
  RoleCapabilitiesConfig(
    allowed: case yay.extract_string_list(node, "allowed") {
      Ok(values) -> values
      Error(_) -> default.allowed
    },
    denied: case yay.extract_string_list(node, "denied") {
      Ok(values) -> values
      Error(_) -> default.denied
    },
  )
}

fn decode_capabilities(root: yay.Node) -> CapabilitiesConfig {
  let default = default_capabilities_config()
  case yay.select_sugar(root, "capabilities") {
    Ok(node) -> {
      let member = case yay.select_sugar(node, "member") {
        Ok(member_node) -> decode_role_capabilities(member_node, default.member)
        Error(_) -> default.member
      }
      let admin = case yay.select_sugar(node, "admin") {
        Ok(admin_node) -> decode_role_capabilities(admin_node, default.admin)
        Error(_) -> default.admin
      }
      CapabilitiesConfig(member: member, admin: admin)
    }
    Error(_) -> default
  }
}

fn decode_rate_limit(root: yay.Node) -> RateLimitConfig {
  let default = default_rate_limit_config()
  case yay.select_sugar(root, "rate_limit") {
    Ok(node) -> {
      let member = case yay.select_sugar(node, "member") {
        Ok(member_node) ->
          RoleRateLimitConfig(messages_per_minute: get_int_or(
            member_node,
            "messages_per_minute",
            default.member.messages_per_minute,
          ))
        Error(_) -> default.member
      }
      let admin = case yay.select_sugar(node, "admin") {
        Ok(admin_node) ->
          RoleRateLimitConfig(messages_per_minute: get_int_or(
            admin_node,
            "messages_per_minute",
            default.admin.messages_per_minute,
          ))
        Error(_) -> default.admin
      }
      RateLimitConfig(member: member, admin: admin)
    }
    Error(_) -> default
  }
}

fn decode_pricing_entry(node: yay.Node, default: PricingEntry) -> PricingEntry {
  PricingEntry(
    input_per_mtok: get_float_or(node, "input_per_mtok", default.input_per_mtok),
    output_per_mtok: get_float_or(
      node,
      "output_per_mtok",
      default.output_per_mtok,
    ),
  )
}

fn decode_pricing(root: yay.Node) -> PricingConfig {
  let default = default_pricing_config()
  case yay.select_sugar(root, "pricing") {
    Ok(node) -> {
      let default_entry = case yay.select_sugar(node, "default") {
        Ok(default_node) -> decode_pricing_entry(default_node, default.default)
        Error(_) -> default.default
      }
      let models = case yay.select_sugar(node, "models") {
        Ok(yay.NodeMap(pairs)) ->
          pairs
          |> list.filter_map(fn(pair) {
            let #(key_node, value_node) = pair
            case node_to_string_key(key_node) {
              Some(name) ->
                Ok(#(name, decode_pricing_entry(value_node, default_entry)))
              None -> Error(Nil)
            }
          })
          |> dict.from_list
        _ -> dict.new()
      }
      PricingConfig(default: default_entry, models: models)
    }
    Error(_) -> default
  }
}

fn decode_instance_budget(root: yay.Node) -> InstanceBudgetConfig {
  let default = default_instance_budget_config()
  case yay.select_sugar(root, "instance_budget") {
    Ok(node) ->
      InstanceBudgetConfig(
        daily_usd: get_float_or(node, "daily_usd", default.daily_usd),
        timezone: get_string_or(node, "timezone", default.timezone),
        reserve_output_tokens: get_int_or(
          node,
          "reserve_output_tokens",
          default.reserve_output_tokens,
        ),
      )
    Error(_) -> default
  }
}

fn decode_reflection(root: yay.Node) -> ReflectionConfig {
  let default = default_reflection_config()
  case yay.select_sugar(root, "reflection") {
    Ok(node) ->
      ReflectionConfig(
        every_turns: get_int_or(node, "every_turns", default.every_turns),
        every_hours: get_int_or(node, "every_hours", default.every_hours),
        model: get_optional_string(node, "model"),
        journal_limit: get_int_or(node, "journal_limit", default.journal_limit),
      )
    Error(_) -> default
  }
}

fn decode_drift(root: yay.Node) -> DriftConfig {
  let default = default_drift_config()
  case yay.select_sugar(root, "drift") {
    Ok(node) ->
      DriftConfig(
        half_life_days: get_float_or(
          node,
          "half_life_days",
          default.half_life_days,
        ),
        threshold: get_float_or(node, "threshold", default.threshold),
        min_interval_days: get_int_or(
          node,
          "min_interval_days",
          default.min_interval_days,
        ),
        min_pressure_days: get_int_or(
          node,
          "min_pressure_days",
          default.min_pressure_days,
        ),
      )
    Error(_) -> default
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
  let sim = decode_sim(root)

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
  let access = decode_access(root)
  let role_budgets = decode_role_budgets(root)
  let capabilities = decode_capabilities(root)
  let rate_limit = decode_rate_limit(root)
  let pricing = decode_pricing(root)
  let instance_budget = decode_instance_budget(root)
  let reflection = decode_reflection(root)
  let drift = decode_drift(root)
  let data_dir = get_string_or(root, "data_dir", "data")

  // Parse tools
  let tools = decode_tools(root)

  Ok(Config(
    app_name: app_name,
    environment: environment,
    log_level: log_level,
    providers: providers,
    discord: discord,
    telegram: telegram,
    sim: sim,
    matrix: matrix,
    lark: lark,
    google_chat: google_chat,
    slack: slack,
    mattermost: mattermost,
    wechat_work: wechat_work,
    whatsapp: whatsapp,
    database: database,
    budgets: budgets,
    access: access,
    role_budgets: role_budgets,
    capabilities: capabilities,
    rate_limit: rate_limit,
    pricing: pricing,
    instance_budget: instance_budget,
    reflection: reflection,
    drift: drift,
    data_dir: data_dir,
    tools: tools,
  ))
}

/// Decode Tools configuration from YAML
fn decode_tools(root: yay.Node) -> ToolsConfig {
  let default = default_tools_config()
  case yay.select_sugar(root, "tools") {
    Ok(tools_node) -> {
      let browser = case yay.select_sugar(tools_node, "browser") {
        Ok(browser_node) ->
          BrowserToolsConfig(allow_evaluate: get_bool_or(
            browser_node,
            "allow_evaluate",
            default.browser.allow_evaluate,
          ))
        Error(_) -> default.browser
      }
      ToolsConfig(browser: browser)
    }
    Error(_) -> default
  }
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
  case yay.parse_string(string.trim(yaml_string)) {
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
    Ok(value) ->
      case string.trim(value) == "" {
        True -> None
        False -> Some(value)
      }
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

  // Tools overrides
  let browser_allow_evaluate = case
    get_env("SUPERNOVA_BROWSER_ALLOW_EVALUATE")
  {
    Some(value) ->
      case string.lowercase(string.trim(value)) {
        "true" -> True
        "false" -> False
        _ -> config.tools.browser.allow_evaluate
      }
    None -> config.tools.browser.allow_evaluate
  }

  // Closed-group access overrides
  let access_mode = case
    get_env("SUPERNOVA_ACCESS_MODE")
    |> option.map(string.lowercase)
  {
    Some("open") -> Open
    Some("allowlist") -> Allowlist
    _ -> config.access.mode
  }
  let admins = case get_env("SUPERNOVA_ACCESS_ADMINS") {
    Some(value) -> parse_csv(value)
    None -> config.access.admins
  }
  let members = case get_env("SUPERNOVA_ACCESS_MEMBERS") {
    Some(value) -> parse_csv(value)
    None -> config.access.members
  }
  let allowed_chats = case get_env("SUPERNOVA_ACCESS_ALLOWED_CHATS") {
    Some(value) -> parse_csv(value)
    None -> config.access.allowed_chats
  }
  let data_dir = option.unwrap(get_env("SUPERNOVA_DATA_DIR"), config.data_dir)

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
    sim: config.sim,
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
    access: AccessConfig(
      ..config.access,
      mode: access_mode,
      admins: admins,
      members: members,
      allowed_chats: allowed_chats,
    ),
    role_budgets: config.role_budgets,
    capabilities: config.capabilities,
    rate_limit: config.rate_limit,
    pricing: config.pricing,
    instance_budget: config.instance_budget,
    reflection: config.reflection,
    drift: config.drift,
    data_dir: data_dir,
    tools: ToolsConfig(browser: BrowserToolsConfig(
      allow_evaluate: browser_allow_evaluate,
    )),
  )
}

fn parse_csv(value: String) -> List(String) {
  value
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(entry) { entry != "" })
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
  use _ <- result.try(validate_sim(config.sim))

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

fn validate_sim(config: SimConfig) -> Result(Nil, ConfigError) {
  case config.enabled {
    True ->
      case config.token {
        Some(token) ->
          case string.trim(token) {
            "" ->
              Error(ValidationError("Sim is enabled but no token is configured"))
            _ -> Ok(Nil)
          }
        None ->
          Error(ValidationError("Sim is enabled but no token is configured"))
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
    Mock -> Nil
    Zai | ZaiCoding | Mistral -> {
      case config.api_key {
        Some(_) -> Nil
        None -> {
          let _ = "Zai provider '" <> name <> "' requires an API key"
          Nil
        }
      }
    }
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

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_config_file(path: String) -> Result(String, String)

/// Load configuration from file path
pub fn load_from_file(path: String) -> Result(Config, ConfigError) {
  use yaml_string <- result.try(
    read_config_file(path)
    |> result.map_error(fn(err) {
      FileError("Failed to read configuration file \"" <> path <> "\": " <> err)
    }),
  )
  use config <- result.try(parse_yaml(yaml_string))
  let config_with_env = apply_env_overrides(config)
  use _ <- result.try(validate(config_with_env))
  Ok(config_with_env)
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
    Zai -> True
    ZaiCoding -> True
    Mistral -> True
    Mock -> False
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
    Zai -> "zai"
    ZaiCoding -> "zai_coding"
    Mistral -> "mistral"
    Mock -> "mock"
  }
}

/// Default model used when a config provider omits `model`.
pub fn provider_default_model(provider: Provider) -> String {
  case provider {
    OpenAI -> "gpt-5.4-2026-03-05"
    Anthropic -> "claude-sonnet-4-20260217"
    OpenRouter -> "openrouter/free"
    OpenCodeZen -> "claude-sonnet-4-6"
    Zhipu -> "glm-5"
    ZhipuCoding -> "glm-5.1"
    Minimax -> "MiniMax-M2.7"
    Ollama -> "llama3"
    Zai -> "glm-5"
    ZaiCoding -> "glm-5.1"
    Mistral -> "deepseek-v4-1-flash-1017"
    Mock -> "mock-model"
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

/// Root used by the kernel workspace policy.
pub fn workspace_root(config: Config) -> String {
  case config.access.mode {
    Allowlist -> config.data_dir <> "/agents"
    Open -> config.data_dir <> "/workspace"
  }
}

pub fn is_sim_enabled(config: Config) -> Bool {
  case config.sim.token {
    Some(token) -> config.sim.enabled && string.trim(token) != ""
    None -> False
  }
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

/// Support level for a channel adapter.
///
/// Telegram and Discord are covered end to end. The remaining channels are
/// experimental and warn at boot.
pub fn channel_support(channel: String) -> ChannelSupport {
  case channel {
    "telegram" | "discord" -> Supported
    _ -> Experimental
  }
}

/// All channel names known to the registry, in stable order.
pub fn channel_names() -> List(String) {
  [
    "discord",
    "telegram",
    "matrix",
    "lark",
    "google_chat",
    "slack",
    "mattermost",
    "wechat_work",
    "whatsapp",
  ]
}

/// Whether a channel is enabled in configuration.
pub fn is_channel_enabled(config: Config, channel: String) -> Bool {
  case channel {
    "discord" -> is_discord_enabled(config)
    "telegram" -> is_telegram_enabled(config)
    "matrix" -> is_matrix_enabled(config)
    "lark" -> is_lark_enabled(config)
    "google_chat" -> is_google_chat_enabled(config)
    "slack" -> is_slack_enabled(config)
    "mattermost" -> is_mattermost_enabled(config)
    "wechat_work" -> is_wechat_work_enabled(config)
    "whatsapp" -> is_whatsapp_enabled(config)
    _ -> False
  }
}

/// Provider type from its configuration name (used by the harness).
pub fn provider_from_name(name: String) -> Result(Provider, Nil) {
  case parse_provider(name) {
    Ok(provider) -> Ok(provider)
    Error(_) -> Error(Nil)
  }
}
