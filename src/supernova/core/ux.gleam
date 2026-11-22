//// UX — help text and user-facing messages.
////
//// Provides channel-specific help text for Supernova.

import gleam/string
import supernova/channel/catalog

pub type Command {
  Menu
  Status
  Models
  NewSession
  ResetIdentity
  Help
  Ping
  Think
}

pub fn resolve_shortcut(input: String) -> Result(Command, Nil) {
  let normalized =
    input
    |> string.trim
    |> string.lowercase
  let normalized = case string.starts_with(normalized, "/") {
    True -> string.drop_start(normalized, 1)
    False -> normalized
  }

  case normalized {
    "help" | "ajuda" | "?" -> Ok(Help)
    "menu" | "inicio" | "início" | "commands" -> Ok(Menu)
    "modelo" | "modelos" | "models" | "model" -> Ok(Models)
    "novo" | "new" | "reset" | "start" -> Ok(NewSession)
    "status" | "estado" -> Ok(Status)
    "ping" -> Ok(Ping)
    "pensa" | "think" | "raciocina" | "reasoning" -> Ok(Think)
    "reset-identity" -> Ok(ResetIdentity)
    _ -> Error(Nil)
  }
}

/// Get help text for a specific channel.
pub fn help_text(channel: String) -> String {
  let base = "Supernova AI Agent Framework\n\n"

  let commands = catalog.get(channel).help_commands

  base <> commands
}

/// Get the full commands list for a specific channel.
pub fn commands_text(channel: String) -> String {
  let base = "Available Commands\n\n"
  let channel_commands = catalog.get(channel).command_list
  let tools =
    "\nTools (via natural language):\n"
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
