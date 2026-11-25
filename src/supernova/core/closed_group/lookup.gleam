//// Who someone is in the closed group, asked without side effects: no audit
//// entry, no denial notice spent, no abuse count. For questions asked before
//// a turn (Discord autocomplete on every keystroke, whether to download an
//// attachment); the gate still decides the turn itself.

import gleam/option.{type Option, None, Some}
import supernova/core/access/actor as access_actor
import supernova/core/access/types as access_types
import supernova/core/agent_identity
import supernova/core/closed_group/global
import supernova/core/closed_group/pure

/// The person behind `user_id` (linked identities resolved) and their role,
/// when they have access and the chat is allowed for them. None without a
/// runtime.
pub fn role(
  channel: String,
  chat_id: String,
  user_id: String,
) -> Option(#(String, access_types.Role)) {
  case global.get_runtime() {
    None -> None
    Some(runtime) -> {
      let principal = agent_identity.principal_id(channel, user_id)
      case access_actor.try_check(runtime.access, principal) {
        Ok(access_types.Allowed(role)) ->
          case
            access_actor.check_chat(
              runtime.access,
              principal,
              pure.chat_key(channel, chat_id),
              pure.is_private_chat(channel, chat_id),
            )
          {
            access_types.ChatAllowed -> Some(#(principal, role))
            access_types.ChatDenied -> None
          }
        _ -> None
      }
    }
  }
}
