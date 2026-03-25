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
