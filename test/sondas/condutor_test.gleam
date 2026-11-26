//// PRD-S, S-06: the conductor of a probe, with the mock LLM and fake
//// hands. S-I1 (only what the agent passed), S-I2 (cost cap), the round
//// limit, and the hands kept and let go.

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/core/executor
import supernova/llm/provider
import supernova/sondas/condutor

fn mock() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

type Seen {
  Called(name: String)
  Kept(text: String)
  Closed
}

fn hands(seen: process.Subject(Seen)) -> condutor.Hands {
  condutor.Hands(
    tools: [
      provider.new_tool(name: "buscar", description: "Search", parameters: [
        provider.string_param("consulta", "q", True),
      ]),
    ],
    invoke: fn(name, _args) {
      process.send(seen, Called(name))
      Ok("resultado da busca: a página fala de Gleam")
    },
    folder: "/home/pwuser/pessoas/abcd/sondas/1",
    keep: fn(text) { process.send(seen, Kept(text)) },
    close: fn() { process.send(seen, Closed) },
  )
}

fn free() -> condutor.Costing {
  condutor.Costing(cost: fn(_, _, _) { 0.0 }, reserve_output_tokens: 1000)
}

fn drain(subject: process.Subject(Seen), acc: List(Seen)) -> List(Seen) {
  case process.receive(subject, 0) {
    Ok(item) -> drain(subject, [item, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn a_probe_runs_its_tools_and_reports_test() {
  let seen = process.new_subject()
  let assert Ok(#(condutor.Concluded, report)) =
    condutor.run(
      condutor.Web,
      "Procure o que é Gleam.",
      condutor.default_limits(condutor.Web),
      hands(seen),
      executor.empty_run_context(),
      mock(),
      free(),
    )
  string.starts_with(report, "concluída: Mock response") |> should.be_true
  string.contains(
    report,
    "Pasta no computador: /home/pwuser/pessoas/abcd/sondas/1",
  )
  |> should.be_true
  drain(seen, [])
  |> should.equal([Called("buscar"), Kept("Mock response"), Closed])
}

/// S-I1: the model of the probe sees its prompt, the instructions and its
/// tool results; nothing of the agent.
pub fn the_conductor_sees_only_what_the_agent_passed_test() {
  clear_prompts()
  let seen = process.new_subject()
  let _ =
    condutor.run(
      condutor.Web,
      "Procure o que é Gleam.",
      condutor.default_limits(condutor.Web),
      hands(seen),
      executor.empty_run_context(),
      mock(),
      free(),
    )
  let assert [last, first] = prompts()
  first
  |> should.equal(
    condutor.prompt(condutor.Web, "/home/pwuser/pessoas/abcd/sondas/1")
    <> "\n---\nProcure o que é Gleam.",
  )
  string.contains(last, "resultado da busca: a página fala de Gleam")
  |> should.be_true
}

/// S-I2: a call that would pass the cap is refused; the probe ends with
/// "custo esgotado" and keeps what it has: what its tools returned so far.
pub fn the_cost_cap_stops_the_probe_test() {
  let seen = process.new_subject()
  let costing =
    condutor.Costing(cost: fn(_, _, _) { 0.15 }, reserve_output_tokens: 1000)
  let assert Ok(#(condutor.CostExhausted, report)) =
    condutor.run(
      condutor.Web,
      "Procure.",
      condutor.default_limits(condutor.Web),
      hands(seen),
      executor.empty_run_context(),
      mock(),
      costing,
    )
  string.starts_with(report, "custo esgotado:") |> should.be_true
  string.contains(report, "O que a sonda juntou até parar") |> should.be_true
  string.contains(report, "### buscar\nresultado da busca") |> should.be_true
  string.contains(report, "Custo: US$ 0.15") |> should.be_true
  drain(seen, []) |> list.contains(Closed) |> should.be_true
}

pub fn the_round_limit_ends_the_probe_test() {
  let seen = process.new_subject()
  let assert Error(reason) =
    condutor.run(
      condutor.Web,
      "Procure.",
      condutor.Limits(..condutor.default_limits(condutor.Web), max_rounds: 0),
      hands(seen),
      executor.empty_run_context(),
      mock(),
      free(),
    )
  reason |> should.equal("passou de 0 rodadas sem terminar")
  drain(seen, []) |> list.contains(Closed) |> should.be_true
}

pub fn the_result_is_cut_for_the_chat_test() {
  let limits =
    condutor.Limits(..condutor.default_limits(condutor.Disk), result_chars: 10)
  let text =
    condutor.deliverable(
      "concluída",
      string.repeat("a", 50),
      limits,
      "/p",
      0.01,
    )
  string.contains(text, string.repeat("a", 10) <> " …(cortado")
  |> should.be_true
  string.contains(text, string.repeat("a", 11)) |> should.be_false
}

pub fn kinds_test() {
  [condutor.Web, condutor.Disk, condutor.Code]
  |> list.map(condutor.kind_name)
  |> list.map(condutor.parse_kind)
  |> should.equal([Ok(condutor.Web), Ok(condutor.Disk), Ok(condutor.Code)])
  condutor.parse_kind("código") |> should.equal(Ok(condutor.Code))
  condutor.parse_kind("shell") |> should.equal(Error(Nil))
  condutor.default_limits(condutor.Disk).duration_ms |> should.equal(120_000)
  condutor.default_limits(condutor.Code).duration_ms |> should.equal(900_000)
  condutor.default_limits(condutor.Web).duration_ms |> should.equal(1_800_000)
  string.contains(condutor.prompt(condutor.Web, "/p"), "barrada")
  |> should.be_true
  string.contains(condutor.prompt(condutor.Code, "/p"), "mkdir -p /p")
  |> should.be_true
}

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompts() -> List(String)
