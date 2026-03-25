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
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import supernova/core/checkpoint/actor as checkpoint_actor
import supernova/core/checkpoint/types as checkpoint_types
import supernova/core/turn_outcome
import supernova/llm/client
import supernova/llm/provider
import supernova/llm/stream
import supernova/tools/file_system
import supernova/tools/git_inspect
import supernova/tools/safe_shell
import supernova/tools/web

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

/// Built-in tool definitions wired by the executor.
pub fn builtin_tools() -> List(provider.ToolDefinition) {
  [safe_shell.tool(), web.tool(), git_inspect.tool(), file_system.tool()]
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
  tools: List(provider.ToolDefinition),
) -> List(provider.ChatMessage) {
  list.map(calls, fn(call) {
    let content = execute_single_tool_call(call, tools)
    provider.tool_result_message(call.id, content)
  })
}

/// Expose tool execution for unit tests.
pub fn execute_tool_calls_for_test(
  calls: List(provider.ToolCall),
  tools: List(provider.ToolDefinition),
) -> List(provider.ChatMessage) {
  execute_tool_calls(calls, tools)
}

fn execute_single_tool_call(
  call: provider.ToolCall,
  tools: List(provider.ToolDefinition),
) -> String {
  case is_declared_tool(call.name, tools) {
    False -> "ERROR: Tool '" <> call.name <> "' is not declared for this turn"
    True ->
      case dispatch_builtin_tool(call.name, call.arguments) {
        Ok(result) -> result
        Error(reason) -> "ERROR: " <> reason
      }
  }
}

fn is_declared_tool(name: String, tools: List(provider.ToolDefinition)) -> Bool {
  list.any(tools, fn(tool) { tool.name == name })
}

fn dispatch_builtin_tool(
  name: String,
  args_json: String,
) -> Result(String, String) {
  case name {
    "safe_shell" -> execute_safe_shell(args_json)
    "web_fetch" -> execute_web_fetch(args_json)
    "git_inspect" -> execute_git_inspect(args_json)
    "file_system" -> execute_file_system(args_json)
    _ -> Error("Tool '" <> name <> "' is not wired in executor")
  }
}

type SafeShellArgs {
  SafeShellArgs(command: String)
}

type WebFetchArgs {
  WebFetchArgs(url: String)
}

type GitInspectArgs {
  GitInspectArgs(action: String)
}

type FileSystemArgs {
  FileSystemArgs(action: String, path: String, content: String)
}

fn safe_shell_args_decoder() -> decode.Decoder(SafeShellArgs) {
  use command <- decode.field("command", decode.string)
  decode.success(SafeShellArgs(command: command))
}

fn web_fetch_args_decoder() -> decode.Decoder(WebFetchArgs) {
  use url <- decode.field("url", decode.string)
  decode.success(WebFetchArgs(url: url))
}

fn git_inspect_alias_args_decoder() -> decode.Decoder(GitInspectArgs) {
  use action <- decode.field("command", decode.string)
  decode.success(GitInspectArgs(action: action))
}

fn git_inspect_args_decoder() -> decode.Decoder(GitInspectArgs) {
  use action <- decode.field("action", decode.string)
  decode.success(GitInspectArgs(action: action))
}

fn file_system_args_decoder() -> decode.Decoder(FileSystemArgs) {
  use action <- decode.field("action", decode.string)
  use path <- decode.field("path", decode.string)
  use content <- decode.optional_field("content", "", decode.string)
  decode.success(FileSystemArgs(action: action, path: path, content: content))
}

fn execute_safe_shell(args_json: String) -> Result(String, String) {
  case json.parse(from: args_json, using: safe_shell_args_decoder()) {
    Error(_) -> Error("Invalid arguments for safe_shell")
    Ok(SafeShellArgs(command)) -> safe_shell.execute(command)
  }
}

fn execute_web_fetch(args_json: String) -> Result(String, String) {
  case json.parse(from: args_json, using: web_fetch_args_decoder()) {
    Error(_) -> Error("Invalid arguments for web_fetch")
    Ok(WebFetchArgs(url)) -> web.fetch(url)
  }
}

fn execute_git_inspect(args_json: String) -> Result(String, String) {
  let parsed = case
    json.parse(from: args_json, using: git_inspect_args_decoder())
  {
    Ok(args) -> Ok(args)
    Error(_) ->
      json.parse(from: args_json, using: git_inspect_alias_args_decoder())
  }
  case parsed {
    Error(_) -> Error("Invalid arguments for git_inspect")
    Ok(GitInspectArgs(action)) ->
      case string.lowercase(string.trim(action)) {
        "status" -> git_inspect.status()
        "log" -> git_inspect.log()
        "branch" -> git_inspect.branch()
        _ -> Error("git_inspect action must be status, log, or branch")
      }
  }
}

fn execute_file_system(args_json: String) -> Result(String, String) {
  case json.parse(from: args_json, using: file_system_args_decoder()) {
    Error(_) -> Error("Invalid arguments for file_system")
    Ok(FileSystemArgs(action, path, content)) ->
      case string.lowercase(string.trim(action)) {
        "read" -> file_system.read(".", path)
        "write" ->
          case file_system.write(".", path, content) {
            Ok(Nil) -> Ok("ok")
            Error(reason) -> Error(reason)
          }
        "list" ->
          case file_system.list(".", path) {
            Ok(entries) -> Ok(string.join(entries, "\n"))
            Error(reason) -> Error(reason)
          }
        _ -> Error("file_system action must be read, write, or list")
      }
  }
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
