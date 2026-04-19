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
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/budget_policy/types as budget_types
import supernova/core/checkpoint/actor as checkpoint_actor
import supernova/core/checkpoint/types as checkpoint_types
import supernova/core/complexity_router
import supernova/core/turn_outcome
import supernova/llm/circuit_breaker/actor as cb_actor
import supernova/llm/circuit_breaker/global as cb_global
import supernova/llm/client
import supernova/llm/provider
import supernova/llm/retry/types as retry
import supernova/llm/stream
import supernova/metrics/actor as metrics_actor
import supernova/metrics/global as metrics_global
import supernova/tools/browser
import supernova/tools/canvas
import supernova/tools/file_system
import supernova/tools/gateway
import supernova/tools/git_inspect
import supernova/tools/github
import supernova/tools/process as process_tool
import supernova/tools/safe_shell
import supernova/tools/web
import supernova/tracing/global as tracing_global
import supernova/tracing/types as tracing_types

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int

// ============================================================================
// Constants
// ============================================================================

const max_recursion_depth = 25

const default_retry_config = retry.RetryConfig(
  initial_delay_ms: 1000,
  max_delay_ms: 30_000,
  max_attempts: 3,
  jitter_factor: 0.2,
)

fn record_llm_latency(provider_name: String, model: String, latency_ms: Int) {
  case metrics_global.get_metrics() {
    option.Some(metrics) -> {
      let labels = [#("provider", provider_name), #("model", model)]
      metrics_actor.observe_histogram(
        metrics,
        "llm_request_duration_ms",
        int.to_float(latency_ms),
        labels,
      )
      metrics_actor.inc_counter(metrics, "llm_requests_total", [
        #("provider", provider_name),
        #("model", model),
        #("status", "success"),
      ])
    }
    option.None -> Nil
  }
}

fn record_llm_error(provider_name: String, model: String, error_type: String) {
  case metrics_global.get_metrics() {
    option.Some(metrics) ->
      metrics_actor.inc_counter(metrics, "llm_requests_total", [
        #("provider", provider_name),
        #("model", model),
        #("status", "error"),
        #("error_type", error_type),
      ])
    option.None -> Nil
  }
}

fn record_complexity_selection(
  score: Float,
  tier: complexity_router.ComplexityTier,
  model_used: String,
) {
  case metrics_global.get_metrics() {
    option.Some(metrics) -> {
      metrics_actor.observe_histogram(metrics, "complexity_score", score, [
        #("tier", complexity_router.tier_to_string(tier)),
      ])
      metrics_actor.inc_counter(metrics, "complexity_selected_tier_total", [
        #("tier", complexity_router.tier_to_string(tier)),
        #("model_used", model_used),
        #("complexity_score", float.to_string(score)),
      ])
    }
    option.None -> Nil
  }
}

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
    /// Optional wall-clock timeout for this execution
    timeout_ms: Option(Int),
    /// Start timestamp for timeout tracking
    started_at_ms: Int,
    /// Optional budget policy used to cooperatively pause on exhaustion
    budget_policy: Option(budget_actor.BudgetPolicy),
    /// Agent/session identity used against the budget policy
    budget_agent_id: Option(String),
  )
}

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

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
  [
    safe_shell.tool(),
    browser.tool(),
    canvas.tool(),
    gateway.tool(),
    process_tool.tool(),
    github.tool(),
    web.tool(),
    git_inspect.tool(),
    file_system.tool(),
  ]
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

/// Request a cooperative manual pause for the current session.
pub fn request_manual_pause(yield_config: YieldConfig, reason: String) -> Nil {
  checkpoint_actor.force_yield(
    yield_config.checkpoint_store,
    yield_config.session_id,
    checkpoint_types.Pause("manual:" <> reason),
  )
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
      let decision =
        complexity_router.route(config, messages, list.length(tools), depth)
      let selected_config = decision.selected_config
      record_complexity_selection(
        decision.score,
        decision.tier,
        selected_config.default_model,
      )
      // Call LLM with metrics
      let start = current_timestamp()
      case
        retry.with_retry(default_retry_config, fn() {
          with_llm_span(
            selected_config.name,
            selected_config.default_model,
            depth,
            fn() { client.chat(messages, selected_config, tools) },
          )
        })
      {
        Ok(response) -> {
          let elapsed = current_timestamp() - start
          record_llm_latency(
            selected_config.name,
            selected_config.default_model,
            elapsed,
          )
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
        Error(err) -> {
          record_llm_error(
            selected_config.name,
            selected_config.default_model,
            error_type_name(err),
          )
          Error(LLMError(reason: err))
        }
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
  let decision =
    complexity_router.route(config, messages, list.length(tools), depth)
  let selected_config = decision.selected_config
  record_complexity_selection(
    decision.score,
    decision.tier,
    selected_config.default_model,
  )
  let start = current_timestamp()
  case
    retry.with_retry(default_retry_config, fn() {
      with_llm_span(
        selected_config.name,
        selected_config.default_model,
        depth,
        fn() { client.chat(messages, selected_config, tools) },
      )
    })
  {
    Ok(response) -> {
      let elapsed = current_timestamp() - start
      record_llm_latency(
        selected_config.name,
        selected_config.default_model,
        elapsed,
      )
      let outcome = turn_outcome.classify(response)
      case outcome {
        turn_outcome.TextResponse -> Ok(response)
        turn_outcome.ToolCall(calls) -> {
          let updated_history =
            list.append(messages, [
              provider.assistant_message_with_tools(response.content, calls),
            ])
          case
            maybe_consume_tool_budget(
              updated_history,
              calls,
              depth,
              yield_config,
            )
          {
            Ok(Nil) -> {
              let tool_results = execute_tool_calls(calls, tools)
              let history_with_results =
                list.append(updated_history, tool_results)
              run_loop_with_checkpoint(
                history_with_results,
                config,
                tools,
                depth + 1,
                yield_config,
              )
            }
            Error(error) -> Error(error)
          }
        }
        turn_outcome.Empty -> Ok(response)
        turn_outcome.Error(msg) ->
          Error(LLMError(reason: provider.APIError(status: 0, message: msg)))
      }
    }
    Error(err) -> {
      record_llm_error(
        selected_config.name,
        selected_config.default_model,
        error_type_name(err),
      )
      Error(LLMError(reason: err))
    }
  }
}

fn error_type_name(err: provider.LLMError) -> String {
  case err {
    provider.APIError(_, _) -> "api_error"
    provider.NetworkError(_) -> "network_error"
    provider.ConfigError(_) -> "config_error"
    provider.ProviderNotFound(_) -> "provider_not_found"
    provider.NotImplemented(_) -> "not_implemented"
    provider.CircuitOpen(_) -> "circuit_open"
  }
}

fn with_llm_span(
  provider: String,
  model: String,
  depth: Int,
  f: fn() -> Result(provider.ChatResponse, provider.LLMError),
) -> Result(provider.ChatResponse, provider.LLMError) {
  case cb_global.check_and_call(provider) {
    cb_actor.Blocked(_) -> {
      Error(provider.CircuitOpen(provider: provider))
    }
    cb_actor.Allowed -> {
      case
        tracing_global.start_span(
          "llm.chat",
          tracing_types.SpanKindClient,
          option.None,
        )
      {
        option.Some(span) -> {
          tracing_global.set_span_attributes(span, [
            #("provider", provider),
            #("model", model),
            #("depth", int.to_string(depth)),
          ])
          let result = f()
          case result {
            Ok(_) -> {
              cb_global.record_success(provider)
              tracing_global.end_span(span, tracing_types.SpanStatusOk)
            }
            Error(err) -> {
              cb_global.record_failure(provider)
              tracing_global.end_span(
                span,
                tracing_types.SpanStatusError(error_type_name(err)),
              )
            }
          }
          result
        }
        option.None -> {
          let result = f()
          case result {
            Ok(_) -> cb_global.record_success(provider)
            Error(_) -> cb_global.record_failure(provider)
          }
          result
        }
      }
    }
  }
}

fn with_tool_span(tool_name: String, f: fn() -> String) -> String {
  case
    tracing_global.start_span(
      "tool.execute",
      tracing_types.SpanKindInternal,
      option.None,
    )
  {
    option.Some(span) -> {
      tracing_global.set_span_attributes(span, [#("tool", tool_name)])
      let result = f()
      case string.starts_with(result, "ERROR:") {
        True ->
          tracing_global.end_span(
            span,
            tracing_types.SpanStatusError("tool_error"),
          )
        False -> tracing_global.end_span(span, tracing_types.SpanStatusOk)
      }
      result
    }
    option.None -> f()
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
    False -> {
      record_tool_error(call.name)
      "ERROR: Tool '" <> call.name <> "' is not declared for this turn"
    }
    True -> {
      let start = current_timestamp()
      with_tool_span(call.name, fn() {
        case dispatch_builtin_tool(call.name, call.arguments) {
          Ok(result) -> {
            let elapsed = current_timestamp() - start
            record_tool_latency(call.name, elapsed)
            result
          }
          Error(reason) -> {
            record_tool_error(call.name)
            "ERROR: " <> reason
          }
        }
      })
    }
  }
}

fn record_tool_latency(tool_name: String, latency_ms: Int) {
  case metrics_global.get_metrics() {
    option.Some(metrics) -> {
      metrics_actor.observe_histogram(
        metrics,
        "tool_execution_duration_ms",
        int.to_float(latency_ms),
        [#("tool", tool_name)],
      )
      metrics_actor.inc_counter(metrics, "tool_executions_total", [
        #("tool", tool_name),
        #("status", "success"),
      ])
    }
    option.None -> Nil
  }
}

fn record_tool_error(tool_name: String) {
  case metrics_global.get_metrics() {
    option.Some(metrics) ->
      metrics_actor.inc_counter(metrics, "tool_executions_total", [
        #("tool", tool_name),
        #("status", "error"),
      ])
    option.None -> Nil
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
    "browser" -> execute_browser(args_json)
    "canvas" -> execute_canvas(args_json)
    "gateway" -> execute_gateway(args_json)
    "process" -> execute_process(args_json)
    "github" -> execute_github(args_json)
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

fn execute_browser(args_json: String) -> Result(String, String) {
  browser.execute(args_json)
}

fn execute_canvas(args_json: String) -> Result(String, String) {
  canvas.execute(args_json)
}

fn execute_gateway(args_json: String) -> Result(String, String) {
  gateway.execute(args_json)
}

fn execute_process(args_json: String) -> Result(String, String) {
  process_tool.execute(args_json)
}

fn execute_github(args_json: String) -> Result(String, String) {
  github.execute(args_json)
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
      case maybe_pause_before_turn(messages, depth, yield_config) {
        Ok(Nil) ->
          run_loop_inner_with_checkpoint(
            messages,
            config,
            tools,
            depth,
            yield_config,
          )
        Error(error) -> Error(error)
      }
    }
  }
}

fn maybe_pause_before_turn(
  messages: List(provider.ChatMessage),
  depth: Int,
  yield_config: YieldConfig,
) -> Result(Nil, ExecutorError) {
  case maybe_pause_for_timeout(messages, depth, yield_config) {
    Error(error) -> Error(error)
    Ok(Nil) -> {
      let interval = normalize_yield_interval(yield_config.yield_interval)
      case depth % interval == 0 {
        False -> Ok(Nil)
        True -> {
          let decision =
            checkpoint_actor.should_yield(
              yield_config.checkpoint_store,
              yield_config.session_id,
            )
          case decision {
            checkpoint_types.Continue -> Ok(Nil)
            checkpoint_types.Pause(reason) -> {
              let #(kind, detail) = classify_pause_reason(reason)
              Error(save_pause_checkpoint(
                messages,
                None,
                depth,
                yield_config,
                kind,
                detail,
              ))
            }
            checkpoint_types.Abort(reason) ->
              Error(YieldAborted(reason: reason))
          }
        }
      }
    }
  }
}

fn maybe_pause_for_timeout(
  messages: List(provider.ChatMessage),
  depth: Int,
  yield_config: YieldConfig,
) -> Result(Nil, ExecutorError) {
  case yield_config.timeout_ms {
    None -> Ok(Nil)
    Some(timeout_ms) -> {
      let elapsed_ms = ffi_current_timestamp() - yield_config.started_at_ms
      case elapsed_ms >= timeout_ms {
        True ->
          Error(save_pause_checkpoint(
            messages,
            None,
            depth,
            yield_config,
            "timeout",
            "timeout exceeded",
          ))
        False -> Ok(Nil)
      }
    }
  }
}

fn maybe_consume_tool_budget(
  messages: List(provider.ChatMessage),
  calls: List(provider.ToolCall),
  depth: Int,
  yield_config: YieldConfig,
) -> Result(Nil, ExecutorError) {
  case calls {
    [] -> Ok(Nil)
    _ ->
      case yield_config.budget_policy, yield_config.budget_agent_id {
        Some(policy), Some(agent_id) -> {
          let amount = list.length(calls)
          case
            budget_actor.check(
              policy,
              agent_id,
              budget_types.BudgetToolCalls,
              amount,
            )
          {
            Ok(Nil) -> {
              budget_actor.record_consumption(
                policy,
                agent_id,
                budget_types.BudgetToolCalls,
                amount,
              )
              Ok(Nil)
            }
            Error(exceeded) ->
              Error(save_pause_checkpoint(
                messages,
                first_tool_call(calls),
                depth,
                yield_config,
                "budget_exhausted",
                exceeded.message,
              ))
          }
        }
        _, _ -> Ok(Nil)
      }
  }
}

fn save_pause_checkpoint(
  messages: List(provider.ChatMessage),
  pending_tool: Option(provider.ToolCall),
  depth: Int,
  yield_config: YieldConfig,
  reason_kind: String,
  reason_detail: String,
) -> ExecutorError {
  let metadata =
    dict.from_list([
      #("paused_at_depth", int.to_string(depth)),
      #("yield_reason", reason_kind),
      #("yield_detail", reason_detail),
    ])

  case
    checkpoint_actor.save(
      yield_config.checkpoint_store,
      yield_config.session_id,
      messages,
      pending_tool,
      metadata,
    )
  {
    Ok(checkpoint_id) -> YieldPaused(checkpoint_id: checkpoint_id)
    Error(_) -> YieldPaused(checkpoint_id: "unknown")
  }
}

fn classify_pause_reason(reason: String) -> #(String, String) {
  case string.starts_with(reason, "manual:") {
    True -> #("manual", string.drop_start(reason, 7))
    False ->
      case string.starts_with(reason, "timeout:") {
        True -> #("timeout", string.drop_start(reason, 8))
        False ->
          case string.starts_with(reason, "budget_exhausted:") {
            True -> #("budget_exhausted", string.drop_start(reason, 17))
            False -> #("external", reason)
          }
      }
  }
}

fn normalize_yield_interval(interval: Int) -> Int {
  int.max(1, interval)
}

fn first_tool_call(calls: List(provider.ToolCall)) -> Option(provider.ToolCall) {
  case calls {
    [first, ..] -> Some(first)
    [] -> None
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
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  _tools: List(provider.ToolDefinition),
) -> Subject(stream.StreamChunk) {
  let subject = process.new_subject()

  case latest_user_content(messages) {
    Some(content) ->
      case string.contains(content, "[stream-timeout]") {
        True -> Nil
        False ->
          case string.contains(content, "[stream-error]") {
            True ->
              process.send(
                subject,
                stream.StreamError(reason: "simulated mock stream error"),
              )
            False ->
              mock_stream_chunks(messages, config)
              |> list.each(fn(chunk) { process.send(subject, chunk) })
          }
      }
    None ->
      mock_stream_chunks(messages, config)
      |> list.each(fn(chunk) { process.send(subject, chunk) })
  }

  subject
}

fn mock_stream_chunks(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
) -> List(stream.StreamChunk) {
  case latest_user_content(messages) {
    Some(content) ->
      case string.contains(content, "[echo-model]") {
        True -> [
          stream.TextChunk(
            content: "Mock response via " <> config.default_model,
          ),
          stream.Done,
        ]
        False -> default_mock_stream_chunks()
      }
    None -> default_mock_stream_chunks()
  }
}

fn default_mock_stream_chunks() -> List(stream.StreamChunk) {
  [
    stream.TextChunk(content: "Mock "),
    stream.TextChunk(content: "streaming "),
    stream.TextChunk(content: "response"),
    stream.Done,
  ]
}

fn latest_user_content(messages: List(provider.ChatMessage)) -> Option(String) {
  latest_user_content_acc(messages, None)
}

fn latest_user_content_acc(
  messages: List(provider.ChatMessage),
  latest: Option(String),
) -> Option(String) {
  case messages {
    [] -> latest
    [message, ..rest] ->
      case message.role == "user" {
        True -> latest_user_content_acc(rest, Some(message.content))
        False -> latest_user_content_acc(rest, latest)
      }
  }
}
