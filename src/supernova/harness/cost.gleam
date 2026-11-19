//// Cost accounting. Persona and judge costs come from the CLI output; agent
//// cost comes from the run's ledger. The cap is hard: the run stops.

import gleam/dynamic/decode
import gleam/int
import gleam/json
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

/// One ledger line's cost, read as JSON. A digit filter turned `1.89e-4`
/// into 1.894 dollars; JSON numbers may be floats, scientific or integers.
fn ledger_line_cost(line: String) -> Float {
  let decoder = {
    use cost <- decode.optional_field(
      "cost_usd",
      0.0,
      decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)]),
    )
    decode.success(cost)
  }
  case string.trim(line) {
    "" -> 0.0
    trimmed ->
      case json.parse(from: trimmed, using: decoder) {
        Ok(cost) -> cost
        Error(_) -> 0.0
      }
  }
}

@external(erlang, "supernova_file_system_ffi", "find_files")
fn find_files(dir: String, pattern: String) -> List(String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
