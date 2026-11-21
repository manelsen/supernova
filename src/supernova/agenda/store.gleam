//// A person's agenda: what they asked their agent to do at a given time.
////
//// Kept in the agent's private `self` directory, out of reach of the
//// file_system tool. Every read-modify-write runs under a per-person lock,
//// so the tool and the clock never overwrite each other.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import supernova/agenda/schedule
import supernova/core/agent_identity

pub type Entry {
  Entry(
    id: Int,
    spec: String,
    request: String,
    created_at: Int,
    next_run_at: Int,
  )
}

type Agenda {
  Agenda(next_id: Int, entries: List(Entry))
}

/// At most this many entries per person.
pub const max_entries = 5

/// The longest request an entry may carry, in characters.
pub const max_request_length = 2000

/// How late an entry may still run after its time, for instance after a
/// restart. Later than this, the occurrence is skipped.
pub const grace_ms = 3_600_000

pub fn path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/agenda.json"
}

/// The person's entries, soonest first.
pub fn list(data_dir: String, principal: String) -> List(Entry) {
  load(data_dir, principal).entries
  |> list.sort(fn(a, b) { int.compare(a.next_run_at, b.next_run_at) })
}

/// Add an entry. `when` is a cron expression or a local "YYYY-MM-DD HH:MM".
pub fn add(
  data_dir: String,
  principal: String,
  when: String,
  request: String,
  now: Int,
  offset: Int,
) -> Result(Entry, String) {
  let request = string.trim(request)
  use parsed <- result.try(schedule.parse(when, now, offset))
  use next <- result.try(
    schedule.next_after(parsed, now, offset)
    |> option.to_result("esse horário nunca acontece"),
  )
  use _ <- result.try(case request {
    "" -> Error("o pedido está vazio")
    _ ->
      case string.length(request) > max_request_length {
        True ->
          Error(
            "o pedido passa de "
            <> int.to_string(max_request_length)
            <> " caracteres",
          )
        False -> Ok(Nil)
      }
  })
  update(data_dir, principal, fn(agenda) {
    case list.length(agenda.entries) >= max_entries {
      True ->
        Error(
          "a agenda já tem "
          <> int.to_string(max_entries)
          <> " tarefas; remova uma antes",
        )
      False -> {
        let entry =
          Entry(
            id: agenda.next_id,
            spec: schedule.spec(parsed),
            request: request,
            created_at: now,
            next_run_at: next,
          )
        Ok(#(
          Agenda(
            next_id: agenda.next_id + 1,
            entries: list.append(agenda.entries, [entry]),
          ),
          entry,
        ))
      }
    }
  })
}

/// Remove one entry by id.
pub fn remove(
  data_dir: String,
  principal: String,
  id: Int,
) -> Result(Entry, String) {
  update(data_dir, principal, fn(agenda) {
    case list.partition(agenda.entries, fn(entry) { entry.id == id }) {
      #([found], rest) -> Ok(#(Agenda(..agenda, entries: rest), found))
      _ -> Error("não há tarefa " <> int.to_string(id) <> " na agenda")
    }
  })
}

/// Remove every entry and the file. Returns how many entries there were.
pub fn clear(data_dir: String, principal: String) -> Result(Int, String) {
  with_lock(lock_key(principal), fn() {
    let count = list.length(load(data_dir, principal).entries)
    delete_file(path(data_dir, principal))
    |> result.replace(count)
  })
}

/// Entries due at `now`. Each one is advanced to its next run, or removed
/// when it runs only once, and saved before it is returned: a crash while
/// running it never makes it run twice. An occurrence later than the grace
/// period is skipped, not run late.
pub fn take_due(
  data_dir: String,
  principal: String,
  now: Int,
  offset: Int,
) -> List(Entry) {
  let taken =
    update(data_dir, principal, fn(agenda) {
      let #(due, kept) =
        list.fold(agenda.entries, #([], []), fn(acc, entry) {
          let #(due, kept) = acc
          case entry.next_run_at <= now {
            False -> #(due, [entry, ..kept])
            True -> {
              let due = case now - entry.next_run_at <= grace_ms {
                True -> [entry, ..due]
                False -> due
              }
              case advance(entry, now, offset) {
                Some(next) -> #(due, [next, ..kept])
                None -> #(due, kept)
              }
            }
          }
        })
      case list.any(agenda.entries, fn(entry) { entry.next_run_at <= now }) {
        False -> Error("nothing due")
        True ->
          Ok(#(Agenda(..agenda, entries: list.reverse(kept)), list.reverse(due)))
      }
    })
  result.unwrap(taken, [])
}

/// People who have an agenda file.
pub fn owners(data_dir: String) -> List(String) {
  list_agent_dirs(data_dir <> "/agents")
  |> list.map(agent_identity.decode_principal)
  |> list.filter(fn(principal) {
    file_exists(path(data_dir, principal)) == Ok(True)
  })
}

fn advance(entry: Entry, now: Int, offset: Int) -> option.Option(Entry) {
  case schedule.parse(entry.spec, entry.created_at, offset) {
    Error(_) -> None
    Ok(parsed) ->
      schedule.next_after(parsed, now, offset)
      |> option.map(fn(next) { Entry(..entry, next_run_at: next) })
  }
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

fn update(
  data_dir: String,
  principal: String,
  change: fn(Agenda) -> Result(#(Agenda, a), String),
) -> Result(a, String) {
  with_lock(lock_key(principal), fn() {
    use #(agenda, value) <- result.try(change(load(data_dir, principal)))
    use _ <- result.try(save(data_dir, principal, agenda))
    Ok(value)
  })
}

fn lock_key(principal: String) -> String {
  "agenda:" <> principal
}

fn load(data_dir: String, principal: String) -> Agenda {
  case read_file(path(data_dir, principal)) {
    Error(_) -> Agenda(next_id: 1, entries: [])
    Ok(text) ->
      json.parse(text, agenda_decoder())
      |> result.unwrap(Agenda(next_id: 1, entries: []))
  }
}

fn save(
  data_dir: String,
  principal: String,
  agenda: Agenda,
) -> Result(Nil, String) {
  let file = path(data_dir, principal)
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  use _ <- result.try(write_file(file <> ".tmp", encode(agenda)))
  rename(file <> ".tmp", file)
}

fn encode(agenda: Agenda) -> String {
  json.object([
    #("next_id", json.int(agenda.next_id)),
    #(
      "entries",
      json.array(agenda.entries, fn(entry) {
        json.object([
          #("id", json.int(entry.id)),
          #("spec", json.string(entry.spec)),
          #("request", json.string(entry.request)),
          #("created_at", json.int(entry.created_at)),
          #("next_run_at", json.int(entry.next_run_at)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn agenda_decoder() -> decode.Decoder(Agenda) {
  let entry = {
    use id <- decode.field("id", decode.int)
    use spec <- decode.field("spec", decode.string)
    use request <- decode.field("request", decode.string)
    use created_at <- decode.field("created_at", decode.int)
    use next_run_at <- decode.field("next_run_at", decode.int)
    decode.success(Entry(id:, spec:, request:, created_at:, next_run_at:))
  }
  use next_id <- decode.field("next_id", decode.int)
  use entries <- decode.field("entries", decode.list(entry))
  decode.success(Agenda(next_id:, entries:))
}

@external(erlang, "supernova_self_ffi", "with_lock")
fn with_lock(key: String, body: fn() -> a) -> a

@external(erlang, "supernova_self_ffi", "list_agent_dirs")
fn list_agent_dirs(path: String) -> List(String)

@external(erlang, "supernova_self_ffi", "rename_file")
fn rename(from: String, to: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn delete_file(path: String) -> Result(Nil, String)
