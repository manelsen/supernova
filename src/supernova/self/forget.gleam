//// Forget everything the owner told the agent, preserving who it became.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import supernova/core/agent_identity
import supernova/core/audit_log/types as audit_types
import supernova/core/introspection/lesson
import supernova/core/introspection/relationship
import supernova/core/introspection/self_state
import supernova/core/session/supervisor as session_supervisor
import supernova/self/audit
import supernova/self/journal
import supernova/self/memory

pub type Counts {
  Counts(
    journal: Int,
    experiences: Int,
    pressures: Int,
    lessons: Int,
    relationship: Int,
    sessions: Int,
  )
}

pub fn forget(
  data_dir: String,
  principal: String,
  supervisor: Option(session_supervisor.SessionSupervisor),
) -> Result(Counts, String) {
  let self_dir = agent_identity.self_dir(data_dir, principal)

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
  let _ = delete_file(lesson.lessons_path_in(self_dir))

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
  let _ = delete_file(relationship.relationship_path_in(self_dir))

  let state = self_state.from_dir(self_dir)
  let _ =
    self_state.save_in(
      self_dir,
      self_state.SelfState(
        ..state,
        concerns: [],
        open_questions: [],
        last_reflection: "Sem reflexão registrada.",
      ),
    )

  let session_count = clear_sessions(supervisor, principal)
  let counts =
    Counts(
      journal: journal_count,
      experiences: experience_count,
      pressures: pressure_count,
      lessons: lesson_count,
      relationship: relationship_count,
      sessions: session_count,
    )
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
    ]),
  )
  Ok(counts)
}

fn clear_sessions(
  supervisor: Option(session_supervisor.SessionSupervisor),
  principal: String,
) -> Int {
  case supervisor {
    None -> 0
    Some(supervisor) -> {
      let sessions =
        session_supervisor.list_sessions(supervisor)
        |> list.filter(fn(session_id) {
          agent_identity.principal_from_session_id(session_id) == principal
        })
      list.each(sessions, fn(session_id) {
        let _ = session_supervisor.stop_session(supervisor, session_id)
        Nil
      })
      list.length(sessions)
    }
  }
}

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn delete_file(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)
