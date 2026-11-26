//// The mock marks that call the test tools (PRD-F, F-01), the mock counting
//// only this turn's tool results, and the stress option that mixes them in.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/llm/client
import supernova/llm/provider
import supernova/stress/fake_tools
import supernova/stress/run

fn mock() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

fn tools() -> List(provider.ToolDefinition) {
  fake_tools.enable()
  let tools = fake_tools.tools()
  fake_tools.disable()
  tools
}

fn calls(text: String) -> List(provider.ToolCall) {
  let assert Ok(response) =
    client.chat([provider.user_message(text)], mock(), tools())
  option.unwrap(response.tool_calls, [])
}

pub fn marks_call_the_test_tools_test() {
  let assert [lenta] = calls("[mock-lenta 25] oi")
  lenta.name |> should.equal("lenta")
  lenta.arguments |> should.equal("{\"ms\":25}")
  let assert [trava] = calls("[mock-trava]")
  trava.name |> should.equal("trava")
  let assert [explode] = calls("[mock-explode]")
  explode.name |> should.equal("explode")
}

pub fn many_calls_come_slowest_first_test() {
  calls("[mock-varias 3]")
  |> list.map(fn(call) { #(call.id, call.arguments) })
  |> should.equal([
    #("mock_tool_call_1", "{\"ms\":60}"),
    #("mock_tool_call_2", "{\"ms\":40}"),
    #("mock_tool_call_3", "{\"ms\":20}"),
  ])
}

/// A tool result from a past turn, kept in the history (#59), does not stop
/// this turn from calling its tool.
pub fn past_turns_tool_results_do_not_count_test() {
  let history = [
    provider.user_message("[mock-lenta 10] antes"),
    provider.tool_result_message("old", "lenta: 10 ms"),
    provider.ChatMessage(
      ..provider.user_message("Mock response"),
      role: "assistant",
    ),
    provider.user_message("[mock-explode] agora"),
  ]
  let assert Ok(response) = client.chat(history, mock(), tools())
  let assert Some([call]) = response.tool_calls
  call.name |> should.equal("explode")

  // After this turn's error, the mock answers.
  let assert Ok(answer) =
    client.chat(
      list.append(history, [
        provider.tool_result_message("mock_tool_call_1", "ERROR: tool crashed"),
      ]),
      mock(),
      tools(),
    )
  answer.content |> should.equal("Mock tool error")
}

pub fn tool_mix_option_test() {
  let assert Ok(options) = run.parse_args(["--tool-mix", "--seconds", "5"])
  options.tool_mix |> should.be_true
  let assert Ok(plain) = run.parse_args([])
  plain.tool_mix |> should.be_false
}

pub fn tool_mix_messages_test() {
  let assert Ok(plain) = run.parse_args([])
  run.plain_or_tool(plain, 7).0 |> should.equal("plain")

  let assert Ok(mixed) = run.parse_args(["--tool-mix"])
  let kinds =
    list.repeat(Nil, 400)
    |> list.index_map(fn(_, n) { run.plain_or_tool(mixed, n) })
  list.all(kinds, fn(kind) { kind.0 == "plain" || kind.0 == "tool" })
  |> should.be_true
  list.any(kinds, fn(kind) { kind.0 == "tool" }) |> should.be_true
}

/// With `--tool-mix`, members may call the test tools and `trava` is cut at
/// 2 s; without it, the config is the plain one.
pub fn tool_mix_config_test() {
  let assert Ok(mixed) = run.parse_args(["--tool-mix"])
  let cfg = run.build_config(mixed, "/tmp/nao-usado", 0, "t")
  list.contains(cfg.capabilities.member.allowed, "trava") |> should.be_true
  dict.get(cfg.tools.timeouts, "trava") |> should.equal(Ok(2))

  let assert Ok(plain) = run.parse_args([])
  let cfg = run.build_config(plain, "/tmp/nao-usado", 0, "t")
  list.contains(cfg.capabilities.member.allowed, "trava") |> should.be_false
}
