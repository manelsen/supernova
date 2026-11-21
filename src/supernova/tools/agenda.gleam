//// The agenda tool: lets an agent schedule something its person asked for,
//// at a time or on a recurring cron schedule, and list or remove entries.
////
//// The syscall gateway passes the caller's principal; an agent only ever
//// sees and changes its own person's agenda.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/agenda/runtime
import supernova/agenda/schedule
import supernova/agenda/store
import supernova/llm/provider

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "agenda",
    description: "Schedule something your person asked you to do later, once or on a recurring basis; at that time you will be woken with the request and your reply goes to your person. Also list or remove what is scheduled. Times are local (America/Sao_Paulo). Schedule only what your person asked for.",
    parameters: [
      provider.string_param("action", "Action: add, list, remove", True),
      provider.string_param(
        "when",
        "For add: a local date and time \"YYYY-MM-DD HH:MM\" for once, or a 5-field cron expression (minute hour day month weekday) for recurring, e.g. \"0 5 * * *\" for every day at 05:00. At most once an hour.",
        False,
      ),
      provider.string_param(
        "request",
        "For add: what to do at that time, written as instructions to yourself.",
        False,
      ),
      provider.integer_param("id", "For remove: the entry id.", False),
    ],
  )
}

/// Run a tool call for `principal` with the runtime's data dir and clock.
pub fn execute(principal: String, args_json: String) -> Result(String, String) {
  case runtime.get() {
    None -> Error("agenda unavailable: runtime not configured")
    Some(context) ->
      execute_for(
        context.data_dir,
        principal,
        context.clock(),
        context.offset_minutes,
        args_json,
      )
  }
}

/// Channels where the agenda can reach the person in a private chat.
pub fn deliverable(principal: String) -> Bool {
  case string.split(principal, ":") {
    ["telegram", ..] | ["sim", ..] -> True
    _ -> False
  }
}

type Args {
  Args(action: String, when: String, request: String, id: Option(Int))
}

pub fn execute_for(
  data_dir: String,
  principal: String,
  now: Int,
  offset: Int,
  args_json: String,
) -> Result(String, String) {
  case json.parse(args_json, args_decoder()) {
    Error(_) -> Error("Invalid arguments for agenda")
    Ok(args) ->
      case string.lowercase(string.trim(args.action)) {
        "add" -> add(data_dir, principal, now, offset, args)
        "list" -> Ok(listing(data_dir, principal, offset))
        "remove" ->
          case args.id {
            None -> Error("remove needs the entry id")
            Some(id) ->
              case store.remove(data_dir, principal, id) {
                Ok(entry) ->
                  Ok("Removida a tarefa " <> int.to_string(entry.id) <> ".")
                Error(reason) -> Error(reason)
              }
          }
        _ -> Error("agenda action must be add, list, or remove")
      }
  }
}

fn add(
  data_dir: String,
  principal: String,
  now: Int,
  offset: Int,
  args: Args,
) -> Result(String, String) {
  case deliverable(principal) {
    False -> Error("a agenda ainda só funciona no Telegram")
    True ->
      case string.trim(args.when), string.trim(args.request) {
        "", _ -> Error("add needs when")
        _, "" -> Error("add needs request")
        when, request ->
          case store.add(data_dir, principal, when, request, now, offset) {
            Error(reason) -> Error(reason)
            Ok(entry) ->
              Ok(
                "Agendada a tarefa "
                <> int.to_string(entry.id)
                <> " ("
                <> entry.spec
                <> "). Próxima vez: "
                <> schedule.format_local(entry.next_run_at, offset)
                <> ".",
              )
          }
      }
  }
}

fn listing(data_dir: String, principal: String, offset: Int) -> String {
  case store.list(data_dir, principal) {
    [] -> "(agenda vazia)"
    entries ->
      entries
      |> list.map(fn(entry) { describe(entry, offset) })
      |> string.join("\n")
  }
}

/// One line per entry, shared with the /agenda command.
pub fn describe(entry: store.Entry, offset: Int) -> String {
  int.to_string(entry.id)
  <> ". "
  <> entry.spec
  <> " — próxima: "
  <> schedule.format_local(entry.next_run_at, offset)
  <> " — "
  <> entry.request
}

fn args_decoder() -> decode.Decoder(Args) {
  use action <- decode.field("action", decode.string)
  use when <- decode.optional_field("when", "", decode.string)
  use request <- decode.optional_field("request", "", decode.string)
  use id <- decode.optional_field(
    "id",
    None,
    decode.one_of(decode.int |> decode.map(Some), [
      decode.string
      |> decode.then(fn(text) {
        case int.parse(string.trim(text)) {
          Ok(value) -> decode.success(Some(value))
          Error(_) -> decode.failure(None, "id")
        }
      }),
    ]),
  )
  decode.success(Args(action:, when:, request:, id:))
}
