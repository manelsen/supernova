//// Forget everything the owner told the agent, preserving who it became.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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
import supernova/self/audit
import supernova/self/desk
import supernova/self/epoch
import supernova/self/incidents
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
    workspace_files: Int,
    agenda: Int,
    incidents: Int,
  )
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

  let session_count = clear_sessions(supervisor, principal)
  // Messages still waiting in the durable inbox are what the owner said too;
  // erasing them rewrites the inbox log without the text of finished turns.
  case inbox.global() {
    Some(box) -> {
      let _ = inbox.forget(box, principal, now_ms())
      Nil
    }
    None -> Nil
  }
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
      #("workspace_files", workspace_count),
      #("agenda", agenda_count),
      #("incidents", incident_count),
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

@external(erlang, "supernova_self_ffi", "clear_dir")
fn clear_dir(path: String) -> Result(Int, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn delete_file(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int
