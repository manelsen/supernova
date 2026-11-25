//// Suggestions for command arguments while they are typed (Discord
//// autocomplete, PRD-D 6.3), for any channel that asks.
////
//// The person is resolved like in the gate (linked identities included),
//// but nothing is audited and no denial notice is spent: a suggestion is
//// asked on every keystroke. Who has no access gets nothing; only an admin
//// sees admin commands and the list of principals.

import gleam/list
import gleam/option.{None, Some}
import supernova/agenda/runtime as agenda_runtime
import supernova/agenda/store as agenda_store
import supernova/core/access/actor as access_actor
import supernova/core/access/types as access_types
import supernova/core/agent_identity
import supernova/core/closed_group/commands
import supernova/core/closed_group/global
import supernova/core/closed_group/pure
import supernova/llm/catalog

/// Suggestions as `#(label, value)` for `command` (without the slash) while
/// `typed` is written by `user_id` in `chat_id`.
pub fn for_sender(
  channel: String,
  chat_id: String,
  user_id: String,
  command: String,
  typed: String,
) -> List(#(String, String)) {
  case global.get_runtime() {
    None -> []
    Some(runtime) -> {
      let principal = agent_identity.principal_id(channel, user_id)
      case access_actor.try_check(runtime.access, principal) {
        Ok(access_types.Allowed(role)) -> {
          let chat =
            access_actor.check_chat(
              runtime.access,
              principal,
              pure.chat_key(channel, chat_id),
              pure.is_private_chat(channel, chat_id),
            )
          case chat {
            access_types.ChatAllowed -> {
              let is_admin = role == access_types.Admin
              commands.suggest(
                command,
                typed,
                is_admin,
                sources(runtime.access, principal, command, is_admin),
              )
            }
            access_types.ChatDenied -> []
          }
        }
        _ -> []
      }
    }
  }
}

fn sources(
  access: access_actor.AccessActor,
  principal: String,
  command: String,
  is_admin: Bool,
) -> commands.Sources {
  let models = case command {
    "model" ->
      case catalog.global() {
        Some(found) ->
          list.map(catalog.choices(found), fn(choice) {
            choice.provider <> " " <> choice.model
          })
        None -> []
      }
    _ -> []
  }
  let agenda = case command, agenda_runtime.get() {
    "agenda", Some(context) ->
      agenda_store.list(context.data_dir, principal)
      |> list.map(fn(entry) { #(entry.id, entry.request) })
    _, _ -> []
  }
  let principals = case command, is_admin {
    "acesso", True ->
      list.append(
        access_actor.list_admins(access),
        access_actor.list_members(access),
      )
      |> list.unique
    _, _ -> []
  }
  commands.Sources(models: models, agenda: agenda, principals: principals)
}
