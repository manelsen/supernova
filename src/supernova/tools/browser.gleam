//// Browser Tool — persistent browser automation via Erlang FFI + Playwright.
////
//// Supports persistent sessions across tool calls so agents can open a page,
//// interact with it, evaluate JavaScript, take screenshots, and extract
//// readable text incrementally.

import envoy
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/core/url_guard
import supernova/llm/provider

const evaluate_disabled_error = "browser evaluate is disabled by configuration"

const evaluate_global_key = "supernova_browser_allow_evaluate"

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: Bool) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn global_get(key: String) -> Bool

@external(erlang, "supernova_global_ffi", "global_has")
fn global_has(key: String) -> Bool

/// Configure whether arbitrary JavaScript evaluation is enabled globally.
pub fn set_evaluate_allowed(allowed: Bool) -> Nil {
  global_put(evaluate_global_key, allowed)
}

/// Check whether browser `evaluate` is currently enabled by env or config.
/// Defaults to `False` unless `SUPERNOVA_BROWSER_ALLOW_EVALUATE=true` or
/// `tools.browser.allow_evaluate: true` has been applied.
pub fn is_evaluate_allowed() -> Bool {
  case envoy.get("SUPERNOVA_BROWSER_ALLOW_EVALUATE") {
    Ok(value) ->
      case string.lowercase(string.trim(value)) {
        "true" -> True
        "false" -> False
        _ -> stored_evaluate_allowed()
      }
    Error(_) -> stored_evaluate_allowed()
  }
}

fn stored_evaluate_allowed() -> Bool {
  case global_has(evaluate_global_key) {
    True -> global_get(evaluate_global_key)
    False -> False
  }
}

type BrowserArgs {
  BrowserArgs(
    operation: String,
    session_id: Option(String),
    url: Option(String),
    selector: Option(String),
    text: Option(String),
    script: Option(String),
    timeout_ms: Int,
  )
}

/// Get the tool definition for Browser automation.
pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "browser",
    description: "Automate a real browser with persistent sessions: open, click, type, evaluate, screenshot, and extract readable text",
    parameters: [
      provider.string_param("operation", "Browser operation to run", True),
      provider.string_param(
        "session_id",
        "Existing browser session id (required after open)",
        False,
      ),
      provider.string_param("url", "URL to open", False),
      provider.string_param("selector", "CSS selector target", False),
      provider.string_param("text", "Text to type into the selector", False),
      provider.string_param(
        "script",
        "JavaScript expression to evaluate in the page context",
        False,
      ),
      provider.integer_param(
        "timeout_ms",
        "Per-operation timeout in milliseconds",
        False,
      ),
    ],
  )
}

/// Open a new browser session and navigate to the URL (with SSRF protection).
pub fn open(url: String, timeout_ms: Int) -> Result(String, String) {
  use validated_url <- result.try(url_guard.validate_url_allow_data(url))
  do_open_session(validated_url, timeout_ms)
}

/// Click a selector within an existing session.
pub fn click(
  session_id: String,
  selector: String,
  timeout_ms: Int,
) -> Result(String, String) {
  do_click(session_id, selector, timeout_ms)
}

/// Fill text into a selector within an existing session.
pub fn type_text(
  session_id: String,
  selector: String,
  text: String,
  timeout_ms: Int,
) -> Result(String, String) {
  do_type_text(session_id, selector, text, timeout_ms)
}

/// Evaluate JavaScript in the current page context if enabled by config/env.
pub fn evaluate(
  session_id: String,
  script: String,
  timeout_ms: Int,
) -> Result(String, String) {
  evaluate_with_config(session_id, script, timeout_ms, is_evaluate_allowed())
}

/// Evaluate JavaScript in the current page context with an explicit flag.
pub fn evaluate_with_config(
  session_id: String,
  script: String,
  timeout_ms: Int,
  allow_evaluate: Bool,
) -> Result(String, String) {
  case allow_evaluate {
    False -> Error(evaluate_disabled_error)
    True -> do_evaluate(session_id, script, timeout_ms)
  }
}

/// Extract readable text from the current page.
pub fn extract_readable(
  session_id: String,
  timeout_ms: Int,
) -> Result(String, String) {
  do_extract_readable(session_id, timeout_ms)
}

/// Take a PNG screenshot of the current page.
pub fn screenshot(session_id: String, timeout_ms: Int) -> Result(String, String) {
  do_screenshot(session_id, timeout_ms)
}

/// Close a browser session and clean up resources.
pub fn close(session_id: String) -> Result(String, String) {
  do_close_session(session_id)
}

/// Execute a browser tool call encoded as JSON arguments.
pub fn execute(args_json: String) -> Result(String, String) {
  execute_with_config(args_json, is_evaluate_allowed())
}

/// Execute a browser tool call with an explicit `allow_evaluate` flag.
pub fn execute_with_config(
  args_json: String,
  allow_evaluate: Bool,
) -> Result(String, String) {
  case json.parse(from: args_json, using: browser_args_decoder()) {
    Ok(args) -> dispatch(args, allow_evaluate)
    Error(error) ->
      Error("Invalid arguments for browser: " <> string.inspect(error))
  }
}

fn browser_args_decoder() -> decode.Decoder(BrowserArgs) {
  use operation <- decode.field("operation", decode.string)
  use session_id <- decode.optional_field(
    "session_id",
    None,
    decode.optional(decode.string),
  )
  use url <- decode.optional_field("url", None, decode.optional(decode.string))
  use selector <- decode.optional_field(
    "selector",
    None,
    decode.optional(decode.string),
  )
  use text <- decode.optional_field(
    "text",
    None,
    decode.optional(decode.string),
  )
  use script <- decode.optional_field(
    "script",
    None,
    decode.optional(decode.string),
  )
  use timeout_ms <- decode.optional_field("timeout_ms", 5000, decode.int)

  decode.success(BrowserArgs(
    operation: operation,
    session_id: session_id,
    url: url,
    selector: selector,
    text: text,
    script: script,
    timeout_ms: timeout_ms,
  ))
}

fn dispatch(args: BrowserArgs, allow_evaluate: Bool) -> Result(String, String) {
  let operation = string.lowercase(string.trim(args.operation))

  case operation {
    "open" ->
      require_string_field(args.url, "url", operation)
      |> result_then(fn(url) { open(url, args.timeout_ms) })
    "click" ->
      require_session_and_field(
        args.session_id,
        args.selector,
        "selector",
        operation,
      )
      |> result_then(fn(pair) {
        let #(session_id, selector) = pair
        click(session_id, selector, args.timeout_ms)
      })
    "type" ->
      require_session_field_and_text(args, operation)
      |> result_then(fn(values) {
        let #(session_id, selector, text) = values
        type_text(session_id, selector, text, args.timeout_ms)
      })
    "evaluate" ->
      case allow_evaluate {
        False -> Error(evaluate_disabled_error)
        True ->
          require_session_and_field(
            args.session_id,
            args.script,
            "script",
            operation,
          )
          |> result_then(fn(pair) {
            let #(session_id, script) = pair
            evaluate_with_config(session_id, script, args.timeout_ms, True)
          })
      }
    "extract_readable" ->
      require_session(args.session_id, operation)
      |> result_then(fn(session_id) {
        extract_readable(session_id, args.timeout_ms)
      })
    "screenshot" ->
      require_session(args.session_id, operation)
      |> result_then(fn(session_id) { screenshot(session_id, args.timeout_ms) })
    "close" ->
      require_session(args.session_id, operation)
      |> result_then(close)
    _ -> Error("Invalid arguments for browser: unknown operation " <> operation)
  }
}

fn require_session(
  session_id: Option(String),
  operation: String,
) -> Result(String, String) {
  require_string_field(session_id, "session_id", operation)
}

fn require_session_and_field(
  session_id: Option(String),
  field: Option(String),
  field_name: String,
  operation: String,
) -> Result(#(String, String), String) {
  case
    require_session(session_id, operation),
    require_string_field(field, field_name, operation)
  {
    Ok(session_id), Ok(field_value) -> Ok(#(session_id, field_value))
    Error(reason), _ -> Error(reason)
    _, Error(reason) -> Error(reason)
  }
}

fn require_session_field_and_text(
  args: BrowserArgs,
  operation: String,
) -> Result(#(String, String, String), String) {
  case require_session(args.session_id, operation) {
    Error(reason) -> Error(reason)
    Ok(session_id) ->
      case require_string_field(args.selector, "selector", operation) {
        Error(reason) -> Error(reason)
        Ok(selector) ->
          case require_string_field(args.text, "text", operation) {
            Error(reason) -> Error(reason)
            Ok(text) -> Ok(#(session_id, selector, text))
          }
      }
  }
}

fn require_string_field(
  value: Option(String),
  field_name: String,
  operation: String,
) -> Result(String, String) {
  case value {
    Some(text) -> Ok(text)
    None ->
      Error(
        "Invalid arguments for browser: missing "
        <> field_name
        <> " for "
        <> operation,
      )
  }
}

fn result_then(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(reason) -> Error(reason)
  }
}

@external(erlang, "supernova_browser_ffi", "open_session")
fn do_open_session(url: String, timeout_ms: Int) -> Result(String, String)

@external(erlang, "supernova_browser_ffi", "click")
fn do_click(
  session_id: String,
  selector: String,
  timeout_ms: Int,
) -> Result(String, String)

@external(erlang, "supernova_browser_ffi", "type_text")
fn do_type_text(
  session_id: String,
  selector: String,
  text: String,
  timeout_ms: Int,
) -> Result(String, String)

@external(erlang, "supernova_browser_ffi", "evaluate")
fn do_evaluate(
  session_id: String,
  script: String,
  timeout_ms: Int,
) -> Result(String, String)

@external(erlang, "supernova_browser_ffi", "extract_readable")
fn do_extract_readable(
  session_id: String,
  timeout_ms: Int,
) -> Result(String, String)

@external(erlang, "supernova_browser_ffi", "screenshot")
fn do_screenshot(session_id: String, timeout_ms: Int) -> Result(String, String)

@external(erlang, "supernova_browser_ffi", "close_session")
fn do_close_session(session_id: String) -> Result(String, String)
