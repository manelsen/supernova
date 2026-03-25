//// Executor — the agent execution loop.
////
//// Runs the core agent cycle: input → LLM → tool_call? → execute → loop.
//// Handles recursion depth, tool dispatch, and result aggregation.
////
//// ## Usage
////
//// ```gleam
//// let messages = [provider.user_message("Hello")]
//// let config = provider.ProviderConfig(name: "openai", ...)
//// let result = executor.run(messages, config, tools)
//// ```

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import supernova/core/checkpoint/actor as checkpoint_actor
import supernova/core/checkpoint/types as checkpoint_types
import supernova/core/turn_outcome
import supernova/llm/client
import supernova/llm/provider
import supernova/llm/stream

// ============================================================================
// Constants
// ============================================================================

const max_recursion_depth = 25

// ============================================================================
// Types
// ============================================================================

/// Executor result.
pub type ExecutorResult {
  ExecutorResult(
    /// Response role
    role: String,
    /// Response content
    content: String,
    /// Number of turns taken
    turns: Int,
  )
}

/// Executor error.
pub type ExecutorError {
  /// Max recursion depth exceeded
  MaxDepthExceeded(depth: Int)
  /// LLM error
  LLMError(reason: provider.LLMError)
  /// Tool execution error
  ToolError(name: String, reason: String)
  /// Agent was paused by scheduler for cooperative preemption
  YieldPaused(checkpoint_id: String)
  /// Agent was aborted by scheduler
  YieldAborted(reason: String)
}

// ============================================================================
// Yield / Checkpoint
// ============================================================================

/// Configuration for cooperative yield integration.
pub type YieldConfig {
  YieldConfig(
    /// Session identifier for this execution
    session_id: String,
    /// Checkpoint store actor handle
    checkpoint_store: checkpoint_actor.CheckpointHandle,
    /// How often to check for yield (in iterations)
    yield_interval: Int,
  )
}

// ============================================================================
// Public API
// ============================================================================

/// Run the executor loop.
///
/// Takes messages, provider config, and available tools.
/// Returns the final response after the agent loop completes.
pub fn run(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, ExecutorError) {
  run_loop(messages, config, tools, 0)
}

/// Run the executor loop with cooperative yield support.
///
/// At every `yield_config.yield_interval` iterations, consults the checkpoint
/// store for a yield decision. On Pause: saves checkpoint, returns YieldPaused.
/// On Abort: returns YieldAborted immediately.
pub fn run_with_checkpoint(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
  yield_config: YieldConfig,
) -> Result(provider.ChatResponse, ExecutorError) {
  run_loop_with_checkpoint(messages, config, tools, 0, yield_config)
}

// ============================================================================
// Internal Loop
// ============================================================================

/// Recursive execution loop.
fn run_loop(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
  depth: Int,
) -> Result(provider.ChatResponse, ExecutorError) {
  // Check recursion depth
  case depth > max_recursion_depth {
    True -> Error(MaxDepthExceeded(depth: depth))
    False -> {
      // Call LLM
      case client.chat(messages, config, tools) {
        Ok(response) -> {
          // Classify the outcome
          let outcome = turn_outcome.classify(response)

          case outcome {
            turn_outcome.TextResponse -> Ok(response)
            turn_outcome.ToolCall(calls) -> {
              // Execute tool calls and add results to history
              let tool_results = execute_tool_calls(calls, tools)
              let updated_history =
                list.append(messages, [
                  provider.assistant_message_with_tools(response.content, calls),
                ])
              let history_with_results =
                list.append(updated_history, tool_results)

              // Recurse
              run_loop(history_with_results, config, tools, depth + 1)
            }
            turn_outcome.Empty -> Ok(response)
            turn_outcome.Error(msg) ->
              Error(
                LLMError(reason: provider.APIError(status: 0, message: msg)),
              )
          }
        }
        Error(err) -> Error(LLMError(reason: err))
      }
    }
  }
}

/// Execute tool calls and return result messages.
fn execute_tool_calls(
  calls: List(provider.ToolCall),
  _tools: List(provider.ToolDefinition),
) -> List(provider.ChatMessage) {
  list.map(calls, fn(call) {
    // For now, return a placeholder result
    // In a real implementation, this would dispatch to the tool registry
    provider.tool_result_message(
      call.id,
      "Tool '" <> call.name <> "' executed with args: " <> call.arguments,
    )
  })
}

// ============================================================================
// Checkpoint Loop
// ============================================================================

/// Recursive execution loop with cooperative yield checking.
fn run_loop_with_checkpoint(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
  depth: Int,
  yield_config: YieldConfig,
) -> Result(provider.ChatResponse, ExecutorError) {
  // Check recursion depth
  case depth > max_recursion_depth {
    True -> Error(MaxDepthExceeded(depth: depth))
    False -> {
      // Check yield every N iterations (not at depth 0)
      let should_check_yield =
        depth > 0 && depth % yield_config.yield_interval == 0
      case should_check_yield {
        True -> {
          let decision =
            checkpoint_actor.should_yield(
              yield_config.checkpoint_store,
              yield_config.session_id,
            )
          case decision {
            checkpoint_types.Continue ->
              run_loop_inner_with_checkpoint(
                messages,
                config,
                tools,
                depth,
                yield_config,
              )
            checkpoint_types.Pause(_reason) -> {
              // Save checkpoint before pausing
              let metadata =
                dict.from_list([
                  #("paused_at_depth", int.to_string(depth)),
                ])
              case
                checkpoint_actor.save(
                  yield_config.checkpoint_store,
                  yield_config.session_id,
                  messages,
                  None,
                  metadata,
                )
              {
                Ok(checkpoint_id) -> Error(YieldPaused(checkpoint_id:))
                Error(_) -> Error(YieldPaused(checkpoint_id: "unknown"))
              }
            }
            checkpoint_types.Abort(reason) -> Error(YieldAborted(reason:))
          }
        }
        False ->
          run_loop_inner_with_checkpoint(
            messages,
            config,
            tools,
            depth,
            yield_config,
          )
      }
    }
  }
}

/// Inner loop body shared between yield-check and no-yield-check paths.
fn run_loop_inner_with_checkpoint(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
  depth: Int,
  yield_config: YieldConfig,
) -> Result(provider.ChatResponse, ExecutorError) {
  case client.chat(messages, config, tools) {
    Ok(response) -> {
      let outcome = turn_outcome.classify(response)
      case outcome {
        turn_outcome.TextResponse -> Ok(response)
        turn_outcome.ToolCall(calls) -> {
          let tool_results = execute_tool_calls(calls, tools)
          let updated_history =
            list.append(messages, [
              provider.assistant_message_with_tools(response.content, calls),
            ])
          let history_with_results = list.append(updated_history, tool_results)
          run_loop_with_checkpoint(
            history_with_results,
            config,
            tools,
            depth + 1,
            yield_config,
          )
        }
        turn_outcome.Empty -> Ok(response)
        turn_outcome.Error(msg) ->
          Error(LLMError(reason: provider.APIError(status: 0, message: msg)))
      }
    }
    Error(err) -> Error(LLMError(reason: err))
  }
}

// ============================================================================
// Streaming API
// ============================================================================

/// Run the executor in streaming mode.
///
/// Returns a Subject that receives StreamChunk messages as the LLM generates
/// responses. The stream emits partial text chunks as they arrive, allowing
/// real-time display of responses.
pub fn run_stream(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Subject(stream.StreamChunk) {
  stream.start_stream_with_tools(messages, config, tools)
}

/// Run the executor in streaming mode with a mock provider.
///
/// For testing: emits chunks synchronously from a mock response.
pub fn run_stream_mock(
  _messages: List(provider.ChatMessage),
  _config: provider.ProviderConfig,
  _tools: List(provider.ToolDefinition),
) -> Subject(stream.StreamChunk) {
  let subject = process.new_subject()

  // Simulate streaming by sending text chunks
  let mock_chunks = [
    stream.TextChunk(content: "Mock "),
    stream.TextChunk(content: "streaming "),
    stream.TextChunk(content: "response"),
    stream.Done,
  ]

  list.each(mock_chunks, fn(chunk) { process.send(subject, chunk) })

  subject
}
