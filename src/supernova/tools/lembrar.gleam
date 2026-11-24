//// lembrar: ask the memory whether the person and the agent already talked
//// about something, described in plain words (docs/prd/PRD-M-memoria.md).
////
//// Offered only when `conversation.recall` is on. The syscall gateway
//// passes the caller's principal; the agent only ever reads its own
//// person's conversations, as with `buscar_conversa`.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import supernova/agenda/runtime as agenda_runtime
import supernova/llm/provider
import supernova/memory/recall
import supernova/memory/runtime

pub const name = "lembrar"

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: name,
    description: "Ask your memory whether you and your person have already talked about something, described in plain words (e.g. 'the name of her mother's heart doctor', 'a trip to Lisbon'). It reads your whole conversation, beyond the recent messages you see, and returns how likely it is that you talked about it and the most likely excerpts, word for word, with date, time and who said it. Describe the subject, not the exact words: it understands paraphrases. For exact words, numbers or codes, use buscar_conversa. A low probability means you don't remember it: say so, don't say it was never said and don't fill the gap.",
    parameters: [
      provider.string_param(
        "assunto",
        "What to look for, in plain words.",
        True,
      ),
    ],
  )
}

/// Offered only when the memory is configured.
pub fn configured() -> Bool {
  runtime.get() != None
}

pub fn execute(principal: String, args_json: String) -> Result(String, String) {
  let decoder = {
    use assunto <- decode.field("assunto", decode.string)
    decode.success(assunto)
  }
  case runtime.get(), agenda_runtime.get() {
    None, _ -> Error("lembrar unavailable: memory not configured")
    _, None -> Error("lembrar unavailable: runtime not configured")
    Some(settings), Some(context) ->
      case json.parse(args_json, decoder) {
        Error(_) -> Error("Invalid arguments for lembrar: assunto is required")
        Ok(assunto) ->
          Ok(
            recall.recall(
              settings,
              context.data_dir,
              principal,
              context.offset_minutes,
              assunto,
            ).text,
          )
      }
  }
}
