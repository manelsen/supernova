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
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/budget_policy/types as budget_types
import supernova/core/checkpoint/actor as checkpoint_actor
import supernova/core/checkpoint/types as checkpoint_types
import supernova/core/complexity_router
import supernova/core/exception_guard
import supernova/core/prompt_log
import supernova/core/tool_dispatch
import supernova/core/tool_limits
import supernova/core/turn_outcome
import supernova/llm/circuit_breaker/actor as cb_actor
import supernova/llm/circuit_breaker/global as cb_global
import supernova/llm/client
import supernova/llm/provider
import supernova/llm/retry/types as retry
import supernova/llm/stream
import supernova/llm/tool_images
import supernova/metrics/actor as metrics_actor
import supernova/metrics/global as metrics_global
import supernova/tracing/global as tracing_global
import supernova/tracing/types as tracing_types

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int

// ============================================================================
// Constants
// ============================================================================

const max_recursion_depth = 25

const default_retry_config =
  retry.RetryConfig(
    initial_delay_ms: 1000,
    max_delay_ms: 30_000,
    max_attempts: 3,
    jitter_factor: 0.2,
  )

/// Publish the default model's request series at zero (see `record.declare`).
///
/// The error series are declared too, one per error type: the alert on
/// model failures counts them with `increase`, which misses a series' first
/// sample.
pub fn declare_metrics(provider_name: String, model: String) -> Nil {
  case metrics_global.get_metrics() {
    option.Some(metrics) -> {
      metrics_actor.add_counter(metrics, "llm_requests_total", 0, [
        #("provider", provider_name),
        #("model", model),
        #("status", "success"),
      ])
      list.each(error_type_names, fn(error_type) {
        metrics_actor.add_counter(metrics, "llm_requests_total", 0, [
          #("provider", provider_name),
          #("model", model),
          #("status", "error"),
          #("error_type", error_type),
        ])
      })
    }
    option.None -> Nil
  }
}

fn record_llm_latency(provider_name: String, model: String, latency_ms: Int) {
  case metrics_global.get_metrics() {
    option.Some(metrics) -> {
      let labels = [#("provider", provider_name), #("model", model)]
      metrics_actor.observe_histogram(
        metrics,
        "llm_request_duration_seconds",
        int.to_float(latency_ms) /. 1000.0,
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
  /// A kernel policy (access, budget, capability, instance cap) refused the turn
  PolicyDenied(message: String)
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

/// Context injected by the closed-group runtime for production turns.
///
/// `before_llm` runs before every provider call; `on_llm_usage` records the
/// estimated real usage after a successful call; `invoke_tool` routes every
/// tool call through the syscall gateway.
pub type RunContext {
  RunContext(
    principal_id: String,
    role: String,
    /// Why this agent is calling the model: turn, reflection, birth or drift.
    purpose: String,
    call_id_override: Option(String),
    before_llm: Option(fn() -> Result(Nil, String)),
    admit_llm: Option(fn(String, String, String, Int) -> Result(Nil, String)),
    on_llm_usage: Option(fn(String, String, String, Int, Int) -> Nil),
    on_llm_unconfirmed: Option(fn(String, String, String, Int) -> Nil),
    on_llm_failure: Option(fn(String) -> Nil),
    invoke_tool: Option(fn(String, String) -> Result(String, String)),
    on_tool_result: Option(fn(String, Bool) -> Nil),
  )
}

/// An empty context: no policy callbacks, tools run locally.
///
/// Only used when the closed-group runtime is not enforced (tests and
/// library use). The role defaults to the least privileged one.
pub fn empty_run_context() -> RunContext {
  RunContext(
    principal_id: "",
    role: "member",
    purpose: "turn",
    call_id_override: None,
    before_llm: None,
    admit_llm: None,
    on_llm_usage: None,
    on_llm_unconfirmed: None,
    on_llm_failure: None,
    invoke_tool: None,
    on_tool_result: None,
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
  run_loop(messages, config, tools, 0, empty_run_context())
}

/// Run the executor loop with kernel policy callbacks.
pub fn run_with_context(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
  context: RunContext,
) -> Result(provider.ChatResponse, ExecutorError) {
  run_loop(messages, config, tools, 0, context)
}

/// Built-in tool definitions wired by the executor.
pub fn builtin_tools() -> List(provider.ToolDefinition) {
  tool_dispatch.builtin_tools()
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
  run_loop_with_checkpoint(
    messages,
    config,
    tools,
    0,
    yield_config,
    empty_run_context(),
  )
}

/// Run the checkpoint loop with kernel policy callbacks.
pub fn run_with_checkpoint_and_context(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
  yield_config: YieldConfig,
  context: RunContext,
) -> Result(provider.ChatResponse, ExecutorError) {
  run_loop_with_checkpoint(messages, config, tools, 0, yield_config, context)
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
  context: RunContext,
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
      case before_llm(context) {
        Error(reason) -> Error(PolicyDenied(message: reason))
        Ok(Nil) -> {
          // Call LLM with metrics
          let start = current_timestamp()
          case
            run_provider_call(
              context,
              selected_config,
              messages,
              tools,
              depth,
              start,
            )
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
                  let tool_results = execute_tool_calls(calls, tools, context)
                  let updated_history =
                    list.append(messages, [
                      provider.assistant_message_with_tools(
                        response.content,
                        calls,
                      ),
                    ])
                  let history_with_results =
                    append_tool_round(updated_history, tool_results)

                  // Recurse
                  run_loop(
                    history_with_results,
                    config,
                    tools,
                    depth + 1,
                    context,
                  )
                }
                turn_outcome.Empty -> Ok(response)
                turn_outcome.Error(msg) ->
                  Error(
                    LLMError(reason: provider.APIError(status: 0, message: msg)),
                  )
              }
            }
            Error(error) -> Error(error)
          }
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
  context: RunContext,
) -> Result(provider.ChatResponse, ExecutorError) {
  let decision =
    complexity_router.route(config, messages, list.length(tools), depth)
  let selected_config = decision.selected_config
  record_complexity_selection(
    decision.score,
    decision.tier,
    selected_config.default_model,
  )
  case before_llm(context) {
    Error(reason) -> Error(PolicyDenied(message: reason))
    Ok(Nil) -> {
      let start = current_timestamp()
      case
        run_provider_call(
          context,
          selected_config,
          messages,
          tools,
          depth,
          start,
        )
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
                  let tool_results = execute_tool_calls(calls, tools, context)
                  let history_with_results =
                    append_tool_round(updated_history, tool_results)
                  run_loop_with_checkpoint(
                    history_with_results,
                    config,
                    tools,
                    depth + 1,
                    yield_config,
                    context,
                  )
                }
                Error(error) -> Error(error)
              }
            }
            turn_outcome.Empty -> Ok(response)
            turn_outcome.Error(msg) ->
              Error(
                LLMError(reason: provider.APIError(status: 0, message: msg)),
              )
          }
        }
        Error(error) -> Error(error)
      }
    }
  }
}

/// Every label `error_type_name` can return.
const error_type_names = [
  "api_error", "network_error", "config_error", "provider_not_found",
  "not_implemented", "circuit_open",
]

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
              record_breaker_outcome(provider, err)
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
            Error(err) -> record_breaker_outcome(provider, err)
          }
          result
        }
      }
    }
  }
}

/// Only errors that say the provider is unavailable count against its
/// breaker: network failures, 5xx and 429. A 4xx caused by the request (too
/// long a context, a bad parameter) says nothing about the provider, and must
/// not block every person's turns.
fn record_breaker_outcome(provider: String, err: provider.LLMError) -> Nil {
  case provider_unavailable(err) {
    True -> cb_global.record_failure(provider)
    False -> Nil
  }
}

pub fn provider_unavailable(err: provider.LLMError) -> Bool {
  case err {
    provider.NetworkError(_) -> True
    provider.APIError(status, _) -> status >= 500 || status == 429
    _ -> False
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

/// Run the pre-LLM policy hook.
fn before_llm(context: RunContext) -> Result(Nil, String) {
  case context.before_llm {
    None -> Ok(Nil)
    Some(check) -> check()
  }
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn next_call_id(depth: Int) -> String {
  "llm:"
  <> int.to_string(ffi_current_timestamp())
  <> ":"
  <> int.to_string(depth)
  <> ":"
  <> int.to_string(unique_integer())
}

fn admit_llm(
  context: RunContext,
  call_id: String,
  provider_name: String,
  model: String,
  prompt_tokens: Int,
) -> Result(Nil, String) {
  case context.admit_llm {
    None -> Ok(Nil)
    Some(admit) -> admit(call_id, provider_name, model, prompt_tokens)
  }
}

fn report_llm_failure(context: RunContext, call_id: String) -> Nil {
  case context.on_llm_failure {
    None -> Nil
    Some(report) -> report(call_id)
  }
}

/// Estimate tokens when a provider does not expose usage.
fn estimate_tokens(text: String) -> Int {
  int.max(1, string.length(text) / 4)
}

fn prompt_token_estimate(
  messages: List(provider.ChatMessage),
  tools: List(provider.ToolDefinition),
) -> Int {
  let message_tokens =
    messages
    |> list.map(message_token_estimate)
    |> list.fold(0, fn(acc, value) { acc + value })

  let tool_tokens =
    tools
    |> list.map(tool_definition_tokens)
    |> list.fold(0, fn(acc, value) { acc + value })

  message_tokens + tool_tokens
}

fn message_token_estimate(message: provider.ChatMessage) -> Int {
  let content = estimate_tokens(message.content)
  let tool_calls = case message.tool_calls {
    None -> 0
    Some(calls) ->
      calls
      |> list.map(fn(call) {
        estimate_tokens(call.name) + estimate_tokens(call.arguments)
      })
      |> list.fold(0, fn(acc, value) { acc + value })
  }
  content + tool_calls + list.length(message.images) * image_token_estimate
}

/// Rough prompt cost of one attached image. A 1280x800 screenshot measured
/// about 570 tokens on the pilot's provider; this rounds up for the budget.
const image_token_estimate = 1000

fn tool_definition_tokens(tool: provider.ToolDefinition) -> Int {
  let parameters =
    tool.parameters
    |> list.map(fn(parameter) {
      estimate_tokens(parameter.param_type)
      + estimate_tokens(parameter.name)
      + estimate_tokens(parameter.description)
    })
    |> list.fold(0, fn(acc, value) { acc + value })
  estimate_tokens(tool.name) + estimate_tokens(tool.description) + parameters
}

fn response_token_estimate(response: provider.ChatResponse) -> Int {
  let tool_calls = case response.tool_calls {
    None -> 0
    Some(calls) ->
      calls
      |> list.map(fn(call) {
        estimate_tokens(call.name) + estimate_tokens(call.arguments)
      })
      |> list.fold(0, fn(acc, value) { acc + value })
  }
  estimate_tokens(response.content) + tool_calls
}

/// Token estimates used by the usage callback (tests and diagnostics).
pub fn estimate_usage_for_test(
  messages: List(provider.ChatMessage),
  response: provider.ChatResponse,
  tools: List(provider.ToolDefinition),
) -> #(Int, Int) {
  #(prompt_token_estimate(messages, tools), response_token_estimate(response))
}

fn run_provider_call(
  context: RunContext,
  config: provider.ProviderConfig,
  messages: List(provider.ChatMessage),
  tools: List(provider.ToolDefinition),
  depth: Int,
  start: Int,
) -> Result(provider.ChatResponse, ExecutorError) {
  let prompt_tokens = prompt_token_estimate(messages, tools)
  let base_call_id = case context.call_id_override {
    Some(call_id) -> call_id
    None -> next_call_id(depth)
  }
  run_provider_attempt(
    context,
    config,
    messages,
    tools,
    depth,
    start,
    prompt_tokens,
    base_call_id,
    1,
  )
}

fn run_provider_attempt(
  context: RunContext,
  config: provider.ProviderConfig,
  messages: List(provider.ChatMessage),
  tools: List(provider.ToolDefinition),
  depth: Int,
  start: Int,
  prompt_tokens: Int,
  base_call_id: String,
  attempt: Int,
) -> Result(provider.ChatResponse, ExecutorError) {
  let call_id = case context.call_id_override {
    Some(_) ->
      case attempt {
        1 -> base_call_id
        _ -> base_call_id <> ":a" <> int.to_string(attempt)
      }
    None -> base_call_id <> ":a" <> int.to_string(attempt)
  }
  case
    admit_llm(
      context,
      call_id,
      config.name,
      config.default_model,
      prompt_tokens,
    )
  {
    Error(reason) -> Error(PolicyDenied(message: reason))
    Ok(Nil) ->
      case
        with_llm_span(config.name, config.default_model, depth, fn() {
          prompt_log.record(context.principal_id, context.purpose, messages)
          client.chat(messages, config, tools)
        })
      {
        Ok(response) -> {
          let elapsed = current_timestamp() - start
          record_llm_latency(config.name, config.default_model, elapsed)
          record_llm_usage(context, config, messages, response, tools, call_id)
          Ok(response)
        }
        Error(err) -> {
          settle_failed_attempt(context, call_id, config, prompt_tokens, err)
          record_llm_error(
            config.name,
            config.default_model,
            error_type_name(err),
          )
          case attempt < default_retry_config.max_attempts {
            True ->
              case retry.is_retryable(err) {
                retry.ShouldRetry -> {
                  retry.wait_before_retry(default_retry_config, attempt)
                  run_provider_attempt(
                    context,
                    config,
                    messages,
                    tools,
                    depth,
                    start,
                    prompt_tokens,
                    base_call_id,
                    attempt + 1,
                  )
                }
                retry.DoNotRetry(_) -> Error(LLMError(reason: err))
              }
            False -> Error(LLMError(reason: err))
          }
        }
      }
  }
}

/// A network failure may already have been billed by the provider. Record the
/// reserved estimate as unconfirmed usage; other failures release the reserve.
fn settle_failed_attempt(
  context: RunContext,
  call_id: String,
  config: provider.ProviderConfig,
  prompt_tokens: Int,
  err: provider.LLMError,
) -> Nil {
  case err {
    provider.NetworkError(_) ->
      case context.on_llm_unconfirmed {
        Some(record) ->
          record(call_id, config.name, config.default_model, prompt_tokens)
        None -> Nil
      }
    _ -> report_llm_failure(context, call_id)
  }
}

fn record_llm_usage(
  context: RunContext,
  config: provider.ProviderConfig,
  messages: List(provider.ChatMessage),
  response: provider.ChatResponse,
  tools: List(provider.ToolDefinition),
  call_id: String,
) -> Nil {
  case context.on_llm_usage {
    None -> Nil
    Some(record) ->
      record(
        call_id,
        config.name,
        config.default_model,
        prompt_token_estimate(messages, tools),
        response_token_estimate(response),
      )
  }
}

/// How many tool images stay in the history of one turn. Older ones are
/// dropped so a long tool loop does not resend every screenshot.
const kept_tool_images = 2

/// Execute tool calls and return result messages. Images a tool attached to
/// its result (see `tool_images`) go in one user message after the tool
/// results.
fn execute_tool_calls(
  calls: List(provider.ToolCall),
  tools: List(provider.ToolDefinition),
  context: RunContext,
) -> List(provider.ChatMessage) {
  // The calls of one round are independent (the APIs ask for them together
  // when the model needs them all), so they run at the same time.
  let results =
    calls
    |> run_concurrently(fn(call) {
      execute_single_tool_call(call, tools, context)
    })
    |> list.zip(calls, _)
    |> list.map(fn(pair) {
      let #(call, output) = pair
      let #(text, images) = tool_images.split(output)
      #(provider.tool_result_message(call.id, tool_limits.cap(text)), images)
    })
  list.append(
    list.map(results, fn(result) { result.0 }),
    tool_images.message(list.flat_map(results, fn(result) { result.1 })),
  )
}

/// Most tool calls of one round running at once; the rest wait for a slot.
const max_concurrent_tools = 8

/// `run` on each item, each in a process of its own, at most
/// `max_concurrent_tools` at a time; the results in the items' order. A run
/// that crashes, or whose process is killed, gives an error text instead of
/// taking the turn down. One item runs here, with no process to start.
fn run_concurrently(items: List(a), run: fn(a) -> String) -> List(String) {
  items
  |> list.sized_chunk(max_concurrent_tools)
  |> list.flat_map(run_batch(_, run))
}

fn run_batch(items: List(a), run: fn(a) -> String) -> List(String) {
  case items {
    [] | [_] -> list.map(items, run)
    _ ->
      items
      |> list.map(fn(item) {
        let reply = process.new_subject()
        let pid =
          process.spawn_unlinked(fn() {
            case exception_guard.run(fn() { process.send(reply, run(item)) }) {
              Ok(Nil) -> Nil
              Error(reason) ->
                process.send(reply, "ERROR: tool crashed: " <> reason)
            }
          })
        #(reply, process.monitor(pid))
      })
      |> list.map(fn(pending) {
        let #(reply, monitor) = pending
        let result =
          process.new_selector()
          |> process.select(reply)
          |> process.select_specific_monitor(monitor, fn(down) {
            "ERROR: tool stopped: " <> string.inspect(down)
          })
          |> process.selector_receive_forever
        process.demonitor_process(monitor)
        result
      })
  }
}

/// Append one round of tool calls and their results to the history.
fn append_tool_round(
  history: List(provider.ChatMessage),
  tool_results: List(provider.ChatMessage),
) -> List(provider.ChatMessage) {
  list.append(history, tool_results)
  |> tool_images.keep_recent(kept_tool_images)
}

/// Expose tool execution with a run context for unit tests.
pub fn execute_tool_calls_with_context_for_test(
  calls: List(provider.ToolCall),
  tools: List(provider.ToolDefinition),
  context: RunContext,
) -> List(provider.ChatMessage) {
  execute_tool_calls(calls, tools, context)
}

/// Expose how a round of tool results joins the history, for unit tests.
pub fn append_tool_round_for_test(
  history: List(provider.ChatMessage),
  tool_results: List(provider.ChatMessage),
) -> List(provider.ChatMessage) {
  append_tool_round(history, tool_results)
}

/// Expose tool execution for unit tests.
pub fn execute_tool_calls_for_test(
  calls: List(provider.ToolCall),
  tools: List(provider.ToolDefinition),
) -> List(provider.ChatMessage) {
  execute_tool_calls(calls, tools, empty_run_context())
}

fn execute_single_tool_call(
  call: provider.ToolCall,
  tools: List(provider.ToolDefinition),
  context: RunContext,
) -> String {
  case is_declared_tool(call.name, tools) {
    False -> {
      record_tool_error(call.name)
      "ERROR: Tool '" <> call.name <> "' is not declared for this turn"
    }
    True -> {
      let start = current_timestamp()
      with_tool_span(call.name, fn() {
        let limit_ms = tool_limits.timeout_ms(tool_limits.current(), call.name)
        let result =
          within(limit_ms, fn() {
            case context.invoke_tool {
              Some(invoke) -> invoke(call.name, call.arguments)
              None -> dispatch_builtin_tool(call.name, call.arguments)
            }
          })
          |> result.unwrap(Error(
            "a ferramenta passou do tempo-limite de "
            <> int.to_string(limit_ms / 1000)
            <> " s e foi interrompida",
          ))
        case result {
          Ok(output) -> {
            let elapsed = current_timestamp() - start
            record_tool_latency(call.name, elapsed)
            report_tool_result(context, call.name, True)
            output
          }
          Error(reason) -> {
            record_tool_error(call.name)
            report_tool_result(context, call.name, False)
            "ERROR: " <> reason
          }
        }
      })
    }
  }
}

/// `work` in a process of its own, killed when `timeout_ms` passes first. A
/// crash inside it is reported like a crash here.
fn within(
  timeout_ms: Int,
  work: fn() -> Result(String, String),
) -> Result(Result(String, String), Nil) {
  let reply = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      case exception_guard.run(fn() { process.send(reply, work()) }) {
        Ok(Nil) -> Nil
        Error(reason) -> process.send(reply, Error("tool crashed: " <> reason))
      }
    })
  case process.receive(reply, timeout_ms) {
    Ok(value) -> Ok(value)
    Error(Nil) -> {
      process.kill(worker)
      Error(Nil)
    }
  }
}

fn report_tool_result(context: RunContext, tool_name: String, ok: Bool) -> Nil {
  case context.on_tool_result {
    None -> Nil
    Some(record) -> record(tool_name, ok)
  }
}

fn record_tool_latency(tool_name: String, latency_ms: Int) {
  case metrics_global.get_metrics() {
    option.Some(metrics) -> {
      metrics_actor.observe_histogram(
        metrics,
        "tool_execution_duration_seconds",
        int.to_float(latency_ms) /. 1000.0,
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

fn is_declared_tool(
  name: String,
  tools: List(provider.ToolDefinition),
) -> Bool {
  list.any(tools, fn(tool) { tool.name == name })
}

fn dispatch_builtin_tool(
  name: String,
  args_json: String,
) -> Result(String, String) {
  tool_dispatch.execute(name, args_json)
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
  context: RunContext,
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
            context,
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

fn first_tool_call(
  calls: List(provider.ToolCall),
) -> Option(provider.ToolCall) {
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
  // The same span, circuit breaker and metrics as a non-streamed call.
  stream.start_stream_from(fn() {
    let start = current_timestamp()
    let result =
      with_llm_span(config.name, config.default_model, 0, fn() {
        client.chat(messages, config, tools)
      })
    case result {
      Ok(_) ->
        record_llm_latency(
          config.name,
          config.default_model,
          current_timestamp() - start,
        )
      Error(err) ->
        record_llm_error(
          config.name,
          config.default_model,
          error_type_name(err),
        )
    }
    result
  })
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
    Some(content) -> {
      case mock_delay_ms(content) {
        Some(delay) -> process.sleep(delay)
        None -> Nil
      }
      case string.contains(content, "[mock-crash]") {
        True -> panic as "simulated executor crash"
        False ->
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
      }
    }
    None ->
      mock_stream_chunks(messages, config)
      |> list.each(fn(chunk) { process.send(subject, chunk) })
  }

  subject
}

fn mock_delay_ms(content: String) -> Option(Int) {
  case string.split(content, "[mock-delay-ms=") {
    [_, rest] ->
      case string.split(rest, "]") {
        [digits, ..] ->
          case int.parse(digits) {
            Ok(value) -> Some(value)
            Error(_) -> None
          }
        [] -> None
      }
    _ -> None
  }
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
