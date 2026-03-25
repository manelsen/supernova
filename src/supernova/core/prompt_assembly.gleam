//// Prompt Assembly — composes prompts from history and context.
////
//// Prepares the message list for LLM calls by adding system context
//// and managing history length.

import gleam/list
import supernova/core/context_injector
import supernova/core/world_model/types.{type WorldModelState}
import supernova/llm/provider

/// Prepare messages for an LLM call.
///
/// Adds system context (time, workspace) and ensures history fits.
pub fn prepare(
  messages: List(provider.ChatMessage),
  system_context: String,
) -> List(provider.ChatMessage) {
  let system_msg = provider.system_message(system_context)

  // Prepend system message if not already present
  case messages {
    [first, ..] if first.role == "system" -> messages
    _ -> [system_msg, ..messages]
  }
}

/// Truncate history to fit within token limits.
///
/// Keeps the system message and most recent messages.
pub fn truncate(
  messages: List(provider.ChatMessage),
  max_messages: Int,
) -> List(provider.ChatMessage) {
  case messages {
    [system, ..rest] if system.role == "system" -> {
      let truncated = list.take(rest, max_messages - 1)
      [system, ..truncated]
    }
    _ -> list.take(messages, max_messages)
  }
}

/// Prepare messages for an LLM call, injecting WorldModel facts into context.
///
/// Queries `world_state` for facts relevant to `session_topic` and prepends
/// them to `system_context` before assembling the message list.
/// `token_budget` limits how many tokens the injected facts may consume.
pub fn prepare_with_world_model(
  messages: List(provider.ChatMessage),
  system_context: String,
  world_state: WorldModelState,
  session_topic: String,
  token_budget: Int,
) -> List(provider.ChatMessage) {
  let enriched =
    context_injector.inject(
      world_state,
      system_context,
      session_topic,
      token_budget,
    )
  prepare(messages, enriched)
}

/// Build a system context string with current info.
pub fn build_system_context(
  workspace_path: String,
  additional: String,
) -> String {
  "Workspace: " <> workspace_path <> "\n" <> additional
}
