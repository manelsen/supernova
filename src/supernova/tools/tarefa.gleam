//// The `tarefa` tool: run another tool in the background and get its
//// result later, as a message (PRD-F, phase B, F-05).
////
//// It is not run by the syscall gateway like the other tools: starting a
//// task needs the chat of origin, which only the turn knows. The turn
//// handles it (`channel_common_router`) and passes the gateway's own
//// invoke, so the background call is authorized, charged and audited like
//// any tool call of that person.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/llm/provider
import supernova/self/tasks

pub const name = "tarefa"

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: name,
    description: "Run another of your tools in the background, when it may take long (a search, a page, a command): you answer your person at once and the result arrives later as a message \"[Tarefa] …\" in this same chat; then tell your person. Never invent the result before it arrives. Also list your running tasks or cancel one. At most "
      <> int.to_string(tasks.max_running)
      <> " at once, each up to 30 minutes.",
    parameters: [
      provider.string_param("acao", "Action: iniciar, listar, cancelar", True),
      provider.string_param(
        "ferramenta",
        "For iniciar: the name of the tool to run in the background.",
        False,
      ),
      provider.string_param(
        "argumentos",
        "For iniciar: the arguments for that tool, as a JSON object.",
        False,
      ),
      provider.string_param(
        "motivo",
        "For iniciar: in a few words, what the task is for; you will see it when the result arrives.",
        False,
      ),
      provider.integer_param("id", "For cancelar: the task id.", False),
    ],
  )
}

type Request {
  Start(tool: String, arguments: String, reason: String)
  ListOpen
  CancelOne(id: Int)
}

/// Run one `tarefa` call for `origin`. `invoke` runs a tool call for the
/// same person through the gateway.
pub fn execute(
  origin: tasks.Origin,
  args_json: String,
  invoke: tasks.Invoke,
) -> Result(String, String) {
  case tasks.registry(), parse(args_json) {
    None, _ -> Error("tarefas indisponíveis agora")
    _, Error(reason) -> Error(reason)
    Some(registry), Ok(Start(tool, arguments, reason)) ->
      case tasks.begin(registry, origin, tool, arguments, reason, invoke) {
        Ok(id) ->
          Ok(
            "Tarefa "
            <> int.to_string(id)
            <> " iniciada ("
            <> tool
            <> "). Avise sua pessoa; o resultado chega depois como mensagem"
            <> " [Tarefa] neste chat. Não diga o resultado antes de ele chegar.",
          )
        Error(reason) -> Error(reason)
      }
    Some(registry), Ok(ListOpen) ->
      Ok(listing(tasks.list_open(registry, origin.agent_id)))
    Some(registry), Ok(CancelOne(id)) ->
      case tasks.cancel(registry, origin.agent_id, id) {
        Ok(Nil) -> Ok("Tarefa " <> int.to_string(id) <> " cancelada.")
        Error(reason) -> Error(reason)
      }
  }
}

fn listing(open: List(tasks.Task)) -> String {
  case open {
    [] -> "Nenhuma tarefa em andamento."
    _ ->
      "Tarefas:\n"
      <> {
        open
        |> list.map(fn(task) {
          "- "
          <> int.to_string(task.id)
          <> " ("
          <> task.reason
          <> ", "
          <> task.tool
          <> "): "
          <> case task.status {
            tasks.Running -> "rodando"
            _ -> "terminou; o resultado está a caminho"
          }
        })
        |> string.join("\n")
      }
  }
}

fn parse(args_json: String) -> Result(Request, String) {
  let decoder = {
    use action <- decode.field("acao", decode.string)
    use tool <- decode.optional_field("ferramenta", "", decode.string)
    use arguments <- decode.optional_field(
      "argumentos",
      None,
      decode.dynamic |> decode.map(Some),
    )
    use reason <- decode.optional_field("motivo", "", decode.string)
    use id <- decode.optional_field("id", None, decode.optional(decode.int))
    decode.success(#(action, tool, arguments, reason, id))
  }
  case json.parse(args_json, decoder) {
    Error(_) -> Error("argumentos inválidos para tarefa")
    Ok(#(action, tool, arguments, reason, id)) ->
      case string.lowercase(string.trim(action)), id {
        "iniciar", _ ->
          case string.trim(tool), arguments_json(arguments) {
            "", _ -> Error("iniciar precisa de ferramenta")
            _, Error(reason) -> Error(reason)
            tool, Ok(arguments) ->
              Ok(
                Start(tool, arguments, case string.trim(reason) {
                  "" -> tool
                  reason -> reason
                }),
              )
          }
        "listar", _ -> Ok(ListOpen)
        "cancelar", Some(id) -> Ok(CancelOne(id))
        "cancelar", None -> Error("cancelar precisa do id")
        other, _ -> Error("ação desconhecida: " <> other)
      }
  }
}

/// The tool's arguments as a JSON object text. Models send them either as
/// an object or as a string holding one.
fn arguments_json(
  arguments: Option(dynamic.Dynamic),
) -> Result(String, String) {
  case arguments {
    None -> Ok("{}")
    Some(value) ->
      case decode.run(value, decode.string) {
        Ok(text) ->
          case json.parse(text, decode.dynamic) {
            Ok(_) -> Ok(text)
            Error(_) -> Error("argumentos precisa ser um objeto JSON")
          }
        Error(_) ->
          case dynamic_to_json(value) {
            Ok(text) -> Ok(text)
            Error(_) -> Error("argumentos precisa ser um objeto JSON")
          }
      }
  }
}

@external(erlang, "supernova_mcp_ffi", "dynamic_to_json")
fn dynamic_to_json(value: dynamic.Dynamic) -> Result(String, String)
