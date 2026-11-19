//// Harness CLI: run scenarios, apply deterministic checks and the judge,
//// account cost, and write the report.

import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/config as agent_config_module
import supernova/harness/calibration
import supernova/harness/checks
import supernova/harness/cli_model
import supernova/harness/config as harness_config
import supernova/harness/cost
import supernova/harness/engine
import supernova/harness/judge
import supernova/harness/report
import supernova/harness/scenario
import supernova/harness/transcript
import supernova/llm/client
import supernova/llm/provider
import supernova/self/core as self_core
import supernova/self/memory

pub type Options {
  Options(
    config_path: String,
    scenario_selector: String,
    runs: Int,
    max_usd: Float,
    out_dir: String,
    long: Bool,
    skip_calibration: Bool,
    keep_data: Bool,
    mock_persona_cost: Float,
  )
}

pub fn default_options() -> Options {
  Options(
    config_path: "harness.yaml",
    scenario_selector: "all",
    runs: 3,
    max_usd: 3.0,
    out_dir: "harness-out",
    long: False,
    skip_calibration: False,
    keep_data: False,
    mock_persona_cost: 0.0,
  )
}

pub fn parse_args(args: List(String)) -> Result(Options, String) {
  parse_args_loop(args, default_options())
}

fn parse_args_loop(
  args: List(String),
  options: Options,
) -> Result(Options, String) {
  case args {
    [] -> Ok(options)
    ["--config", value, ..rest] ->
      parse_args_loop(rest, Options(..options, config_path: value))
    ["--scenario", value, ..rest] ->
      parse_args_loop(rest, Options(..options, scenario_selector: value))
    ["--runs", value, ..rest] ->
      case int.parse(value) {
        Ok(number) -> parse_args_loop(rest, Options(..options, runs: number))
        Error(_) -> Error("invalid --runs: " <> value)
      }
    ["--max-usd", value, ..rest] ->
      case float.parse(value) {
        Ok(number) -> parse_args_loop(rest, Options(..options, max_usd: number))
        Error(_) -> Error("invalid --max-usd: " <> value)
      }
    ["--out", value, ..rest] ->
      parse_args_loop(rest, Options(..options, out_dir: value))
    ["--long", ..rest] -> parse_args_loop(rest, Options(..options, long: True))
    ["--skip-calibration", ..rest] ->
      parse_args_loop(rest, Options(..options, skip_calibration: True))
    ["--keep-data", ..rest] ->
      parse_args_loop(rest, Options(..options, keep_data: True))
    [unknown, ..] -> Error("unknown argument: " <> unknown)
  }
}

pub fn main() -> Nil {
  let result = case parse_args(cli_args()) {
    Error(message) -> Error(message)
    Ok(options) -> execute(options)
  }
  case result {
    Ok(value) -> {
      io_println(case report.ok(value) {
        True -> "harness: aprovado"
        False -> "harness: reprovado"
      })
      halt(case report.ok(value) {
        True -> 0
        False -> 1
      })
    }
    Error(message) -> {
      io_println("error: " <> message)
      halt(2)
    }
  }
}

pub fn execute(options: Options) -> Result(report.Report, String) {
  use harness <- result.try(harness_config.load(options.config_path))
  use agent <- result.try(agent_config(harness))
  let root = "priv/harness"
  use selected <- result.try(load_scenarios(root, options))
  let mock = harness.agent_provider == "mock"
  let judge_call = judge_call(harness, mock)
  let persona_driver = persona_driver(harness, agent, options, mock)
  // The judge prompt is the maintainer's; without it nothing is graded.
  use template <- result.try(judge_template(root))
  use calibrated <- result.try(case options.skip_calibration {
    True -> Ok(False)
    False -> calibrate_all(root, selected, template, mock, judge_call)
  })
  let started_at = timestamp()
  let session_dir = options.out_dir <> "/" <> int.to_string(started_at)
  use _ <- result.try(ensure_dir(session_dir))
  let initial =
    ReportState(
      report: report.Report(
        outcomes: [],
        partial: False,
        calibrated: calibrated,
        total: cost.zero(),
        started_at: started_at,
      ),
      stopped: False,
    )
  use final <- result.try(run_scenarios(
    options,
    harness,
    agent,
    root,
    selected,
    session_dir,
    persona_driver,
    judge_call,
    template,
    mock,
    initial,
  ))
  use _ <- result.try(write_report(session_dir, final.report))
  Ok(final.report)
}

fn agent_config(
  harness: harness_config.HarnessConfig,
) -> Result(provider.ProviderConfig, String) {
  use provider_type <- result.try(
    agent_config_module.provider_from_name(harness.agent_provider)
    |> result.map_error(fn(_) {
      "unknown agent provider: " <> harness.agent_provider
    }),
  )
  let api_key = case harness.agent_api_key_env {
    None -> None
    Some(name) ->
      case envoy_get(name) {
        Ok(value) -> Some(value)
        Error(_) -> None
      }
  }
  Ok(provider.ProviderConfig(
    name: agent_config_module.provider_runtime_name(provider_type),
    api_key: api_key,
    base_url: None,
    default_model: harness.agent_model,
  ))
}

fn persona_driver(
  harness: harness_config.HarnessConfig,
  agent: provider.ProviderConfig,
  options: Options,
  mock: Bool,
) -> engine.PersonaDriver {
  case mock {
    True -> fn(system, transcript_text) {
      case
        client.chat(
          [
            provider.system_message(system),
            provider.user_message(transcript_text),
          ],
          agent,
          [],
        )
      {
        Ok(response) -> Ok(#(response.content, options.mock_persona_cost))
        Error(error) -> Error(string.inspect(error))
      }
    }
    False -> fn(system, transcript_text) {
      case
        cli_model.call(
          harness.persona,
          system,
          transcript_text,
          temp_dir(),
          None,
        )
      {
        Ok(result) -> Ok(#(result.text, result.cost_usd))
        Error(reason) -> Error(reason)
      }
    }
  }
}

type JudgeCall =
  fn(String, String, Option(String)) -> Result(cli_model.CliResult, String)

fn judge_call(harness: harness_config.HarnessConfig, mock: Bool) -> JudgeCall {
  case mock {
    True -> fn(system, _prompt, _schema) {
      case client.chat([provider.system_message(system)], mock_agent(), []) {
        Ok(response) ->
          Ok(cli_model.CliResult(
            text: response.content,
            model: "mock-judge",
            cost_usd: 0.0,
          ))
        Error(error) -> Error(string.inspect(error))
      }
    }
    False -> fn(system, prompt, schema) {
      cli_model.call(harness.judge, system, prompt, temp_dir(), schema)
    }
  }
}

fn mock_agent() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

fn load_scenarios(
  root: String,
  options: Options,
) -> Result(List(scenario.Loaded), String) {
  let ids = case options.scenario_selector {
    "all" ->
      find_files(root <> "/scenarios", "*.json")
      |> list.map(fn(path) {
        path
        |> string.split("/")
        |> list.last
        |> result.unwrap(path)
        |> string.replace(".json", "")
      })
    selector -> string.split(selector, ",")
  }
  ids
  |> list.try_map(fn(id) { scenario.load(root, id) })
  |> result.map(fn(loaded) {
    list.filter(loaded, fn(item) { item.scenario.long == False || options.long })
  })
}

fn calibrate_all(
  root: String,
  selected: List(scenario.Loaded),
  template: String,
  mock: Bool,
  judge_call: JudgeCall,
) -> Result(Bool, String) {
  let rubrics =
    selected
    |> list.map(fn(item) { #(item.scenario.rubric, item.rubric) })
    |> dedupe_by(fn(item) { item.0 })
  use _ <- result.try(
    rubrics
    |> list.try_each(fn(item) {
      let #(rubric_id, rubric) = item
      use cases <- result.try(calibration.load(root, rubric_id))
      let rubric_text =
        read_file(root <> "/rubrics/" <> rubric_id <> ".md")
        |> result.unwrap("")
      let answer = fn(entry: calibration.Case) {
        // Same template and schema as a real run: calibration must exercise
        // the judge that will grade the scenarios.
        let system =
          judge.render_prompt(
            template,
            rubric_text,
            "(não fornecido na calibração)",
            "(não fornecido na calibração)",
            string.join(transcript.numbered_lines_from(entry.lines), "\n"),
          )
        let _ = mock
        case judge_call(system, judge.instruction, Some(judge.schema(rubric))) {
          Error(reason) -> Error(reason)
          Ok(result) -> Ok(judge.parse_answer(rubric, result.text, entry.lines))
        }
      }
      let result = calibration.evaluate(cases, rubric, answer)
      case result.ok {
        True -> Ok(Nil)
        False -> Error(string.join(result.failures, "; "))
      }
    }),
  )
  Ok(True)
}

fn run_scenarios(
  options: Options,
  harness: harness_config.HarnessConfig,
  agent: provider.ProviderConfig,
  root: String,
  selected: List(scenario.Loaded),
  session_dir: String,
  persona_driver: engine.PersonaDriver,
  judge_call: JudgeCall,
  template: String,
  mock: Bool,
  state: ReportState,
) -> Result(ReportState, String) {
  selected
  |> list.try_fold(state, fn(current, loaded) {
    case current.stopped {
      True -> Ok(current)
      False ->
        run_scenario(
          options,
          harness,
          agent,
          root,
          loaded,
          session_dir,
          persona_driver,
          judge_call,
          template,
          mock,
          current,
        )
    }
  })
}

fn run_scenario(
  options: Options,
  harness: harness_config.HarnessConfig,
  agent: provider.ProviderConfig,
  root: String,
  loaded: scenario.Loaded,
  session_dir: String,
  persona_driver: engine.PersonaDriver,
  judge_call: JudgeCall,
  template: String,
  _mock: Bool,
  state: ReportState,
) -> Result(ReportState, String) {
  let scenario = loaded.scenario
  use final <- result.try(
    list.try_fold(run_indexes(options.runs), state, fn(current, index) {
      case current.stopped {
        True -> Ok(current)
        False -> {
          let run_dir =
            session_dir <> "/" <> scenario.id <> "/" <> int.to_string(index)
          let data_dir = run_dir <> "/data"
          use _ <- result.try(ensure_dir(run_dir))
          use output <- result.try(engine.run(
            engine.Input(
              root: root,
              data_dir: data_dir,
              transcript_path: run_dir <> "/transcripts.jsonl",
              agent: agent,
              agent_provider_name: harness.agent_provider,
              persona: persona_driver,
              turn_timeout_seconds: harness.turn_timeout_seconds,
              start_ms: timestamp(),
              instance_daily_usd: harness.instance_daily_usd,
              member_daily_usd: harness.member_daily_usd,
              every_turns: harness.every_turns,
            ),
            loaded,
          ))
          let allowlist =
            scenario.personas
            |> list.map(fn(persona) { "sim:" <> persona.user_id })
          let context =
            checks.Context(
              data_dir: data_dir,
              transcripts_path: output.transcript_path,
              events: output.events,
              prompts: output.prompts,
              allowlist: allowlist,
              denial_text: "Esta instância é privada.",
            )
          let check_results = checks.run_all(context, scenario.checks)
          let lines = transcript.lines(output.events)
          let judge_system =
            judge_prompt(template, root, scenario, loaded, data_dir, lines)
          let schema = judge.schema(loaded.rubric)
          let judge_costs = process.new_subject()
          let answer =
            judge.ask(loaded.rubric, lines, fn() {
              case judge_call(judge_system, judge.instruction, Some(schema)) {
                Ok(result) -> {
                  process.send(judge_costs, result.cost_usd)
                  Ok(result.text)
                }
                Error(reason) -> Error(reason)
              }
            })
          let verdict = judge.verdict(check_results, loaded.rubric, answer)
          let judge_cost = drain_costs(judge_costs)
          let agents_cost = cost.ledger_cost(data_dir)
          let run_costs =
            cost.Costs(
              agents_usd: agents_cost,
              personas_usd: output.persona_cost_usd,
              judge_usd: judge_cost,
            )
          let outcome =
            report.RunOutcome(
              index: index,
              approved: verdict.ok,
              failures: verdict.failures,
              criteria: verdict.criteria,
              costs: run_costs,
              transcript_path: output.transcript_path,
            )
          use _ <- result.try(write_judge(run_dir, verdict, outcome))
          case options.keep_data {
            True -> Nil
            False -> remove_dir(data_dir)
          }
          let scenario_costs = case
            list.find(current.report.outcomes, fn(item) {
              item.id == scenario.id
            })
          {
            Ok(existing) ->
              cost.Costs(
                agents_usd: existing.costs.agents_usd +. agents_cost,
                personas_usd: existing.costs.personas_usd
                  +. output.persona_cost_usd,
                judge_usd: existing.costs.judge_usd +. judge_cost,
              )
            Error(_) -> run_costs
          }
          let scenario_outcome = case
            list.find(current.report.outcomes, fn(item) {
              item.id == scenario.id
            })
          {
            Ok(existing) ->
              report.ScenarioOutcome(
                ..existing,
                runs: list.append(existing.runs, [outcome]),
                costs: scenario_costs,
              )
            Error(_) ->
              report.ScenarioOutcome(
                id: scenario.id,
                critical: scenario.critical,
                runs: [outcome],
                costs: scenario_costs,
              )
          }
          let others =
            list.filter(current.report.outcomes, fn(item) {
              item.id != scenario.id
            })
          let outcomes =
            list.sort(list.append(others, [scenario_outcome]), fn(a, b) {
              string.compare(a.id, b.id)
            })
          let total =
            cost.Costs(
              agents_usd: current.report.total.agents_usd +. agents_cost,
              personas_usd: current.report.total.personas_usd
                +. output.persona_cost_usd,
              judge_usd: current.report.total.judge_usd +. judge_cost,
            )
          let partial = cost.cap_reached(total, options.max_usd)
          Ok(ReportState(
            report: report.Report(
              ..current.report,
              outcomes: outcomes,
              total: total,
              partial: partial,
            ),
            stopped: partial,
          ))
        }
      }
    }),
  )
  Ok(final)
}

fn judge_prompt(
  template: String,
  root: String,
  scenario: scenario.Scenario,
  loaded: scenario.Loaded,
  data_dir: String,
  lines: List(String),
) -> String {
  let rubric_text =
    read_file(root <> "/rubrics/" <> scenario.rubric <> ".md")
    |> result.unwrap("")
  let agents =
    scenario.personas
    |> list.map(fn(persona) {
      let principal = "sim:" <> persona.user_id
      let core =
        read_file(self_core.prose_path(data_dir, principal))
        |> result.unwrap("")
      let addenda = memory.addenda(data_dir, principal)
      "### " <> persona.id <> "\n" <> core <> "\n" <> addenda
    })
    |> string.join("\n\n")
  let personas =
    loaded.personas
    |> list.map(fn(item) { "### " <> item.0 <> "\n" <> item.1 })
    |> string.join("\n\n")
  judge.render_prompt(
    template,
    rubric_text,
    agents,
    personas,
    string.join(transcript.numbered_lines_from(lines), "\n"),
  )
}

type ReportState {
  ReportState(report: report.Report, stopped: Bool)
}

fn write_report(
  session_dir: String,
  value: report.Report,
) -> Result(Nil, String) {
  use _ <- result.try(write_file(
    session_dir <> "/report.md",
    report.render_markdown(value),
  ))
  use _ <- result.try(write_file(
    session_dir <> "/verdicts.json",
    report.render_json(value),
  ))
  Ok(Nil)
}

fn write_judge(
  run_dir: String,
  verdict: judge.Verdict,
  outcome: report.RunOutcome,
) -> Result(Nil, String) {
  let payload =
    "{"
    <> "\"approved\":"
    <> case outcome.approved {
      True -> "true"
      False -> "false"
    }
    <> ",\"failures\":"
    <> json_string_array(verdict.failures)
    <> "}"
  write_file(run_dir <> "/judge.json", payload)
}

fn json_string_array(items: List(String)) -> String {
  "["
  <> string.join(
    list.map(items, fn(item) {
      "\""
      <> string.replace(string.replace(item, "\\", "\\\\"), "\"", "\\\"")
      <> "\""
    }),
    ",",
  )
  <> "]"
}

fn dedupe_by(items: List(a), key: fn(a) -> String) -> List(a) {
  items
  |> list.fold(dict.new(), fn(acc, item) { dict.insert(acc, key(item), item) })
  |> dict.values
}

fn judge_template(root: String) -> Result(String, String) {
  read_file(root <> "/judge_prompt.md")
  |> result.map_error(fn(reason) {
    "judge prompt unavailable (" <> root <> "/judge_prompt.md): " <> reason
  })
}

/// Empty directory outside the repository, so model CLIs load no project
/// instructions (AGENTS.md, CLAUDE.md).
fn temp_dir() -> String {
  scratch_dir()
}

@external(erlang, "supernova_harness_ffi", "scratch_dir")
fn scratch_dir() -> String

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn timestamp() -> Int

@external(erlang, "envoy_ffi", "get")
fn envoy_get(name: String) -> Result(String, Nil)

@external(erlang, "supernova_cli_ffi", "get_args")
fn cli_args() -> List(String)

fn io_println(value: String) -> Nil {
  io.println(value)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "supernova_file_system_ffi", "find_files")
fn find_files(dir: String, pattern: String) -> List(String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

fn run_indexes(count: Int) -> List(Int) {
  run_indexes_loop(count, 1, [])
}

fn run_indexes_loop(count: Int, next: Int, acc: List(Int)) {
  case next > count {
    True -> list.reverse(acc)
    False -> run_indexes_loop(count, next + 1, [next, ..acc])
  }
}

fn drain_costs(subject: process.Subject(Float)) -> Float {
  case process.receive(subject, within: 0) {
    Ok(value) -> value +. drain_costs(subject)
    Error(_) -> 0.0
  }
}

@external(erlang, "supernova_harness_ffi", "remove_dir")
fn remove_dir(path: String) -> Nil
