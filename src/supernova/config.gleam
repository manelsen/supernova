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
    /// Other models people may pick with /model, besides `model`
    models: List(String),
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
    /// Bot API server (`http://host:port`), for a self-hosted one; the public
    /// API when absent
    base_url: Option(String),
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

/// `channels.webhook`: where the webhook server listens (PRD-C, D1). It
/// starts only when an enabled channel receives by webhook. In the compose
/// file it binds the internal network and its port is not published.
pub type WebhookConfig {
  WebhookConfig(bind: String, port: Int)
}

pub fn default_webhook_config() -> WebhookConfig {
  WebhookConfig(bind: "127.0.0.1", port: 8790)
}

/// `media`: who reads what a person sends (PRD-A). Audio, video and
/// documents are read into text by `reader_model` (Gemini, with
/// SUPERNOVA_GEMINI_API_KEY); images go to the agent's own model. Without
/// the key, media become notes the agent answers.
pub type MediaConfig {
  MediaConfig(
    reader_model: String,
    speech_model: String,
    voice: String,
    audio: Bool,
    video: Bool,
    document: Bool,
    api_key: Option(String),
  )
}

pub fn default_media_config() -> MediaConfig {
  MediaConfig(
    reader_model: "gemini-3.5-flash-lite",
    speech_model: "gemini-3.8-flash-lite-tts",
    voice: "Kore",
    audio: True,
    video: True,
    document: True,
    api_key: None,
  )
}

fn decode_media(root: yay.Node) -> MediaConfig {
  let default = default_media_config()
  case yay.select_sugar(root, "media") {
    Ok(node) -> {
      let mode = fn(key, current) {
        case get_string_or(node, key, "") {
          "off" -> False
          "read" -> True
          _ -> current
        }
      }
      MediaConfig(
        ..default,
        reader_model: get_string_or(node, "reader_model", default.reader_model),
        speech_model: get_string_or(node, "speech_model", default.speech_model),
        voice: get_string_or(node, "voice", default.voice),
        audio: mode("audio", default.audio),
        video: mode("video", default.video),
        document: mode("document", default.document),
      )
    }
    Error(_) -> default
  }
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
    /// Base URL of the GOWA REST API (`http://gowa:3000` in the compose
    /// network; see `channels.internal_hosts`)
    bridge_url: Option(String),
    /// Optional bridge device ID for multi-device deployments
    device_id: Option(String),
    /// Enabled status
    enabled: Bool,
    /// `user:password` of GOWA's basic auth (`APP_BASIC_AUTH`); env
    /// SUPERNOVA_WHATSAPP_BASIC_AUTH
    basic_auth: Option(String),
    /// Shared secret of the webhook signature (`WHATSAPP_WEBHOOK_SECRET`);
    /// env SUPERNOVA_WHATSAPP_WEBHOOK_SECRET
    webhook_secret: Option(String),
    /// `whatsapp.allow_groups`: off by default, every conversation is in
    /// private and group messages are dropped unread.
    allow_groups: Bool,
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

/// The conversation each person has with the agent in a chat.
pub type ConversationConfig {
  ConversationConfig(
    /// Most recent messages (one per user turn, one per reply) the model
    /// sees. The disk keeps every message, so a conversation survives
    /// restarts and the agent can search what is older.
    history_limit: Int,
    /// Remembering what is older (PRD-M): a gate that tells when a message
    /// asks about the past, and the `lembrar` tool.
    recall: RecallConfig,
  )
}

/// The gate and `lembrar` (docs/prd/PRD-M-memoria.md). Both call a decision
/// model: Perplexity's Decider (the default) or Gemini Decision. The key
/// comes only from the environment: SUPERNOVA_PERPLEXITY_API_KEY or
/// SUPERNOVA_GEMINI_API_KEY.
pub type RecallConfig {
  RecallConfig(
    enabled: Bool,
    /// "perplexity" (default) or "gemini".
    provider: String,
    /// Cutoffs; when absent, the ones measured for the provider
    /// (memory/runtime.default_thresholds). Probabilities are not on the
    /// same scale from one model to another.
    gate_threshold: Option(Float),
    unlikely_below: Option(Float),
    likely_from: Option(Float),
    /// The gate never holds a turn longer than this; past it, the turn goes
    /// on without it.
    gate_timeout_ms: Int,
    /// The longest a `lembrar` call may take.
    recall_timeout_ms: Int,
    api_key: Option(String),
  )
}

pub fn default_recall_config() -> RecallConfig {
  RecallConfig(
    enabled: False,
    provider: "perplexity",
    gate_threshold: None,
    unlikely_below: None,
    likely_from: None,
    gate_timeout_ms: 2000,
    recall_timeout_ms: 15_000,
    api_key: None,
  )
}

pub fn default_conversation_config() -> ConversationConfig {
  ConversationConfig(history_limit: 100, recall: default_recall_config())
}

/// recall on needs a known provider and its key: without them the boot
/// stops, instead of every turn failing over to the plain path.
pub fn validate_recall(config: Config) -> Result(Nil, String) {
  let recall = config.conversation.recall
  case recall.enabled, recall.provider, recall.api_key {
    False, _, _ -> Ok(Nil)
    True, provider, _ if provider != "perplexity" && provider != "gemini" ->
      Error(
        "conversation.recall.provider must be perplexity or gemini, found "
        <> provider,
      )
    True, provider, Some(key) ->
      case string.trim(key) {
        "" -> Error(recall_key_missing(provider))
        _ -> Ok(Nil)
      }
    True, provider, None -> Error(recall_key_missing(provider))
  }
}

/// The environment variable that holds the key for `provider`.
pub fn recall_key_env(provider: String) -> String {
  case provider {
    "gemini" -> "SUPERNOVA_GEMINI_API_KEY"
    _ -> "SUPERNOVA_PERPLEXITY_API_KEY"
  }
}

fn recall_key_missing(provider: String) -> String {
  "conversation.recall.enabled needs "
  <> recall_key_env(provider)
  <> " (a paid API key: excerpts of conversations are sent to it)"
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
    /// `tools.timeouts`: seconds per tool name, and `default` for the rest
    /// (PRD-E, D3). Empty means the built-in limits.
    timeouts: Dict(String, Int),
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
    /// Webhook server for channels that receive by webhook
    webhook: WebhookConfig,
    /// Who reads the media a person sends (PRD-A)
    media: MediaConfig,
    /// `channels.internal_hosts`: hosts a channel may reach over plain http
    /// (a bridge in the same compose network), besides loopback.
    channel_internal_hosts: List(String),
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
    /// Conversation history kept per person and chat
    conversation: ConversationConfig,
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
    telegram: TelegramConfig(token: None, enabled: False, base_url: None),
    sim: SimConfig(
      enabled: False,
      bind: "127.0.0.1",
      port: 8787,
      token: None,
      record_prompts: False,
    ),
    webhook: default_webhook_config(),
    media: default_media_config(),
    channel_internal_hosts: [],
    matrix: MatrixConfig(homeserver_url: None, token: None, enabled: False),
    lark: LarkConfig(token: None, base_url: None, enabled: False),
    google_chat: GoogleChatConfig(webhook_url: None, enabled: False),
    slack: SlackConfig(token: None, enabled: False),
    mattermost: MattermostConfig(token: None, base_url: None, enabled: False),
    wechat_work: WechatWorkConfig(webhook_url: None, enabled: False),
    whatsapp: default_whatsapp_config(),
    budgets: default_budgets_config(),
    access: default_access_config(),
    role_budgets: default_role_budgets_config(),
    capabilities: default_capabilities_config(),
    rate_limit: default_rate_limit_config(),
    pricing: default_pricing_config(),
    instance_budget: default_instance_budget_config(),
    conversation: default_conversation_config(),
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
      allowed: [
        "web", "web_fetch", "file_system", "canvas", "github", "agenda",
        "buscar_conversa", "lembrar",
      ],
      denied: ["safe_shell", "process", "browser", "computador"],
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
  ToolsConfig(
    browser: BrowserToolsConfig(allow_evaluate: False),
    timeouts: dict.new(),
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
    models: [],
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
fn get_optional_float(node: yay.Node, key: String) -> Option(Float) {
  case yay.select_sugar(node, key) {
    Ok(yay.NodeFloat(value)) -> Some(value)
    Ok(yay.NodeInt(value)) -> Some(int.to_float(value))
    _ -> None
  }
}

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
  let models =
    get_string_list(node, "models")
    |> list.map(string.trim)
    |> list.filter(fn(name) { name != "" })
  let timeout_ms = get_int_or(node, "timeout_ms", 30_000)

  Ok(ProviderConfig(
    provider: provider,
    api_key: api_key,
    base_url: base_url,
    model: model,
    models: models,
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
        base_url: get_optional_string(telegram_node, "base_url"),
      )
    }
    Error(_) -> TelegramConfig(token: None, enabled: False, base_url: None)
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

fn decode_webhook(root: yay.Node) -> WebhookConfig {
  let default = default_webhook_config()
  case yay.select_sugar(root, "channels.webhook") {
    Ok(node) ->
      WebhookConfig(
        bind: get_string_or(node, "bind", default.bind),
        port: get_int_or(node, "port", default.port),
      )
    Error(_) -> default
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
pub fn default_whatsapp_config() -> WhatsAppConfig {
  WhatsAppConfig(
    bridge_url: None,
    device_id: None,
    enabled: False,
    basic_auth: None,
    webhook_secret: None,
    allow_groups: False,
  )
}

fn decode_whatsapp(root: yay.Node) -> WhatsAppConfig {
  case yay.select_sugar(root, "whatsapp") {
    Ok(node) ->
      WhatsAppConfig(
        ..default_whatsapp_config(),
        bridge_url: get_optional_string(node, "bridge_url"),
        device_id: get_optional_string(node, "device_id"),
        enabled: get_bool_or(node, "enabled", False),
        allow_groups: get_bool_or(node, "allow_groups", False),
      )
    Error(_) -> default_whatsapp_config()
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

fn decode_conversation(root: yay.Node) -> ConversationConfig {
  let default = default_conversation_config()
  case yay.select_sugar(root, "conversation") {
    Ok(node) -> {
      let limit =
        int.max(get_int_or(node, "history_limit", default.history_limit), 2)
      ConversationConfig(history_limit: limit, recall: decode_recall(node))
    }
    Error(_) -> default
  }
}

fn decode_recall(conversation: yay.Node) -> RecallConfig {
  let default = default_recall_config()
  case yay.select_sugar(conversation, "recall") {
    Ok(node) ->
      RecallConfig(
        enabled: get_bool_or(node, "enabled", default.enabled),
        provider: option.unwrap(
          get_optional_string(node, "provider"),
          default.provider,
        ),
        gate_threshold: get_optional_float(node, "gate_threshold"),
        unlikely_below: get_optional_float(node, "unlikely_below"),
        likely_from: get_optional_float(node, "likely_from"),
        gate_timeout_ms: int.max(
          get_int_or(node, "gate_timeout_ms", default.gate_timeout_ms),
          1,
        ),
        recall_timeout_ms: int.max(
          get_int_or(node, "recall_timeout_ms", default.recall_timeout_ms),
          1,
        ),
        api_key: None,
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

  // Parse budgets
  let budgets = decode_budgets(root)
  let access = decode_access(root)
  let role_budgets = decode_role_budgets(root)
  let capabilities = decode_capabilities(root)
  let rate_limit = decode_rate_limit(root)
  let pricing = decode_pricing(root)
  let instance_budget = decode_instance_budget(root)
  let conversation = decode_conversation(root)
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
    webhook: decode_webhook(root),
    media: decode_media(root),
    channel_internal_hosts: case yay.select_sugar(root, "channels") {
      Ok(channels) -> get_string_list(channels, "internal_hosts")
      Error(_) -> []
    },
    matrix: matrix,
    lark: lark,
    google_chat: google_chat,
    slack: slack,
    mattermost: mattermost,
    wechat_work: wechat_work,
    whatsapp: whatsapp,
    budgets: budgets,
    access: access,
    role_budgets: role_budgets,
    capabilities: capabilities,
    rate_limit: rate_limit,
    pricing: pricing,
    instance_budget: instance_budget,
    conversation: conversation,
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
      ToolsConfig(browser: browser, timeouts: decode_tool_timeouts(tools_node))
    }
    Error(_) -> default
  }
}

/// `tools.timeouts`: positive whole seconds by tool name; anything else is
/// ignored.
fn decode_tool_timeouts(tools_node: yay.Node) -> Dict(String, Int) {
  case yay.select_sugar(tools_node, "timeouts") {
    Ok(yay.NodeMap(pairs)) ->
      list.fold(pairs, dict.new(), fn(acc, pair) {
        case pair {
          #(yay.NodeStr(name), yay.NodeInt(seconds)) if seconds > 0 ->
            dict.insert(acc, name, seconds)
          _ -> acc
        }
      })
    _ -> dict.new()
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
    telegram: TelegramConfig(
      ..config.telegram,
      token: telegram_token,
      enabled: telegram_enabled,
    ),
    sim: config.sim,
    webhook: config.webhook,
    media: MediaConfig(
      ..config.media,
      api_key: option.or(
        get_env("SUPERNOVA_GEMINI_API_KEY"),
        config.media.api_key,
      ),
    ),
    channel_internal_hosts: config.channel_internal_hosts,
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
      basic_auth: option.or(
        get_env("SUPERNOVA_WHATSAPP_BASIC_AUTH"),
        config.whatsapp.basic_auth,
      ),
      webhook_secret: option.or(
        get_env("SUPERNOVA_WHATSAPP_WEBHOOK_SECRET"),
        config.whatsapp.webhook_secret,
      ),
      allow_groups: config.whatsapp.allow_groups,
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
    conversation: ConversationConfig(
      ..config.conversation,
      recall: RecallConfig(
        ..config.conversation.recall,
        api_key: option.or(
          get_env(recall_key_env(config.conversation.recall.provider)),
          config.conversation.recall.api_key,
        ),
      ),
    ),
    reflection: config.reflection,
    drift: config.drift,
    data_dir: data_dir,
    tools: ToolsConfig(
      browser: BrowserToolsConfig(allow_evaluate: browser_allow_evaluate),
      timeouts: config.tools.timeouts,
    ),
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
    let api_key = option.or(get_env(provider_env_key(name)), config.api_key)

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

  // A missing key for the selected provider is refused at boot by
  // `selected_provider`; the other providers are optional.
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

/// Environment variable that holds the API key of the named provider.
pub fn provider_env_key(name: String) -> String {
  "SUPERNOVA_PROVIDER_"
  <> { string.uppercase(name) |> string.replace("-", "_") }
  <> "_API_KEY"
}

/// Whether the provider can be called: it has a key, or needs none.
pub fn provider_usable(provider_config: ProviderConfig) -> Bool {
  !provider_requires_api_key(provider_config.provider)
  || has_usable_key(provider_config)
}

fn has_usable_key(provider_config: ProviderConfig) -> Bool {
  case provider_config.api_key {
    Some(key) -> string.trim(key) != ""
    None -> False
  }
}

/// The provider every agent uses: the first one by name.
///
/// Refuses a provider that needs an API key and has none, so a missing key
/// stops the boot instead of failing the first conversation.
pub fn selected_provider(
  config: Config,
) -> Result(#(String, ProviderConfig), String) {
  let providers =
    config.providers
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  case providers {
    [] ->
      Error(
        "no LLM providers configured — add a provider to supernova.yaml or run the wizard (gleam run -m supernova/wizard_main)",
      )
    [#(name, chosen), ..others] ->
      case
        provider_requires_api_key(chosen.provider) && !has_usable_key(chosen)
      {
        False -> Ok(#(name, chosen))
        True -> {
          let keyed =
            others
            |> list.filter(fn(other) { has_usable_key(other.1) })
            |> list.map(fn(other) { other.0 })
          let hint = case keyed {
            [] -> ""
            _ ->
              " Providers with a key: "
              <> string.join(keyed, ", ")
              <> "; remove the other provider blocks from supernova.yaml to use one of them."
          }
          Error(
            "provider '"
            <> name
            <> "' is the one agents use (the first by name) and has no API key: set "
            <> provider_env_key(name)
            <> "."
            <> hint,
          )
        }
      }
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
  config.whatsapp.enabled
  && config.whatsapp.bridge_url != None
  && config.whatsapp.webhook_secret != None
  && config.whatsapp.basic_auth != None
}

/// Channels with `enabled: true` that cannot start because a required
/// setting is missing, with the reason. Boot skips them; readiness lists them.
pub fn incomplete_channels(config: Config) -> List(#(String, String)) {
  let missing = fn(name, enabled, fields: List(#(String, Bool))) {
    case enabled {
      False -> []
      True ->
        case list.filter(fields, fn(field) { !field.1 }) {
          [] -> []
          absent -> [
            #(
              name,
              "enabled but missing "
                <> string.join(list.map(absent, fn(field) { field.0 }), ", "),
            ),
          ]
        }
    }
  }
  let sim_token = case config.sim.token {
    Some(token) -> string.trim(token) != ""
    None -> False
  }
  list.flatten([
    missing("discord", config.discord.enabled, [
      #("token", config.discord.token != None),
    ]),
    missing("telegram", config.telegram.enabled, [
      #("token", config.telegram.token != None),
    ]),
    missing("sim", config.sim.enabled, [#("token", sim_token)]),
    missing("matrix", config.matrix.enabled, [
      #("token", config.matrix.token != None),
    ]),
    missing("lark", config.lark.enabled, [#("token", config.lark.token != None)]),
    missing("google_chat", config.google_chat.enabled, [
      #("webhook_url", config.google_chat.webhook_url != None),
    ]),
    missing("slack", config.slack.enabled, [
      #("token", config.slack.token != None),
    ]),
    missing("mattermost", config.mattermost.enabled, [
      #("token", config.mattermost.token != None),
      #("base_url", config.mattermost.base_url != None),
    ]),
    missing("wechat_work", config.wechat_work.enabled, [
      #("webhook_url", config.wechat_work.webhook_url != None),
    ]),
    missing("whatsapp", config.whatsapp.enabled, [
      #("bridge_url", config.whatsapp.bridge_url != None),
      #(
        "SUPERNOVA_WHATSAPP_WEBHOOK_SECRET",
        config.whatsapp.webhook_secret != None,
      ),
      #("SUPERNOVA_WHATSAPP_BASIC_AUTH", config.whatsapp.basic_auth != None),
    ]),
  ])
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
    "sim" -> is_sim_enabled(config)
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
