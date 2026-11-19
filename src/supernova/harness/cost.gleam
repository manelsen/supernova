//// Cost accounting. Persona and judge costs come from the CLI output; agent
//// cost comes from the run's ledger. The cap is hard: the run stops.

import gleam/float
import gleam/list
import gleam/string

pub type Costs {
  Costs(agents_usd: Float, personas_usd: Float, judge_usd: Float)
}

pub fn zero() -> Costs {
  Costs(agents_usd: 0.0, personas_usd: 0.0, judge_usd: 0.0)
}

pub fn total(costs: Costs) -> Float {
  costs.agents_usd +. costs.personas_usd +. costs.judge_usd
}

pub fn add_persona(costs: Costs, amount: Float) -> Costs {
  Costs(..costs, personas_usd: costs.personas_usd +. amount)
}

pub fn add_judge(costs: Costs, amount: Float) -> Costs {
  Costs(..costs, judge_usd: costs.judge_usd +. amount)
}

pub fn with_agents(costs: Costs, amount: Float) -> Costs {
  Costs(..costs, agents_usd: amount)
}

pub fn cap_reached(costs: Costs, max_usd: Float) -> Bool {
  total(costs) >=. max_usd
}

/// Sum of `cost_usd` in every ledger line under `<data_dir>/ledger`.
pub fn ledger_cost(data_dir: String) -> Float {
  find_files(data_dir <> "/ledger", "*.jsonl")
  |> list.fold(0.0, fn(total, path) {
    case read_file(path) {
      Error(_) -> total
      Ok(raw) ->
        raw
        |> string.split("\n")
        |> list.fold(total, fn(inner, line) { inner +. ledger_line_cost(line) })
    }
  })
}

fn ledger_line_cost(line: String) -> Float {
  case string.split(line, "\"cost_usd\":") {
    [_, rest, ..] -> {
      let value =
        rest
        |> string.split(",")
        |> list.first
        |> unwrap_or("0")
        |> string.to_graphemes
        |> list.filter(fn(g) { string.contains("0123456789.", g) })
        |> string.concat
      case float.parse(value) {
        Ok(parsed) -> parsed
        Error(_) -> 0.0
      }
    }
    _ -> 0.0
  }
}

fn unwrap_or(value: Result(a, b), default: a) -> a {
  case value {
    Ok(inner) -> inner
    Error(_) -> default
  }
}

@external(erlang, "supernova_file_system_ffi", "find_files")
fn find_files(dir: String, pattern: String) -> List(String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
