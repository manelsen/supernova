//// PRD-E, E-03: every tool result has a ceiling and every tool a time
//// limit.

import gleam/dict
import gleam/erlang/process
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import supernova/core/executor
import supernova/core/tool_limits
import supernova/llm/provider

pub fn a_short_result_is_kept_whole_test() {
  tool_limits.cap("pequeno") |> should.equal("pequeno")
}

pub fn a_long_result_is_cut_with_a_notice_test() {
  let long = string.repeat("a", 25_000)
  let capped = tool_limits.cap(long)
  string.starts_with(capped, string.repeat("a", tool_limits.max_output_chars))
  |> should.be_true()
  string.contains(
    capped,
    "[saída cortada: 25000 caracteres; peça um trecho menor]",
  )
  |> should.be_true()
  { string.length(capped) < 20_100 } |> should.be_true()
}

pub fn timeouts_default_and_per_tool_test() {
  let timeouts = tool_limits.default_timeouts()
  tool_limits.timeout_ms(timeouts, "web_fetch") |> should.equal(60_000)
  tool_limits.timeout_ms(timeouts, "computador") |> should.equal(300_000)
  let custom =
    tool_limits.Timeouts(
      default_ms: 5000,
      per_tool: dict.from_list([#("x", 7)]),
    )
  tool_limits.timeout_ms(custom, "x") |> should.equal(7)
  tool_limits.timeout_ms(custom, "y") |> should.equal(5000)
}

fn run_one(name: String, invoke) {
  let context =
    executor.RunContext(
      ..executor.empty_run_context(),
      invoke_tool: Some(invoke),
    )
  let assert [message, ..] =
    executor.execute_tool_calls_with_context_for_test(
      [provider.ToolCall(id: "c1", name: name, arguments: "{}")],
      [provider.new_tool(name: name, description: "t", parameters: [])],
      context,
    )
  message.content
}

pub fn a_slow_tool_becomes_a_timeout_error_test() {
  tool_limits.configure(
    tool_limits.Timeouts(
      ..tool_limits.default_timeouts(),
      per_tool: dict.from_list([#("e03_lenta", 50)]),
    ),
  )
  let content =
    run_one("e03_lenta", fn(_, _) {
      // Never answers on its own.
      process.receive_forever(process.new_subject())
    })
  tool_limits.configure(tool_limits.default_timeouts())
  string.starts_with(content, "ERROR:") |> should.be_true()
  string.contains(content, "tempo") |> should.be_true()
}

pub fn the_executor_caps_what_a_tool_returns_test() {
  let content =
    run_one("e03_grande", fn(_, _) { Ok(string.repeat("b", 30_000)) })
  string.contains(content, "[saída cortada: 30000 caracteres")
  |> should.be_true()
}

pub fn configured_seconds_override_the_builtin_limits_test() {
  let timeouts =
    tool_limits.from_seconds(
      dict.from_list([#("default", 30), #("web_fetch", 90)]),
    )
  tool_limits.timeout_ms(timeouts, "web_fetch") |> should.equal(90_000)
  tool_limits.timeout_ms(timeouts, "outra") |> should.equal(30_000)
  tool_limits.timeout_ms(timeouts, "computador") |> should.equal(300_000)
  tool_limits.from_seconds(dict.new())
  |> should.equal(tool_limits.default_timeouts())
}
