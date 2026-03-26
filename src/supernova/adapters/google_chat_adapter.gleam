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
  case extract_event_type(event_json) {
    Ok("MESSAGE") -> {
      case extract_space_name(event_json) {
        Ok(space_name) -> {
          case extract_msg_name(event_json) {
            Ok(msg_name) -> {
              case extract_msg_text(event_json) {
                Ok(msg_text) -> {
                  case extract_sender_name(event_json) {
                    Ok(sender_name) -> {
                      case extract_sender_type(event_json) {
                        sender_type -> {
                          normalize_message(space_name, msg_name, msg_text, sender_name, sender_type)
                        }
                      }
                    }
                    Error(_) -> Error(port.SendFailed("invalid JSON"))
                  }
                }
                Error(_) -> Error(port.SendFailed("invalid JSON"))
              }
            }
            Error(_) -> Error(port.SendFailed("invalid JSON"))
          }
        }
        Error(_) -> Error(port.SendFailed("invalid JSON"))
      }
    }
    Ok(_) -> Error(port.Ignored("non-message event"))
    Error(_) -> Error(port.SendFailed("invalid JSON"))
  }
}

fn normalize_message(
  space_name: String,
  msg_name: String,
  msg_text: Option(String),
  sender_name: String,
  sender_type: Option(String),
) -> Result(port.ChannelMessage, port.ChannelError) {
  // Check for bot sender
  case sender_type {
    Some("BOT") -> Error(port.Ignored("bot sender filtered"))
    _ -> {
      // Check for empty text
      case msg_text {
        Some(text) -> {
          case is_empty_string(text) {
            True -> Error(port.Ignored("empty content"))
            False -> Ok(port.ChannelMessage(
              id: msg_name,
              channel: "google_chat",
              channel_id: space_name,
              user_id: sender_name,
              username: "",
              content: text,
              is_bot: False,
              reply_to_id: None,
            ))
          }
        }
        None -> Error(port.Ignored("empty content"))
      }
    }
  }
}

fn is_empty_string(s: String) -> Bool {
  case string.length(s) {
    0 -> True
    _ -> False
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
// Internal: Simple JSON Field Extraction
// ============================================================================

fn extract_event_type(json: String) -> Result(String, String) {
  extract_quoted_field(json, "type")
}

fn extract_space_name(json: String) -> Result(String, String) {
  case extract_quoted_field(json, "space") {
    Ok(v) -> Ok(v)
    Error(_) -> {
      // Try nested: "space": {"name": "..."}
      case extract_quoted_field(json, "name") {
        Ok(v) -> Ok(v)
        Error(e) -> Error(e)
      }
    }
  }
}

fn extract_msg_name(json: String) -> Result(String, String) {
  case extract_quoted_field(json, "name") {
    Ok(v) -> Ok(v)
    Error(_) -> {
      case extract_quoted_field(json, "message") {
        Ok(v) -> Ok(v)
        Error(e) -> Error(e)
      }
    }
  }
}

fn extract_msg_text(json: String) -> Result(Option(String), String) {
  case extract_quoted_field(json, "text") {
    Ok(v) -> Ok(Some(v))
    Error(_) -> Ok(None)
  }
}

fn extract_sender_name(json: String) -> Result(String, String) {
  case extract_quoted_field(json, "sender") {
    Ok(v) -> Ok(v)
    Error(_) -> {
      case extract_quoted_field(json, "name") {
        Ok(v) -> Ok(v)
        Error(e) -> Error(e)
      }
    }
  }
}

fn extract_sender_type(json: String) -> Option(String) {
  case extract_quoted_field(json, "type") {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

fn extract_quoted_field(json: String, field: String) -> Result(String, String) {
  let pattern = "\"" <> field <> "\":\""
  case string.split_once(json, pattern) {
    Ok(#(_, rest)) -> {
      case string.split_once(rest, "\"") {
        Ok(#(value, _)) -> Ok(value)
        Error(_) -> Error("field not found: " <> field)
      }
    }
    Error(_) -> Error("field not found: " <> field)
  }
}

// ============================================================================
// Internal: Sending
// ============================================================================

fn do_send(_webhook_url: String, reply: port.ChannelReply) -> Result(Nil, port.ChannelError) {
  Error(port.NotConnected)
}
