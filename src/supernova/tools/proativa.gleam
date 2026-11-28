//// PRD-Q, Q-02: the person sets how the agent starts conversations on its
//// own, in their words; the agent turns that into this tool. On by default
//// (D2).

import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import supernova/agenda/runtime as agenda_runtime
import supernova/llm/provider
import supernova/proativa/estado

pub const name = "proativa"

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: name,
    description: "How you start conversations on your own (a few times a day you may bring up something interesting; never at night, never twice without an answer). Use it when your person says how they want it: ver (show the settings), desligar (\"stop messaging me on your own\"), ligar, mais or menos (more or fewer times a day), silencio with de and ate (hours 0-23 of quiet, e.g. de 22 ate 8), assuntos with assuntos = leve (only ask lightly how they are about sensitive things), livres (you may come back to anything they told you) or so_meus (never bring sensitive things up). Tell them in one sentence what changed.",
    parameters: [
      provider.string_param(
        "acao",
        "ver, ligar, desligar, mais, menos, silencio or assuntos",
        True,
      ),
      provider.integer_param("de", "silencio: quiet from this hour", False),
      provider.integer_param("ate", "silencio: quiet until this hour", False),
      provider.string_param(
        "assuntos",
        "assuntos: leve, livres or so_meus",
        False,
      ),
    ],
  )
}

pub fn execute(principal: String, args_json: String) -> Result(String, String) {
  case agenda_runtime.get() {
    None -> Error("proativa unavailable: no data directory")
    Some(context) -> execute_for(context.data_dir, principal, args_json)
  }
}

pub fn execute_for(
  data_dir: String,
  principal: String,
  args_json: String,
) -> Result(String, String) {
  let decoder = {
    use acao <- decode.field("acao", decode.string)
    use de <- decode.optional_field("de", -1, decode.int)
    use ate <- decode.optional_field("ate", -1, decode.int)
    use assuntos <- decode.optional_field("assuntos", "", decode.string)
    decode.success(#(acao, de, ate, assuntos))
  }
  use #(acao, de, ate, assuntos) <- result.try(
    json.parse(args_json, decoder)
    |> result.replace_error("invalid arguments: expected acao"),
  )
  let mudanca = case acao {
    "ver" -> Ok(Ok)
    "ligar" -> Ok(fn(e) { Ok(estado.ligar(e)) })
    "desligar" -> Ok(fn(e) { Ok(estado.desligar(e)) })
    "mais" -> Ok(fn(e) { Ok(estado.mais(e)) })
    "menos" -> Ok(fn(e) { Ok(estado.menos(e)) })
    "silencio" -> Ok(fn(e) { estado.silencio(e, de, ate) })
    "assuntos" ->
      case estado.assuntos_de(assuntos) {
        Ok(a) -> Ok(fn(e) { Ok(estado.com_assuntos(e, a)) })
        Error(Nil) -> Error("assuntos must be leve, livres or so_meus")
      }
    _ ->
      Error(
        "acao must be ver, ligar, desligar, mais, menos, silencio or assuntos",
      )
  }
  use mudanca <- result.try(mudanca)
  estado.mudar(data_dir, principal, mudanca)
  |> result.map(estado.resumo)
}
