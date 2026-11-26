//// The `sonda` tool: the agent sends a probe to do something for its
//// person, and goes on talking (PRD-S, S-07, S20).
////
//// A probe is a task of the PRD-F's phase B whose work is the conductor
//// (S14): it shares the task list (at most 7 per agent), the delivery as a
//// message in the chat of origin, /esquecer and the restart notice. Like
//// `tarefa`, the turn runs it, because only the turn knows that chat.

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/adapters/mcp/computer
import supernova/core/executor
import supernova/llm/provider
import supernova/metrics/record
import supernova/self/tasks
import supernova/sondas/condutor
import supernova/sondas/ferramenta
import supernova/sondas/maos

pub const name = ferramenta.name

pub const max_instructions = ferramenta.max_instructions

pub fn tool(may_code: Bool) -> provider.ToolDefinition {
  ferramenta.tool(may_code)
}

/// What a probe needs from the turn that sends it.
pub type Env {
  Env(
    llm_config: provider.ProviderConfig,
    base: executor.RunContext,
    gateway: fn(String, String) -> Result(String, String),
    may_code: Bool,
    costing: condutor.Costing,
    computer: Option(computer.Computer),
  )
}

pub fn execute(
  origin: tasks.Origin,
  args_json: String,
  env: Env,
) -> Result(String, String) {
  let decoder = {
    use kind <- decode.field("tipo", decode.string)
    use instructions <- decode.field("instrucoes", decode.string)
    use reason <- decode.optional_field("motivo", "", decode.string)
    decode.success(#(kind, instructions, reason))
  }
  case json.parse(args_json, decoder), tasks.registry(), env.computer {
    Error(_), _, _ -> Error("sonda precisa de tipo e instrucoes")
    _, None, _ -> Error("sondas indisponíveis agora")
    _, _, None -> Error("sondas indisponíveis: não há computador configurado")
    Ok(#(kind_name, instructions, reason)), Some(registry), Some(pc) ->
      case condutor.parse_kind(kind_name), string.trim(instructions) {
        Error(Nil), _ -> Error("tipo de sonda desconhecido: " <> kind_name)
        _, "" -> Error("sonda precisa de instrucoes")
        Ok(condutor.Code), _ if !env.may_code ->
          Error("a sonda de código precisa do computador, que você não tem")
        Ok(kind), instructions ->
          case string.length(instructions) > max_instructions {
            True ->
              Error(
                "instrucoes passam de "
                <> int.to_string(max_instructions)
                <> " caracteres",
              )
            False ->
              start(registry, pc, origin, kind, instructions, reason, env)
          }
      }
  }
}

fn start(
  registry: tasks.Registry,
  pc: computer.Computer,
  origin: tasks.Origin,
  kind: condutor.Kind,
  instructions: String,
  reason: String,
  env: Env,
) -> Result(String, String) {
  let limits = condutor.default_limits(kind)
  let label = condutor.kind_name(kind)
  let reason = case string.trim(reason) {
    "" -> string.slice(instructions, 0, 60)
    reason -> reason
  }
  let arguments =
    json.to_string(json.object([#("instrucoes", json.string(instructions))]))
  let work = fn(id) {
    let outcome = {
      case maos.open(pc, kind, origin.agent_id, id, env.gateway) {
        Error(reason) -> Error("o computador não abriu a sonda: " <> reason)
        Ok(hands) ->
          condutor.run(
            kind,
            instructions,
            limits,
            hands,
            env.base,
            env.llm_config,
            env.costing,
          )
      }
    }
    record.count("sondas_total", [
      #("tipo", label),
      #("desfecho", ending_of(outcome)),
    ])
    outcome
  }
  case
    tasks.begin_work(
      registry,
      origin,
      "sonda_" <> label,
      arguments,
      reason,
      limits.duration_ms,
      work,
    )
  {
    Error(reason) -> Error(reason)
    Ok(id) ->
      Ok(
        "Sonda "
        <> label
        <> " #"
        <> int.to_string(id)
        <> " disparada (prazo de "
        <> int.to_string(limits.duration_ms / 60_000)
        <> " min, até US$ "
        <> float.to_string(limits.cost_usd)
        <> "). Avise sua pessoa; o resultado chega depois como mensagem [Sonda "
        <> label
        <> " #"
        <> int.to_string(id)
        <> "] neste chat. Não diga o resultado antes de ele chegar.",
      )
  }
}

fn ending_of(outcome: Result(String, String)) -> String {
  case outcome {
    Error(_) -> "falhou"
    Ok(report) ->
      case string.starts_with(report, "custo esgotado") {
        True -> "custo_esgotado"
        False -> "concluida"
      }
  }
}

pub fn declare_metrics() -> Nil {
  ["web", "disco", "codigo"]
  |> list_each(fn(kind) {
    ["concluida", "custo_esgotado", "falhou"]
    |> list_each(fn(ending) {
      record.declare("sondas_total", [#("tipo", kind), #("desfecho", ending)])
    })
  })
}

fn list_each(items: List(a), f: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [item, ..rest] -> {
      f(item)
      list_each(rest, f)
    }
  }
}
