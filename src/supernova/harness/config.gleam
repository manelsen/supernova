//// harness.yaml: which models to use, credentials by env name, and caps.

import gleam/float
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/harness/cli_model
import yay

pub type HarnessConfig {
  HarnessConfig(
    agent_provider: String,
    agent_model: String,
    agent_api_key_env: Option(String),
    persona: cli_model.CliConfig,
    judge: cli_model.CliConfig,
    instance_daily_usd: Float,
    member_daily_usd: Float,
    every_turns: Int,
    turn_timeout_seconds: Int,
  )
}

pub fn load(path: String) -> Result(HarnessConfig, String) {
  use documents <- result.try(
    yay.parse_file(path)
    |> result.map_error(fn(error) {
      "cannot read harness config " <> path <> ": " <> string.inspect(error)
    }),
  )
  let root = case documents {
    [document, ..] -> document.root
    [] -> yay.NodeNil
  }
  use agent <- result.try(section(root, "agent"))
  use persona <- result.try(section(root, "persona"))
  use judge <- result.try(section(root, "judge"))
  let budget = case section(root, "budget") {
    Ok(node) -> node
    Error(_) -> yay.NodeNil
  }
  let reflection = case section(root, "reflection") {
    Ok(node) -> node
    Error(_) -> yay.NodeNil
  }
  Ok(HarnessConfig(
    agent_provider: string_or(agent, "provider", ""),
    agent_model: string_or(agent, "model", ""),
    agent_api_key_env: optional_string(agent, "api_key_env"),
    persona: cli_config(persona, 0.05, "omp"),
    judge: cli_config(judge, 0.5, "claude"),
    instance_daily_usd: float_or(budget, "instance_daily_usd", 2.0),
    member_daily_usd: float_or(budget, "member_daily_usd", 0.5),
    every_turns: int_or(reflection, "every_turns", 6),
    turn_timeout_seconds: int_or(root, "turn_timeout_seconds", 120),
  ))
}

fn section(root: yay.Node, name: String) -> Result(yay.Node, String) {
  yay.select_sugar(root, name)
  |> result.map_error(fn(_) { "missing section in harness.yaml: " <> name })
}

fn cli_config(
  node: yay.Node,
  default_budget: Float,
  default_cli: String,
) -> cli_model.CliConfig {
  let cli = string_or(node, "cli", default_cli)
  let kind = case cli {
    "omp" -> cli_model.Omp
    _ -> cli_model.Claude
  }
  cli_model.CliConfig(
    kind: kind,
    executable: string_or(node, "executable", cli),
    model: string_or(node, "model", ""),
    max_usd_per_call: float_or(node, "max_usd_per_call", default_budget),
    timeout_seconds: int_or(node, "timeout_seconds", 180),
  )
}

fn string_or(node: yay.Node, key: String, default: String) -> String {
  yay.extract_string_or(node, key, default)
  |> result.unwrap(default)
}

fn optional_string(node: yay.Node, key: String) -> Option(String) {
  case yay.extract_optional_string(node, key) {
    Ok(Some(value)) -> Some(value)
    _ -> None
  }
}

fn int_or(node: yay.Node, key: String, default: Int) -> Int {
  yay.extract_int_or(node, key, default)
  |> result.unwrap(default)
}

fn float_or(node: yay.Node, key: String, default: Float) -> Float {
  case yay.extract_string_or(node, key, "") {
    Ok(raw) ->
      case float.parse(raw) {
        Ok(value) -> value
        Error(_) -> default
      }
    Error(_) -> default
  }
}
