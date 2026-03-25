//// Turn Outcome — classifies LLM responses.
////
//// Determines what to do with an LLM response:
//// text reply, tool calls, empty, or error.

import gleam/option.{None, Some}
import supernova/llm/provider

/// Classification of an LLM response.
pub type TurnOutcome {
  /// Plain text response — agent is done
  TextResponse
  /// LLM wants to call tools
  ToolCall(calls: List(provider.ToolCall))
  /// Empty response
  Empty
  /// Error in response
  Error(message: String)
}

/// Classify a ChatResponse into a TurnOutcome.
pub fn classify(response: provider.ChatResponse) -> TurnOutcome {
  case response.tool_calls {
    Some(calls) -> {
      case calls {
        [] -> check_content(response.content)
        _ -> ToolCall(calls: calls)
      }
    }
    None -> check_content(response.content)
  }
}

/// Check if content is empty or has text.
fn check_content(content: String) -> TurnOutcome {
  case content {
    "" -> Empty
    _ -> TextResponse
  }
}
