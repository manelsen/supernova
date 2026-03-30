//// Setup wizard for channel bot configuration.
////
//// This module provides an interactive CLI wizard that guides users
//// through configuring channel bot tokens, then generates a
//// supernova.yaml configuration file with the collected tokens.
////
//// ## Usage
////
//// ```gleam
//// import supernova/wizard
////
//// pub fn main() {
////   let _ = wizard.run()
//// }
//// ```

import gleam/io

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/llm/providers_info

// ============================================================================
// Types
// ============================================================================

/// Which platform(s) the user wants to configure
pub type Platform {
  PlatformDiscord
  PlatformTelegram
  PlatformMatrix
  PlatformLark
  PlatformGoogleChat
  PlatformSlack
  PlatformMattermost
  PlatformWechatWork
  PlatformWhatsApp
  PlatformAll
}

/// State collected by the wizard
pub type WizardState {
  WizardState(
    /// Application name for the generated config
    app_name: String,
    /// Discord bot token
    discord_token: Option(String),
    /// Discord application ID
    discord_app_id: Option(String),
    /// Discord guild ID (optional, for dev servers)
    discord_guild_id: Option(String),
    /// Telegram bot token
    telegram_token: Option(String),
    /// Matrix bot token
    matrix_token: Option(String),
    /// Lark bot token
    lark_token: Option(String),
    /// Optional Lark Open API base URL override
    lark_base_url: Option(String),
    /// Google Chat incoming webhook URL
    google_chat_webhook_url: Option(String),
    /// Slack bot token
    slack_token: Option(String),
    /// Mattermost access token
    mattermost_token: Option(String),
    /// Mattermost base URL
    mattermost_base_url: Option(String),
    /// WeChat Work robot webhook URL
    wechat_work_webhook_url: Option(String),
    /// WhatsApp bridge base URL
    whatsapp_bridge_url: Option(String),
    /// Optional WhatsApp bridge device ID
    whatsapp_device_id: Option(String),
    /// Provider key (e.g., "openai", "anthropic")
    provider_key: Option(String),
    /// Provider API key
    provider_api_key: Option(String),
    /// Selected model
    model: Option(String),
    /// Memory backend
    memory_backend: Option(String),
    /// Output file path for supernova.yaml
    output_path: String,
  )
}

/// Wizard error type
pub type WizardError {
  /// User cancelled (EOF on stdin)
  UserCancelled
  /// Could not write the output file
  FileWriteError(message: String)
}

// ============================================================================
// FFI Bindings
// ============================================================================

/// Read a line from stdin with a prompt.
/// Returns Ok(line) or Error(Nil) on EOF/error.
@external(erlang, "supernova_wizard_ffi", "read_line")
fn read_line_ffi(prompt: String) -> Result(String, Nil)

/// Write content to a file.
/// Returns Ok(Nil) or Error(message) on failure.
@external(erlang, "supernova_wizard_ffi", "write_file")
fn write_file_ffi(path: String, content: String) -> Result(Nil, String)

// ============================================================================
// Pure Functions (Guide Content & YAML Generation)
// ============================================================================

/// Return an empty/default wizard state
pub fn empty_state() -> WizardState {
  WizardState(
    app_name: "my-bot",
    discord_token: None,
    discord_app_id: None,
    discord_guild_id: None,
    telegram_token: None,
    matrix_token: None,
    lark_token: None,
    lark_base_url: None,
    google_chat_webhook_url: None,
    slack_token: None,
    mattermost_token: None,
    mattermost_base_url: None,
    wechat_work_webhook_url: None,
    whatsapp_bridge_url: None,
    whatsapp_device_id: None,
    provider_key: None,
    provider_api_key: None,
    model: None,
    memory_backend: None,
    output_path: "supernova.yaml",
  )
}

/// Return step-by-step instructions for creating a Discord bot
pub fn discord_guide_steps() -> List(String) {
  [
    "1. Go to https://discord.com/developers/applications",
    "2. Click 'New Application' and give your bot a name",
    "3. In the left sidebar, click 'Bot'",
    "4. Click 'Add Bot', then confirm with 'Yes, do it!'",
    "5. Under 'Token', click 'Reset Token' then 'Copy'",
    "   (You will be asked to paste this token shortly)",
    "6. Enable 'Message Content Intent' under 'Privileged Gateway Intents'",
    "7. Go to 'OAuth2' > 'URL Generator'",
    "8. Select scopes: 'bot' and 'applications.commands'",
    "9. Select permissions: 'Send Messages', 'Read Message History'",
    "10. Copy the generated URL and open it to invite the bot to your server",
    "11. Your Application ID is shown on the 'General Information' page",
  ]
}

/// Return step-by-step instructions for creating a Telegram bot
pub fn telegram_guide_steps() -> List(String) {
  [
    "1. Open Telegram and search for '@BotFather'",
    "2. Start a chat with BotFather and send /newbot",
    "3. Follow the prompts: enter a display name for your bot",
    "4. Enter a username for your bot (must end in 'bot', e.g. my_awesome_bot)",
    "5. BotFather will reply with your bot token — copy it",
    "   (You will be asked to paste this token shortly)",
    "6. Optionally use /setdescription, /setabouttext to customise your bot",
  ]
}

/// Format a list of guide steps as a single printable block
pub fn format_guide(steps: List(String)) -> String {
  steps
  |> list.map(fn(step) { "  " <> step })
  |> string.join("\n")
}

/// Generate a supernova.yaml string from the wizard state
pub fn generate_yaml(state: WizardState) -> String {
  let discord_section = case state.discord_token {
    Some(token) -> {
      let app_id_line = case state.discord_app_id {
        Some(app_id) -> "  app_id: \"" <> app_id <> "\"\n"
        None -> ""
      }
      let guild_id_line = case state.discord_guild_id {
        Some(guild_id) -> "  guild_id: \"" <> guild_id <> "\"\n"
        None -> ""
      }
      "discord:\n"
      <> "  token: \""
      <> token
      <> "\"\n"
      <> app_id_line
      <> guild_id_line
      <> "  enabled: true\n"
    }
    None -> "discord:\n" <> "  enabled: false\n"
  }

  let telegram_section = channel_yaml("telegram", state.telegram_token)
  let matrix_section = channel_yaml("matrix", state.matrix_token)
  let lark_section = lark_yaml(state.lark_token, state.lark_base_url)
  let google_chat_section = google_chat_yaml(state.google_chat_webhook_url)
  let slack_section = channel_yaml("slack", state.slack_token)
  let mattermost_section =
    mattermost_yaml(state.mattermost_token, state.mattermost_base_url)
  let wechat_work_section = wechat_work_yaml(state.wechat_work_webhook_url)
  let whatsapp_section =
    whatsapp_yaml(state.whatsapp_bridge_url, state.whatsapp_device_id)

  let provider_section = case state.provider_key {
    Some(provider) -> {
      let api_key_line = case state.provider_api_key {
        Some(api_key) -> "    api_key: \"" <> api_key <> "\"\n"
        None -> ""
      }
      let model_line = case state.model {
        Some(model) -> "    model: \"" <> model <> "\"\n"
        None -> ""
      }
      let memory_line = case state.memory_backend {
        Some(backend) -> "    memory_backend: \"" <> backend <> "\"\n"
        None -> ""
      }
      "providers:\n"
      <> "  default:\n"
      <> "    provider: \""
      <> provider
      <> "\"\n"
      <> api_key_line
      <> model_line
      <> memory_line
    }
    None -> ""
  }

  "# Supernova configuration — generated by setup wizard\n"
  <> "app_name: \""
  <> state.app_name
  <> "\"\n"
  <> "environment: development\n"
  <> "log_level: info\n"
  <> "\n"
  <> provider_section
  <> "\n"
  <> discord_section
  <> "\n"
  <> telegram_section
  <> "\n"
  <> matrix_section
  <> "\n"
  <> lark_section
  <> "\n"
  <> google_chat_section
  <> "\n"
  <> slack_section
  <> "\n"
  <> mattermost_section
  <> "\n"
  <> wechat_work_section
  <> "\n"
  <> whatsapp_section
}

fn channel_yaml(name: String, token: Option(String)) -> String {
  case token {
    Some(value) ->
      name <> ":\n" <> "  token: \"" <> value <> "\"\n" <> "  enabled: true\n"
    None -> name <> ":\n" <> "  enabled: false\n"
  }
}

fn lark_yaml(token: Option(String), base_url: Option(String)) -> String {
  case token {
    Some(value) -> {
      let base_url_line = case base_url {
        Some(url) -> "  base_url: \"" <> url <> "\"\n"
        None -> ""
      }
      "lark:\n"
      <> "  token: \""
      <> value
      <> "\"\n"
      <> base_url_line
      <> "  enabled: true\n"
    }
    None -> "lark:\n" <> "  enabled: false\n"
  }
}

fn google_chat_yaml(webhook_url: Option(String)) -> String {
  case webhook_url {
    Some(url) ->
      "google_chat:\n"
      <> "  webhook_url: \""
      <> url
      <> "\"\n"
      <> "  enabled: true\n"
    None -> "google_chat:\n" <> "  enabled: false\n"
  }
}

fn mattermost_yaml(token: Option(String), base_url: Option(String)) -> String {
  case token {
    Some(value) -> {
      let base_url_line = case base_url {
        Some(url) -> "  base_url: \"" <> url <> "\"\n"
        None -> ""
      }
      "mattermost:\n"
      <> "  token: \""
      <> value
      <> "\"\n"
      <> base_url_line
      <> "  enabled: true\n"
    }
    None -> "mattermost:\n" <> "  enabled: false\n"
  }
}

fn wechat_work_yaml(webhook_url: Option(String)) -> String {
  case webhook_url {
    Some(url) ->
      "wechat_work:\n"
      <> "  webhook_url: \""
      <> url
      <> "\"\n"
      <> "  enabled: true\n"
    None -> "wechat_work:\n" <> "  enabled: false\n"
  }
}

fn whatsapp_yaml(
  bridge_url: Option(String),
  device_id: Option(String),
) -> String {
  case bridge_url {
    Some(url) -> {
      let device_id_line = case device_id {
        Some(value) -> "  device_id: \"" <> value <> "\"\n"
        None -> ""
      }
      "whatsapp:\n"
      <> "  bridge_url: \""
      <> url
      <> "\"\n"
      <> device_id_line
      <> "  enabled: true\n"
    }
    None -> "whatsapp:\n" <> "  enabled: false\n"
  }
}

// ============================================================================
// IO Helpers
// ============================================================================

/// Print a header banner
fn print_banner() -> Nil {
  io.println("")
  io.println("╔══════════════════════════════════════════╗")
  io.println("║      Supernova Setup Wizard              ║")
  io.println("║  Configure Supernova channel bots        ║")
  io.println("╚══════════════════════════════════════════╝")
  io.println("")
}

/// Print a section header
fn print_section(title: String) -> Nil {
  io.println("")
  io.println("─── " <> title <> " ───")
  io.println("")
}

/// Ask a question and read the answer.
/// Returns Error(UserCancelled) if the user sends EOF.
fn ask(prompt: String) -> Result(String, WizardError) {
  case read_line_ffi(prompt) {
    Ok(answer) -> Ok(answer)
    Error(Nil) -> Error(UserCancelled)
  }
}

/// Ask a question with a default value.
/// If the user presses Enter without typing, the default is used.
fn ask_with_default(
  prompt: String,
  default: String,
) -> Result(String, WizardError) {
  let full_prompt = prompt <> " [" <> default <> "]: "
  case ask(full_prompt) {
    Ok("") -> Ok(default)
    Ok(value) -> Ok(value)
    Error(e) -> Error(e)
  }
}

/// Ask for a choice from 1..n, retry on invalid input.
fn ask_choice(prompt: String, max: Int) -> Result(Int, WizardError) {
  case ask(prompt) {
    Error(e) -> Error(e)
    Ok(input) -> {
      let trimmed = string.trim(input)
      case parse_choice(trimmed, max) {
        Ok(n) -> Ok(n)
        Error(Nil) -> {
          io.println(
            "  Please enter a number between 1 and " <> int.to_string(max),
          )
          ask_choice(prompt, max)
        }
      }
    }
  }
}

/// Parse a choice string "1".."n" and validate range
fn parse_choice(s: String, max: Int) -> Result(Int, Nil) {
  case s {
    "1" -> Ok(1)
    "2" ->
      case max >= 2 {
        True -> Ok(2)
        False -> Error(Nil)
      }
    "3" ->
      case max >= 3 {
        True -> Ok(3)
        False -> Error(Nil)
      }
    "4" ->
      case max >= 4 {
        True -> Ok(4)
        False -> Error(Nil)
      }
    "5" ->
      case max >= 5 {
        True -> Ok(5)
        False -> Error(Nil)
      }
    "6" ->
      case max >= 6 {
        True -> Ok(6)
        False -> Error(Nil)
      }
    "7" ->
      case max >= 7 {
        True -> Ok(7)
        False -> Error(Nil)
      }
    "8" ->
      case max >= 8 {
        True -> Ok(8)
        False -> Error(Nil)
      }
    "9" ->
      case max >= 9 {
        True -> Ok(9)
        False -> Error(Nil)
      }
    "10" ->
      case max >= 10 {
        True -> Ok(10)
        False -> Error(Nil)
      }
    "11" ->
      case max >= 11 {
        True -> Ok(11)
        False -> Error(Nil)
      }
    "12" ->
      case max >= 12 {
        True -> Ok(12)
        False -> Error(Nil)
      }
    "13" ->
      case max >= 13 {
        True -> Ok(13)
        False -> Error(Nil)
      }
    "14" ->
      case max >= 14 {
        True -> Ok(14)
        False -> Error(Nil)
      }
    "15" ->
      case max >= 15 {
        True -> Ok(15)
        False -> Error(Nil)
      }
    "16" ->
      case max >= 16 {
        True -> Ok(16)
        False -> Error(Nil)
      }
    "17" ->
      case max >= 17 {
        True -> Ok(17)
        False -> Error(Nil)
      }
    "18" ->
      case max >= 18 {
        True -> Ok(18)
        False -> Error(Nil)
      }
    "19" ->
      case max >= 19 {
        True -> Ok(19)
        False -> Error(Nil)
      }
    "20" ->
      case max >= 20 {
        True -> Ok(20)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// ============================================================================
// Wizard Steps
// ============================================================================

/// Ask which platform to configure
fn ask_platform() -> Result(Platform, WizardError) {
  io.println("Which channel(s) do you want to configure?")
  io.println("  1) Discord")
  io.println("  2) Telegram")
  io.println("  3) Matrix")
  io.println("  4) Lark")
  io.println("  5) Google Chat")
  io.println("  6) Slack")
  io.println("  7) Mattermost")
  io.println("  8) WeChat Work")
  io.println("  9) WhatsApp")
  io.println("  10) All channels")
  io.println("")

  case ask_choice("Your choice (1-10): ", 10) {
    Ok(1) -> Ok(PlatformDiscord)
    Ok(2) -> Ok(PlatformTelegram)
    Ok(3) -> Ok(PlatformMatrix)
    Ok(4) -> Ok(PlatformLark)
    Ok(5) -> Ok(PlatformGoogleChat)
    Ok(6) -> Ok(PlatformSlack)
    Ok(7) -> Ok(PlatformMattermost)
    Ok(8) -> Ok(PlatformWechatWork)
    Ok(9) -> Ok(PlatformWhatsApp)
    Ok(10) -> Ok(PlatformAll)
    Ok(_) -> Ok(PlatformAll)
    Error(e) -> Error(e)
  }
}

/// Ask which LLM provider to use
fn ask_provider() -> Result(String, WizardError) {
  print_section("LLM Provider Setup")

  let providers = providers_info.known_providers()
  io.println("Select an LLM provider:")

  print_provider_list(providers, 1)
  io.println("")

  case ask_choice("Provider number: ", list.length(providers)) {
    Ok(n) -> {
      case providers |> list.drop(n - 1) |> list.first() {
        Ok(provider_info) -> Ok(provider_info.key)
        Error(_) -> Error(UserCancelled)
      }
    }
    Error(e) -> Error(e)
  }
}

/// Print provider list with numbers
fn print_provider_list(
  providers: List(providers_info.ProviderInfo),
  num: Int,
) -> Nil {
  case providers {
    [] -> Nil
    [provider, ..rest] -> {
      io.println(
        "  "
        <> int.to_string(num)
        <> ") "
        <> provider.label
        <> " - "
        <> provider.description,
      )
      print_provider_list(rest, num + 1)
    }
  }
}

/// Ask for the provider API key
fn ask_provider_api_key(provider: String) -> Result(String, WizardError) {
  io.println("")
  io.println("API key for " <> provider <> ":")
  use api_key <- result_try(ask(
    "Paste your API key (or press Enter to configure later): ",
  ))
  let trimmed = string.trim(api_key)
  case trimmed {
    "" -> Ok("")
    _ -> Ok(trimmed)
  }
}

/// Ask which model to use
fn ask_model(provider: String) -> Result(String, WizardError) {
  print_section("Model Selection")
  io.println("Current provider: " <> provider)
  io.println("")
  io.println("Enter a model name (e.g., gpt-4, claude-3-opus)")
  io.println("or press Enter to use the provider default.")
  io.println("")

  use model <- result_try(ask_with_default("Model", ""))
  Ok(string.trim(model))
}

/// Ask which memory backend to use
fn ask_memory_backend() -> Result(String, WizardError) {
  print_section("Memory Backend")
  io.println("Select a memory backend for conversation history:")
  io.println("  1) None (no memory)")
  io.println("  2) Sqlite (local file-based)")
  io.println("  3) Redis (requires Redis server)")
  io.println("")

  case ask_choice("Backend number (1-3): ", 3) {
    Ok(1) -> Ok("none")
    Ok(2) -> Ok("sqlite")
    Ok(3) -> Ok("redis")
    Ok(_) -> Ok("none")
    Error(e) -> Error(e)
  }
}

/// Run the Discord configuration wizard steps
fn configure_discord(state: WizardState) -> Result(WizardState, WizardError) {
  print_section("Discord Bot Setup")

  io.println("Follow these steps to create your Discord bot:")
  io.println("")
  io.println(format_guide(discord_guide_steps()))
  io.println("")

  use token <- result_try(ask("Paste your Discord bot token: "))
  let discord_token = case string.trim(token) {
    "" -> None
    t -> Some(t)
  }

  use app_id_raw <- result_try(ask_with_default(
    "Application ID (from General Information page)",
    "",
  ))
  let discord_app_id = case string.trim(app_id_raw) {
    "" -> None
    v -> Some(v)
  }

  use guild_id_raw <- result_try(ask_with_default(
    "Guild/Server ID for dev server (leave blank to skip)",
    "",
  ))
  let discord_guild_id = case string.trim(guild_id_raw) {
    "" -> None
    v -> Some(v)
  }

  Ok(
    WizardState(
      ..state,
      discord_token: discord_token,
      discord_app_id: discord_app_id,
      discord_guild_id: discord_guild_id,
    ),
  )
}

/// Run the Telegram configuration wizard steps
fn configure_telegram(state: WizardState) -> Result(WizardState, WizardError) {
  print_section("Telegram Bot Setup")

  io.println("Follow these steps to create your Telegram bot:")
  io.println("")
  io.println(format_guide(telegram_guide_steps()))
  io.println("")

  use token <- result_try(ask("Paste your Telegram bot token: "))
  let telegram_token = case string.trim(token) {
    "" -> None
    t -> Some(t)
  }

  Ok(WizardState(..state, telegram_token: telegram_token))
}

fn configure_matrix(state: WizardState) -> Result(WizardState, WizardError) {
  print_section("Matrix Bot Setup")
  use token <- result_try(ask("Paste your Matrix token (blank to skip): "))
  let matrix_token = case string.trim(token) {
    "" -> None
    t -> Some(t)
  }
  Ok(WizardState(..state, matrix_token: matrix_token))
}

fn configure_lark(state: WizardState) -> Result(WizardState, WizardError) {
  print_section("Lark Bot Setup")
  use token <- result_try(ask("Paste your Lark token (blank to skip): "))
  let lark_token = case string.trim(token) {
    "" -> None
    t -> Some(t)
  }
  case lark_token {
    None -> Ok(WizardState(..state, lark_token: None, lark_base_url: None))
    Some(_) -> {
      use base_url <- result_try(ask(
        "Paste your Lark base URL (blank for default Open API host): ",
      ))
      let lark_base_url = case string.trim(base_url) {
        "" -> None
        value -> Some(value)
      }
      Ok(
        WizardState(
          ..state,
          lark_token: lark_token,
          lark_base_url: lark_base_url,
        ),
      )
    }
  }
}

fn configure_google_chat(state: WizardState) -> Result(WizardState, WizardError) {
  print_section("Google Chat Bot Setup")
  use webhook_url <- result_try(ask(
    "Paste your Google Chat webhook URL (blank to skip): ",
  ))
  let google_chat_webhook_url = case string.trim(webhook_url) {
    "" -> None
    t -> Some(t)
  }
  Ok(WizardState(..state, google_chat_webhook_url: google_chat_webhook_url))
}

fn configure_slack(state: WizardState) -> Result(WizardState, WizardError) {
  print_section("Slack Bot Setup")
  use token <- result_try(ask("Paste your Slack token (blank to skip): "))
  let slack_token = case string.trim(token) {
    "" -> None
    t -> Some(t)
  }
  Ok(WizardState(..state, slack_token: slack_token))
}

fn configure_mattermost(state: WizardState) -> Result(WizardState, WizardError) {
  print_section("Mattermost Bot Setup")
  use token <- result_try(ask("Paste your Mattermost token (blank to skip): "))
  let mattermost_token = case string.trim(token) {
    "" -> None
    t -> Some(t)
  }
  case mattermost_token {
    None ->
      Ok(
        WizardState(..state, mattermost_token: None, mattermost_base_url: None),
      )
    Some(_) -> {
      use base_url <- result_try(ask(
        "Paste your Mattermost base URL (blank to skip): ",
      ))
      let mattermost_base_url = case string.trim(base_url) {
        "" -> None
        value -> Some(value)
      }
      Ok(
        WizardState(
          ..state,
          mattermost_token: mattermost_token,
          mattermost_base_url: mattermost_base_url,
        ),
      )
    }
  }
}

fn configure_wechat_work(state: WizardState) -> Result(WizardState, WizardError) {
  print_section("WeChat Work Bot Setup")
  use webhook_url <- result_try(ask(
    "Paste your WeChat Work webhook URL (blank to skip): ",
  ))
  let wechat_work_webhook_url = case string.trim(webhook_url) {
    "" -> None
    t -> Some(t)
  }
  Ok(WizardState(..state, wechat_work_webhook_url: wechat_work_webhook_url))
}

fn configure_whatsapp(state: WizardState) -> Result(WizardState, WizardError) {
  print_section("WhatsApp Bot Setup")
  use bridge_url <- result_try(ask(
    "Paste your WhatsApp bridge URL (blank to skip): ",
  ))
  let whatsapp_bridge_url = case string.trim(bridge_url) {
    "" -> None
    value -> Some(value)
  }
  case whatsapp_bridge_url {
    None ->
      Ok(
        WizardState(
          ..state,
          whatsapp_bridge_url: None,
          whatsapp_device_id: None,
        ),
      )
    Some(url) -> {
      use device_id <- result_try(ask(
        "Paste your WhatsApp bridge device ID (blank for default device): ",
      ))
      let whatsapp_device_id = case string.trim(device_id) {
        "" -> None
        value -> Some(value)
      }
      Ok(
        WizardState(
          ..state,
          whatsapp_bridge_url: Some(url),
          whatsapp_device_id: whatsapp_device_id,
        ),
      )
    }
  }
}

fn configure_all_channels(
  state: WizardState,
) -> Result(WizardState, WizardError) {
  use s1 <- result_try(configure_discord(state))
  use s2 <- result_try(configure_telegram(s1))
  use s3 <- result_try(configure_matrix(s2))
  use s4 <- result_try(configure_lark(s3))
  use s5 <- result_try(configure_google_chat(s4))
  use s6 <- result_try(configure_slack(s5))
  use s7 <- result_try(configure_mattermost(s6))
  use s8 <- result_try(configure_wechat_work(s7))
  configure_whatsapp(s8)
}

/// Helper to chain Result operations with use syntax
fn result_try(
  result: Result(a, WizardError),
  continue: fn(a) -> Result(b, WizardError),
) -> Result(b, WizardError) {
  case result {
    Ok(value) -> continue(value)
    Error(e) -> Error(e)
  }
}

// ============================================================================
// Main Entry Point
// ============================================================================

/// Run the interactive setup wizard.
///
/// Guides the user through channel token setup and generates
/// a supernova.yaml file with the collected configuration.
pub fn run() -> Result(Nil, WizardError) {
  print_banner()

  io.println("This wizard will help you configure your Supernova bot.")
  io.println("Press Ctrl+C at any time to cancel.")
  io.println("")

  // Ask for app name
  use app_name <- result_try(ask_with_default("Application name", "my-bot"))

  let state = WizardState(..empty_state(), app_name: string.trim(app_name))

  // Ask which platform
  use platform <- result_try(ask_platform())

  // Configure selected platform(s)
  use state <- result_try(case platform {
    PlatformDiscord -> configure_discord(state)
    PlatformTelegram -> configure_telegram(state)
    PlatformMatrix -> configure_matrix(state)
    PlatformLark -> configure_lark(state)
    PlatformGoogleChat -> configure_google_chat(state)
    PlatformSlack -> configure_slack(state)
    PlatformMattermost -> configure_mattermost(state)
    PlatformWechatWork -> configure_wechat_work(state)
    PlatformWhatsApp -> configure_whatsapp(state)
    PlatformAll -> configure_all_channels(state)
  })

  // Ask for LLM provider configuration
  use provider <- result_try(ask_provider())
  let state = WizardState(..state, provider_key: Some(provider))

  use api_key <- result_try(ask_provider_api_key(provider))
  let state = case api_key {
    "" -> state
    key -> WizardState(..state, provider_api_key: Some(key))
  }

  use model <- result_try(ask_model(provider))
  let state = case model {
    "" -> state
    m -> WizardState(..state, model: Some(m))
  }

  use memory_backend <- result_try(ask_memory_backend())
  let state = WizardState(..state, memory_backend: Some(memory_backend))

  // Ask for output file path
  print_section("Generate Configuration")
  use output_path <- result_try(ask_with_default(
    "Output file path",
    "supernova.yaml",
  ))

  let final_state = WizardState(..state, output_path: string.trim(output_path))

  // Generate and write the YAML
  let yaml_content = generate_yaml(final_state)

  io.println("")
  io.println("Generated configuration:")
  io.println("────────────────────────")
  io.println(yaml_content)
  io.println("────────────────────────")

  case write_file_ffi(final_state.output_path, yaml_content) {
    Ok(Nil) -> {
      io.println("")
      io.println("Configuration written to: " <> final_state.output_path)
      io.println("")
      io.println("Next steps:")
      io.println("  1. Review " <> final_state.output_path)
      io.println("  2. Run: gleam run")
      io.println("")
      Ok(Nil)
    }
    Error(msg) -> Error(FileWriteError(msg))
  }
}
