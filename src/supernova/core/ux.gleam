//// UX — help text and user-facing messages.
////
//// Provides channel-specific help text for Supernova.

/// Get help text for a specific channel.
pub fn help_text(channel: String) -> String {
  let base = "Supernova AI Agent Framework\n\n"

  let commands = case channel {
    "discord" ->
      "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/model - Change LLM model\n"
      <> "/project - Start project wizard\n"
    "telegram" ->
      "Commands:\n"
      <> "/start - Start a new session\n"
      <> "/help - Show this help\n"
      <> "/status - Show session status\n"
      <> "/commands - List all commands\n"
      <> "/reasoning - Toggle reasoning mode\n"
      <> "/model - Change LLM model\n"
    "matrix" ->
      "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/model - Change LLM model\n"
    "lark" ->
      "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/model - Change LLM model\n"
    "google_chat" ->
      "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/model - Change LLM model\n"
    "slack" ->
      "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/model - Change LLM model\n"
    "mattermost" ->
      "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/model - Change LLM model\n"
    "wechat_work" ->
      "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/model - Change LLM model\n"
    "whatsapp" ->
      "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/model - Change LLM model\n"
    _ ->
      "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
  }

  base <> commands
}


/// Get the full commands list for a specific channel.
pub fn commands_text(channel: String) -> String {
  let base = "Available Commands\n\n"
  let channel_commands = case channel {
    "telegram" ->
      "Slash Commands:\n"
      <> "/start - Start a new session\n"
      <> "/help - Show this help\n"
      <> "/status - Show session status\n"
      <> "/model - Change LLM model\n"
      <> "/commands - List all commands\n"
      <> "/reasoning - Toggle reasoning mode\n"
    _ ->
      "Slash Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/model - Change LLM model\n"
  }
  let tools = "\nTools (via natural language):\n"
    <> "Browse web pages and interact with websites\n"
    <> "Read, write and manage files\n"
    <> "Execute shell commands\n"
    <> "Manage git repositories\n"
    <> "Fetch web content from URLs\n"
    <> "Search code across repositories\n"
    <> "Inspect running processes\n"
    <> "Create and manage canvas notes\n"
    <> "Access kernel operations (gateway)"
  base <> channel_commands <> tools
}

/// Get the reasoning mode description.
pub fn reasoning_text() -> String {
  "Reasoning Mode\n\n"
  <> "When reasoning mode is enabled, the agent shows its chain-of-thought\n"
  <> "before giving the final answer. This helps you follow the agent's logic.\n\n"
  <> "Toggle it with /reasoning.\n\n"
  <> "Currently: reasoning content is shown when available in model responses."
}
