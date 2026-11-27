//// Forget everything the owner told the agent, preserving who it became.
////
//// Some of it lives outside this process: the person's computer (at the
//// dispatcher), the inbox log, open sessions. A part that fails is not
//// forgotten yet, so the person is not told it is (PRD-K, K-I7): it is
//// written down in `<self>/esquecimento_pendente.json`, tried again by a
//// clock (`retry_all`), and the person hears when the last part is done.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import supernova/adapters/mcp/computer
import supernova/agenda/store as agenda_store
import supernova/channel/inbox
import supernova/core/agent_identity
import supernova/core/audit_log/types as audit_types
import supernova/core/introspection/lesson
import supernova/core/introspection/relationship
import supernova/core/introspection/self_state
import supernova/core/preferences
import supernova/core/session/history_store
import supernova/core/session/supervisor as session_supervisor
import supernova/self/aprovacoes
import supernova/self/audit
import supernova/self/cofre
import supernova/self/desk
import supernova/self/epoch
import supernova/self/incidents
import supernova/self/journal
import supernova/self/memory
import supernova/self/tasks

pub type Counts {
  Counts(
    journal: Int,
    experiences: Int,
    pressures: Int,
    lessons: Int,
    relationship: Int,
    sessions: Int,
    workspace_files: Int,
    agenda: Int,
    incidents: Int,
    /// What could not be forgotten yet and will be tried again.
    pendente: List(Part),
  )
}

/// The parts that live outside this process.
pub type Part {
  Computador
  Caixa
  Sessoes
}

pub fn forget(
  data_dir: String,
  principal: String,
  supervisor: Option(session_supervisor.SessionSupervisor),
) -> Result(Counts, String) {
  let self_dir = agent_identity.self_dir(data_dir, principal)
  // Bump first: turns and reflections already in flight check the epoch
  // before writing, so they stop as early as possible.
  use _ <- result.try(epoch.bump(data_dir, principal))
  // Tasks in the background stop, and nothing of them is delivered (I8).
  tasks.forget(principal)
  use _ <- result.try(delete_file(tasks.path(data_dir, principal)))
  // Pending requests, grants and permissions go with the person (PRD-K).
  use _ <- result.try(delete_file(aprovacoes.path(data_dir, principal)))
  // The person's passwords (PRD-K, K-08).
  use _ <- result.try(delete_file(cofre.path(data_dir, principal)))
  // The person's computer, with its files and browser sessions (PRD-K).
  let computer_left = forget_computer(principal)

  let #(journal_kept, journal_count) =
    journal.without_origin(data_dir, principal, principal)
  use _ <- result.try(journal.replace(data_dir, principal, journal_kept))

  let #(experience_kept, experience_count) =
    memory.without_origin_experiences(data_dir, principal, principal)
  use _ <- result.try(memory.replace_experiences(
    data_dir,
    principal,
    experience_kept,
  ))

  let #(pressure_kept, pressure_count) =
    memory.without_origin_pressures(data_dir, principal, principal)
  use _ <- result.try(memory.replace_pressures(
    data_dir,
    principal,
    pressure_kept,
  ))

  let lessons = lesson.load_recent_in(self_dir, 10_000)
  let lesson_count = list.length(lessons)
  use _ <- result.try(delete_file(lesson.lessons_path_in(self_dir)))
  // A legacy copy left behind by an upgrade would be migrated back on the
  // next prompt build if only the private copy were deleted.
  use _ <- result.try(
    delete_file(
      lesson.lessons_path(agent_identity.workspace_dir(data_dir, principal)),
    ),
  )

  let has_relationship = case
    file_exists(relationship.relationship_path_in(self_dir))
  {
    Ok(value) -> value
    Error(_) -> False
  }
  let relationship_count = case has_relationship {
    True -> 1
    False -> 0
  }
  // In the agent's process: no change of a turn lands between the erasing
  // and the rewriting, and what the process kept in memory is dropped.
  use _ <- result.try(
    desk.reset(data_dir, principal, fn() {
      use _ <- result.try(
        delete_file(relationship.relationship_path_in(self_dir)),
      )
      use _ <- result.try(
        delete_file(
          relationship.relationship_path(agent_identity.workspace_dir(
            data_dir,
            principal,
          )),
        ),
      )
      // How the person asked to be answered (/transcricao, /voz) goes too.
      use _ <- result.try(delete_file(preferences.path(data_dir, principal)))
      let state = self_state.from_dir(self_dir)
      self_state.save_in(
        self_dir,
        self_state.SelfState(
          ..state,
          concerns: [],
          open_questions: [],
          last_reflection: "Sem reflexão registrada.",
        ),
      )
    }),
  )

  let #(session_count, sessions_left) = clear_sessions(supervisor, principal)
  // Messages still waiting in the durable inbox are what the owner said too;
  // erasing them rewrites the inbox log without the text of finished turns.
  let inbox_left = forget_inbox(principal)
  // The conversations kept on disk are what the owner said, word for word.
  use _ <- result.try(clear_dir(history_store.dir(data_dir, principal)))
  // Files the agent wrote for the owner are also what came from the owner.
  use workspace_count <- result.try(
    clear_dir(agent_identity.workspace_dir(data_dir, principal)),
  )
  // What the owner asked to schedule is also what came from the owner.
  use agenda_count <- result.try(agenda_store.clear(data_dir, principal))
  // What went wrong in the owner's turns is about the owner's turns too.
  use incident_count <- result.try(incidents.clear(data_dir, principal))
  let counts =
    Counts(
      journal: journal_count,
      experiences: experience_count,
      pressures: pressure_count,
      lessons: lesson_count,
      relationship: relationship_count,
      sessions: session_count,
      workspace_files: workspace_count,
      agenda: agenda_count,
      incidents: incident_count,
      pendente: list.flatten([computer_left, inbox_left, sessions_left]),
    )
  use _ <- result.try(write_pending(data_dir, principal, counts.pendente))
  audit.record(
    principal,
    "forget",
    principal,
    audit_types.AuditSuccess,
    audit.counts([
      #("journal", journal_count),
      #("experiences", experience_count),
      #("pressures", pressure_count),
      #("lessons", lesson_count),
      #("relationship", relationship_count),
      #("sessions", session_count),
      #("workspace_files", workspace_count),
      #("agenda", agenda_count),
      #("incidents", incident_count),
      #("pending", list.length(counts.pendente)),
    ]),
  )
  Ok(counts)
}

fn forget_computer(principal: String) -> List(Part) {
  case computer.from_env() {
    None -> []
    Some(pc) ->
      case computer.forget_person(pc, principal) {
        Ok(Nil) -> []
        Error(_) -> [Computador]
      }
  }
}

fn forget_inbox(principal: String) -> List(Part) {
  case inbox.global() {
    None -> []
    Some(box) ->
      case inbox.forget(box, principal, now_ms()) {
        Ok(_) -> []
        Error(_) -> [Caixa]
      }
  }
}

/// What the person hears: "Esqueci." only when nothing is left.
pub fn receipt(counts: Counts) -> String {
  case counts.pendente {
    [] -> "Esqueci."
    parts ->
      "Apaguei o que estava aqui, mas ainda não consegui apagar "
      <> list.map(parts, part_words) |> join_words
      <> ". Vou tentar de novo sozinha e aviso quando terminar."
  }
}

/// What the person hears when the last part is done.
pub const done_message =
  "Pronto: terminei de apagar o que faltava. Esqueci tudo o que você me pediu."

fn part_words(part: Part) -> String {
  case part {
    Computador -> "o seu computador"
    Caixa -> "mensagens que esperavam na fila"
    Sessoes -> "conversas que estavam abertas"
  }
}

fn join_words(words: List(String)) -> String {
  case list.reverse(words) {
    [] -> ""
    [one] -> one
    [last, ..rest] ->
      list.reverse(rest)
      |> list.fold("", fn(acc, w) {
        case acc {
          "" -> w
          _ -> acc <> ", " <> w
        }
      })
      <> " e "
      <> last
  }
}

fn part_name(part: Part) -> String {
  case part {
    Computador -> "computador"
    Caixa -> "caixa"
    Sessoes -> "sessoes"
  }
}

fn part_from(name: String) -> Result(Part, Nil) {
  case name {
    "computador" -> Ok(Computador)
    "caixa" -> Ok(Caixa)
    "sessoes" -> Ok(Sessoes)
    _ -> Error(Nil)
  }
}

// ============================================================================
// What is left, and trying again
// ============================================================================

pub fn pending_path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/esquecimento_pendente.json"
}

fn write_pending(
  data_dir: String,
  principal: String,
  parts: List(Part),
) -> Result(Nil, String) {
  let target = pending_path(data_dir, principal)
  case parts {
    [] -> delete_file(target)
    _ -> {
      let text =
        json.object([
          #("pendente", json.array(parts, fn(p) { json.string(part_name(p)) })),
        ])
        |> json.to_string
      use _ <- result.try(
        ensure_dir(agent_identity.self_dir(data_dir, principal)),
      )
      use _ <- result.try(write_file(target <> ".tmp", text))
      rename(target <> ".tmp", target)
    }
  }
}

/// The parts still to forget; an unreadable file is everything, to be safe.
pub fn pending(data_dir: String, principal: String) -> List(Part) {
  let target = pending_path(data_dir, principal)
  case file_exists(target) {
    Ok(False) -> []
    _ ->
      case read_file(target) {
        Error(_) -> [Computador, Caixa, Sessoes]
        Ok(text) ->
          case
            json.parse(
              text,
              decode.at(["pendente"], decode.list(decode.string)),
            )
          {
            Ok(names) -> list.filter_map(names, part_from)
            Error(_) -> [Computador, Caixa, Sessoes]
          }
      }
  }
}

/// Try the person's pending parts again; what is still left.
pub fn retry(
  data_dir: String,
  principal: String,
  supervisor: Option(session_supervisor.SessionSupervisor),
) -> Result(List(Part), String) {
  let left =
    pending(data_dir, principal)
    |> list.flat_map(fn(part) {
      case part {
        Computador -> forget_computer(principal)
        Caixa -> forget_inbox(principal)
        Sessoes ->
          case supervisor {
            None -> [Sessoes]
            Some(_) -> clear_sessions(supervisor, principal).1
          }
      }
    })
  use _ <- result.try(write_pending(data_dir, principal, left))
  case left {
    [] ->
      audit.record(
        principal,
        "forget_completed",
        principal,
        audit_types.AuditSuccess,
        audit.counts([]),
      )
    _ -> Nil
  }
  Ok(left)
}

/// Everyone with something left: try again; `done` hears who finished.
pub fn retry_all(
  data_dir: String,
  supervisor: Option(session_supervisor.SessionSupervisor),
  done: fn(String) -> Nil,
) -> Nil {
  list_agent_dirs(data_dir <> "/agents")
  |> list.map(agent_identity.decode_principal)
  |> list.filter(fn(principal) {
    file_exists(pending_path(data_dir, principal)) == Ok(True)
  })
  |> list.each(fn(principal) {
    case retry(data_dir, principal, supervisor) {
      Ok([]) -> done(principal)
      _ -> Nil
    }
  })
}

/// Stop the person's sessions: how many stopped, and what is left.
fn clear_sessions(
  supervisor: Option(session_supervisor.SessionSupervisor),
  principal: String,
) -> #(Int, List(Part)) {
  case supervisor {
    None -> #(0, [])
    Some(supervisor) -> {
      let sessions =
        session_supervisor.list_sessions(supervisor)
        |> list.filter(fn(session_id) {
          agent_identity.principal_from_session_id(session_id) == principal
        })
      let stopped =
        list.filter(sessions, fn(session_id) {
          session_supervisor.stop_session(supervisor, session_id)
          |> result.is_ok
        })
        |> list.length
      case stopped == list.length(sessions) {
        True -> #(stopped, [])
        False -> #(stopped, [Sessoes])
      }
    }
  }
}

@external(erlang, "supernova_self_ffi", "clear_dir")
fn clear_dir(path: String) -> Result(Int, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn delete_file(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_self_ffi", "rename_file")
fn rename(from: String, to: String) -> Result(Nil, String)

@external(erlang, "supernova_self_ffi", "list_agent_dirs")
fn list_agent_dirs(path: String) -> List(String)
