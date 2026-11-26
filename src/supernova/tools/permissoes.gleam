//// The `permissoes` tool (PRD-K, K-02): the agent lists its person's
//// permanent permissions and revokes one when the person asks. It cannot
//// grant: only the person does, by answering a request (K3). The syscall
//// gateway passes the caller's principal, so an agent only ever sees and
//// changes its own person's permissions.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import supernova/aprovacao/permissoes
import supernova/aprovacao/servico
import supernova/llm/provider
import supernova/self/aprovacoes

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "permissoes",
    description: "List your person's permanent permissions (what you may do without asking each time), or revoke one when your person asks you to. You cannot grant permissions: only your person can, by answering a request for approval.",
    parameters: [
      provider.string_param("action", "Action: list, revoke", True),
      provider.integer_param("id", "For revoke: the permission number.", False),
    ],
  )
}

pub fn execute(principal: String, args_json: String) -> Result(String, String) {
  case servico.get() {
    None -> Error("permissoes unavailable: approvals not configured")
    Some(context) -> execute_for(context.data_dir, principal, args_json)
  }
}

pub fn execute_for(
  data_dir: String,
  principal: String,
  args_json: String,
) -> Result(String, String) {
  let args = {
    use action <- decode.field("action", decode.string)
    use id <- decode.optional_field("id", 0, decode.int)
    decode.success(#(action, id))
  }
  case json.parse(args_json, args) {
    Error(_) -> Error("invalid arguments: expected action (list or revoke)")
    Ok(#("list", _)) -> {
      use grants <- result.map(aprovacoes.permissions(data_dir, principal))
      permissoes.listing(grants)
    }
    Ok(#("revoke", id)) -> {
      use grants <- result.try(aprovacoes.permissions(data_dir, principal))
      case list.any(grants, fn(g) { g.id == id }) {
        False -> Ok(permissoes.not_found(id))
        True -> {
          use grant <- result.map(aprovacoes.revoke(data_dir, principal, id))
          permissoes.revoked(grant)
        }
      }
    }
    Ok(#(other, _)) ->
      Error("unknown action " <> other <> ": use list or revoke")
  }
}
