//// Prompt Assembly — composes prompts from history and context.
////
//// Prepares the message list for LLM calls by adding system context
//// and managing history length.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/core/context_injector
import supernova/core/persona/types as persona_types
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

/// Build the full companion-agent system context with all available blocks.
pub fn build_companion_system_context(
  workspace_path workspace_path: String,
  persona persona: Option(persona_types.PersonaFiles),
  self_state_block self_state_block: Option(String),
  lessons_block lessons_block: List(String),
  relationship_block relationship_block: Option(String),
  world_model_facts world_model_facts: String,
) -> String {
  let persona_text = case persona {
    Some(files) ->
      "# IDENTIDADE\n"
      <> files.identity
      <> "\n\n## ALMA E VALORES:\n"
      <> files.soul
      <> "\n\n## USUÁRIO:\n"
      <> files.user
      <> "\n\n## ESTILO DE COMUNICAÇÃO:\n"
      <> files.style
    None ->
      "# IDENTIDADE\nBootstrap pendente.\n\n"
      <> "## ALMA E VALORES:\nBootstrap pendente.\n\n"
      <> "## USUÁRIO:\nBootstrap pendente.\n\n"
      <> "## ESTILO DE COMUNICAÇÃO:\nBootstrap pendente."
  }

  let self_state_text = case self_state_block {
    Some(block) -> "\n\n## ESTADO ATUAL:\n" <> block
    None -> ""
  }

  let lessons_text = case lessons_block {
    [] -> ""
    _ ->
      "\n\n## LIÇÕES RECENTES (Auto-melhoria):\n"
      <> format_lessons(lessons_block, 1)
  }

  let relationship_text = case relationship_block {
    Some(block) -> "\n\n## PROXIMIDADE COM O USUÁRIO:\n" <> block
    None -> ""
  }

  persona_text
  <> self_state_text
  <> lessons_text
  <> relationship_text
  <> "\n\n## WORKSPACE:\n"
  <> workspace_path
  <> "\n\n## CONTEXTO DO WORLD MODEL:\n"
  <> world_model_facts
}

fn format_lessons(lessons: List(String), idx: Int) -> String {
  case lessons {
    [] -> ""
    [lesson, ..rest] -> {
      let item = int.to_string(idx) <> ". " <> string.trim(lesson)
      case rest {
        [] -> item
        _ -> item <> "\n" <> format_lessons(rest, idx + 1)
      }
    }
  }
}
