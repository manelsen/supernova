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
import gleam/result
import gleam/string
import supernova/adapters/mcp/computer
import supernova/aprovacao/pedido
import supernova/aprovacao/servico as aprovacao_servico
import supernova/core/executor
import supernova/core/principal
import supernova/llm/provider
import supernova/metrics/record
import supernova/self/aprovacoes
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
    /// A probe action through the gateway: authorized as `sonda`, audited,
    /// not charged to the hourly tool budget.
    audited: fn(String, fn() -> Result(String, String)) ->
      Result(String, String),
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
    use ceiling <- decode.optional_field(
      "teto_usd",
      None,
      decode.one_of(decode.float |> decode.map(Some), [
        decode.int |> decode.map(fn(n) { Some(int.to_float(n)) }),
        decode.string |> decode.map(parse_money),
      ]),
    )
    decode.success(#(kind, instructions, reason, ceiling))
  }
  case json.parse(args_json, decoder), tasks.registry(), env.computer {
    Error(_), _, _ -> Error("sonda precisa de tipo e instrucoes")
    _, None, _ -> Error("sondas indisponíveis agora")
    _, _, None -> Error("sondas indisponíveis: não há computador configurado")
    Ok(#(kind_name, instructions, reason, ceiling)), Some(registry), Some(pc) ->
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
              case spending(origin, kind, instructions, ceiling) {
                Error(answer) -> answer
                Ok(cost) ->
                  start(
                    registry,
                    pc,
                    origin,
                    kind,
                    instructions,
                    reason,
                    env,
                    cost,
                  )
              }
          }
      }
  }
}

/// Above this, a probe's ceiling needs the person's yes first (K8).
pub const asks_above_usd = 0.5

/// The highest ceiling a probe may declare.
pub const max_usd = 5.0

fn parse_money(text: String) -> Option(Float) {
  let text = string.replace(string.trim(text), ",", ".")
  case float.parse(text), int.parse(text) {
    Ok(value), _ -> Some(value)
    _, Ok(n) -> Some(int.to_float(n))
    _, _ -> None
  }
}

/// US$ with two decimals, as the person reads it and the grant names it.
pub fn money(value: Float) -> String {
  let cents = float.round(value *. 100.0)
  let whole = cents / 100
  let rest = cents % 100
  int.to_string(whole)
  <> ","
  <> case rest < 10 {
    True -> "0"
    False -> ""
  }
  <> int.to_string(rest)
}

/// The probe's cost ceiling: the default; a declared one up to the limit;
/// above US$ 0.50, only with the person's yes (PRD-K, K8, K-10). Error is
/// the tool's answer (a refusal, or "I asked").
fn spending(
  origin: tasks.Origin,
  kind: condutor.Kind,
  instructions: String,
  ceiling: Option(Float),
) -> Result(Float, Result(String, String)) {
  let default = condutor.default_limits(kind).cost_usd
  case ceiling {
    None -> Ok(default)
    Some(value) if value <=. 0.0 -> Error(Error("teto_usd precisa ser positivo"))
    Some(value) if value >. max_usd ->
      Error(Error("o teto de uma sonda é no máximo US$ " <> money(max_usd)))
    Some(value) if value <=. asks_above_usd -> Ok(value)
    Some(value) -> {
      let target = "sonda:" <> money(value)
      case aprovacao_servico.get() {
        None -> Error(Error("aprovações não estão disponíveis agora"))
        Some(context) ->
          case
            aprovacoes.allowed(
              context.data_dir,
              origin.principal,
              context.clock(),
              aprovacoes.Spend,
              target,
              None,
            )
          {
            Error(reason) -> Error(Error(reason))
            Ok(True) -> Ok(value)
            Ok(False) ->
              Error(aprovacao_servico.pedir(
                context,
                origin.principal,
                aprovacoes.Draft(
                  kind: aprovacoes.Spend,
                  target: target,
                  summary: pedido.first_sentence(
                    "Gastar até US$ "
                    <> money(value)
                    <> " numa sonda de "
                    <> condutor.kind_name(kind)
                    <> ": "
                    <> string.slice(instructions, 0, 60)
                    <> ".",
                  ),
                  explanation: "",
                  task: None,
                  approve: aprovacoes.Once,
                  always: False,
                  origin: aprovacoes.Chat(
                    origin.channel,
                    origin.channel_id,
                    origin.user_id,
                  ),
                ),
                in_group: !principal.is_private_chat(
                  origin.channel,
                  origin.channel_id,
                ),
              ))
          }
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
  cost: Float,
) -> Result(String, String) {
  let limits = condutor.Limits(..condutor.default_limits(kind), cost_usd: cost)
  let label = condutor.kind_name(kind)
  let reason = case string.trim(reason) {
    "" -> string.slice(instructions, 0, 60)
    reason -> reason
  }
  let arguments =
    json.to_string(json.object([#("instrucoes", json.string(instructions))]))
  let work = fn(id) {
    let outcome = {
      case maos.open(pc, kind, origin.agent_id, id, env.gateway, env.audited) {
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
    result.map(outcome, fn(delivered) { delivered.1 })
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

fn ending_of(outcome: Result(#(condutor.Ending, String), String)) -> String {
  case outcome {
    Error(_) -> "falhou"
    Ok(#(condutor.Concluded, _)) -> "concluida"
    Ok(#(condutor.CostExhausted, _)) -> "custo_esgotado"
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
