//// Google Chat Adapter — implements the ChannelPort contract for Google Chat.
///
///
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port
import supernova/channel/session.{type SessionResolver, without_manager}

// ============================================================================
// Public API
// ============================================================================

pub fn start(
  webhook_url: String,
  _handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  let send_fn = fn(reply: port.ChannelReply) -> Result(Nil, port.ChannelError) {
    do_send(webhook_url, reply)
  }
  Ok(port.ChannelAdapter(name: "google_chat", send: send_fn))
}

pub fn parse_event(event_json: String) -> Result(port.ChannelMessage, port.ChannelError) {
  case string.contains(event_json, "\"type\":\"MESSAGE\"") {
    True -> parse_message_event(event_json)
    False -> Error(port.Ignored("non-message event"))
  }
}

fn parse_message_event(json: String) -> Result(port.ChannelMessage, port.ChannelError) {
  let space_name = get_field_2(json, "\"space\"", "\"name\":\"")
  let msg_name = get_field_2(json, "\"message\"", "\"name\":\"")
  let msg_text = get_opt_field_2(json, "\"message\"", "\"text\":\"")
  let sender_name = get_field_3(json, "\"message\"", "\"sender\"", "\"name\":\"")
  let sender_type = get_opt_field_3(json, "\"message\"", "\"sender\"", "\"type\":\"")
  let thread_name = get_opt_field_4(json, "\"message\"", "\"thread\"", "\"replyToMessage\"", "\"name\":\"")
  
  case space_name, msg_name, sender_name {
    Some(space), Some(msg), Some(sender) -> {
      case sender_type {
        Some("BOT") -> Error(port.Ignored("bot sender filtered"))
        _ -> {
          case msg_text {
            Some(text) -> {
              case string.length(text) {
                0 -> Error(port.Ignored("empty content"))
                _ -> Ok(port.ChannelMessage(
                  id: msg,
                  channel: "google_chat",
                  channel_id: space,
                  user_id: sender,
                  username: "",
                  content: text,
                  is_bot: False,
                  reply_to_id: thread_name,
                ))
              }
            }
            None -> Error(port.Ignored("empty content"))
          }
        }
      }
    }
    _, _, _ -> Error(port.SendFailed("missing required fields"))
  }
}

pub fn build_reply_payload(reply: port.ChannelReply) -> Result(String, port.ChannelError) {
  Ok("{\"text\": \"" <> escape_json(reply.content) <> "\"}")
}

fn escape_json(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
}

pub fn resolve_session_id(msg: port.ChannelMessage) -> String {
  "google_chat:" <> msg.channel_id <> ":" <> msg.user_id
}

pub fn session_resolver() -> SessionResolver {
  without_manager("google_chat")
}

// ============================================================================
// Internal: JSON Field Extraction
// ============================================================================

// 2-level extraction: parent -> field
fn get_field_2(json: String, parent: String, field: String) -> Option(String) {
  case string.split_once(json, parent) {
    Ok(#(_, rest)) -> {
      case string.split_once(rest, field) {
        Ok(#(_, value_rest)) -> {
          case string.split_once(value_rest, "\"") {
            Ok(#(value, _)) -> Some(value)
            Error(_) -> None
          }
        }
        Error(_) -> None
      }
    }
    Error(_) -> None
  }
}

// 2-level optional extraction
fn get_opt_field_2(json: String, p1: String, field: String) -> Option(String) {
  get_field_2(json, p1, field)
}

// 3-level extraction: parent1 -> parent2 -> field
fn get_field_3(json: String, p1: String, p2: String, field: String) -> Option(String) {
  case string.split_once(json, p1) {
    Ok(#(_, after_p1)) -> {
      case string.split_once(after_p1, p2) {
        Ok(#(_, after_p2)) -> {
          case string.split_once(after_p2, field) {
            Ok(#(_, value_rest)) -> {
              case string.split_once(value_rest, "\"") {
                Ok(#(value, _)) -> Some(value)
                Error(_) -> None
              }
            }
            Error(_) -> None
          }
        }
        Error(_) -> None
      }
    }
    Error(_) -> None
  }
}

// 3-level optional extraction
fn get_opt_field_3(json: String, p1: String, p2: String, field: String) -> Option(String) {
  get_field_3(json, p1, p2, field)
}

// 4-level extraction: parent1 -> parent2 -> parent3 -> field
fn get_field_4(json: String, p1: String, p2: String, p3: String, field: String) -> Option(String) {
  case string.split_once(json, p1) {
    Ok(#(_, after_p1)) -> {
      case string.split_once(after_p1, p2) {
        Ok(#(_, after_p2)) -> {
          case string.split_once(after_p2, p3) {
            Ok(#(_, after_p3)) -> {
              case string.split_once(after_p3, field) {
                Ok(#(_, value_rest)) -> {
                  case string.split_once(value_rest, "\"") {
                    Ok(#(value, _)) -> Some(value)
                    Error(_) -> None
                  }
                }
                Error(_) -> None
              }
            }
            Error(_) -> None
          }
        }
        Error(_) -> None
      }
    }
    Error(_) -> None
  }
}

// 4-level optional extraction
fn get_opt_field_4(json: String, p1: String, p2: String, p3: String, field: String) -> Option(String) {
  get_field_4(json, p1, p2, p3, field)
}

// ============================================================================
// Internal: Sending
// ============================================================================

fn do_send(_webhook_url: String, reply: port.ChannelReply) -> Result(Nil, port.ChannelError) {
  Error(port.NotConnected)
}
