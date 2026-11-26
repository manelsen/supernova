import e2e/e2e_support as support
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/agenda/store as agenda_store
import supernova/config
import supernova/core/agent_identity
import supernova/core/audit_log/actor as audit_actor
import supernova/core/closed_group/global as closed_group_global
import supernova/core/identity/aliases
import supernova/core/introspection/lesson
import supernova/core/introspection/relationship
import supernova/core/introspection/self_state
import supernova/core/session/history_store
import supernova/core/session/server as session_server
import supernova/core/session/supervisor as session_supervisor
import supernova/memory/recall
import supernova/self/core as self_core
import supernova/self/forget
import supernova/self/incidents
import supernova/self/journal
import supernova/self/memory
import supernova/self/sampler

fn cfg() -> config.Config {
  config.Config(
    ..support.channel_config(),
    access: config.AccessConfig(
      ..support.access_config([], ["sim:alice"]),
      allowed_chats: ["sim:group-1"],
    ),
  )
}

fn seed(root: String) -> Nil {
  let assert Ok(_) =
    self_core.save_birth(
      root,
      "sim:alice",
      sampler.Sampled(traits: ["curiosa"], seed: 1, attempts: 1),
      1,
      "Núcleo que fica.",
      1000,
    )
  let assert Ok(_) =
    memory.append_addendum(root, "sim:alice", "Adendo que fica.")
  let self_dir = root <> "/agents/sim_alice/self"
  let assert Ok(_) =
    journal.append(
      root,
      "sim:alice",
      journal.Entry(
        at: 2000,
        origin: "sim:alice",
        session: "sim:group-1:alice",
        user: "segredo",
        agent: "guardei",
      ),
      10,
    )
  let assert Ok(_) =
    memory.append_experiences(root, "sim:alice", [
      memory.Experience(at: 2000, origin: "sim:alice", text: "segredo"),
    ])
  let assert Ok(_) =
    memory.append_pressures(root, "sim:alice", [
      memory.Pressure(
        at: 2000,
        origin: "sim:alice",
        from: "curiosa",
        to: "cauta",
        strength: 1.0,
        reason: "segredo",
      ),
    ])
  let assert Ok(_) =
    lesson.append_in(
      self_dir,
      lesson.make_success_lesson("s1", "segredo", "teste"),
    )
  let assert Ok(_) =
    relationship.save_in(
      self_dir,
      relationship.RelationshipState(
        ..relationship.load_in(self_dir, "alice"),
        user_id: "alice",
      ),
    )
  let assert Ok(_) =
    self_state.save_in(
      self_dir,
      self_state.SelfState(
        ..self_state.default(),
        concerns: ["segredo"],
        open_questions: ["segredo?"],
        last_reflection: "segredo",
      ),
    )
  let workspace = agent_identity.workspace_dir(root, "sim:alice")
  let assert Ok(_) =
    lesson.append(
      workspace,
      lesson.make_success_lesson("legado", "licao legada", "teste"),
    )
  let assert Ok(_) =
    relationship.save(workspace, relationship.load(workspace, "alice"))
  let assert Ok(_) =
    agenda_store.add(
      root,
      "sim:alice",
      "0 5 * * *",
      "radar",
      1_795_273_200_000,
      -180,
    )
  let assert Ok(_) =
    incidents.record(root, "sim:alice", 1_795_273_200_000, "falha antiga")
  Nil
}

pub fn forget_removes_owner_content_and_keeps_identity_test() {
  support.with_runtime_root(cfg(), fn(root) {
    seed(root)
    let assert Ok(forget.Counts(
      journal: 1,
      experiences: 1,
      pressures: 1,
      lessons: 1,
      relationship: 1,
      sessions: 0,
      workspace_files: 0,
      agenda: 1,
      incidents: 1,
      pendente: [],
    )) = forget.forget(root, "sim:alice", None)
    incidents.count(root, "sim:alice") |> should.equal(0)
    agenda_store.list(root, "sim:alice") |> should.equal([])
    let self_dir = root <> "/agents/sim_alice/self"
    journal.load(root, "sim:alice") |> should.equal([])
    memory.experiences(root, "sim:alice") |> should.equal([])
    memory.pressures(root, "sim:alice") |> should.equal([])
    memory.addenda(root, "sim:alice") |> should.equal("\n\nAdendo que fica.\n")
    file_exists(
      agent_identity.workspace_dir(root, "sim:alice")
      <> "/.supernova/LESSONS.json",
    )
    |> should.equal(Ok(False))
    file_exists(
      agent_identity.workspace_dir(root, "sim:alice")
      <> "/.supernova/RELATIONSHIP.json",
    )
    |> should.equal(Ok(False))
    let assert Some(core) = self_core.load(root, "sim:alice")
    core.traits |> should.equal(["curiosa"])
    let state = self_state.from_dir(self_dir)
    state.concerns |> should.equal([])
    state.open_questions |> should.equal([])
    state.last_reflection |> should.equal("Sem reflexão registrada.")
    case closed_group_global.get_audit() {
      Some(audit) ->
        audit_actor.get_all(audit)
        |> list.any(fn(entry) {
          entry.operation == "forget"
          && entry.agent_id == "sim:alice"
          && entry.details
          == "journal=1,experiences=1,pressures=1,lessons=1,relationship=1,sessions=0,workspace_files=0,agenda=1,incidents=1,pending=0"
        })
        |> should.be_true()
      None -> should.fail()
    }
  })
}

pub fn forget_stops_sessions_of_the_owner_test() {
  support.with_runtime_root(cfg(), fn(root) {
    seed(root)
    let assert Ok(sup) = session_supervisor.start()
    let assert Ok(_) =
      session_supervisor.start_session(sup, "sim:group-1:alice")
    let assert Ok(_) = session_supervisor.start_session(sup, "sim:group-1:bob")
    let assert Ok(forget.Counts(sessions: 1, ..)) =
      forget.forget(root, "sim:alice", Some(sup))
    session_supervisor.list_sessions(sup)
    |> list.contains("sim:group-1:alice")
    |> should.equal(False)
    session_supervisor.list_sessions(sup)
    |> list.contains("sim:group-1:bob")
    |> should.equal(True)
    session_supervisor.stop(sup)
  })
}

pub fn forget_deletes_the_owners_conversations_on_disk_test() {
  support.with_runtime_root(cfg(), fn(root) {
    seed(root)
    let store = history_store.HistoryStore(data_dir: root, limit: 40)
    let assert Ok(sup) = session_supervisor.start_with_history(store)
    let said = [
      session_server.ChatMessage(role: "user", content: "oi"),
      session_server.ChatMessage(role: "assistant", content: "olá"),
    ]
    let assert Ok(alice) =
      session_supervisor.start_session(sup, "sim:group-1:alice")
    let assert Ok(Nil) = session_server.append_messages(alice, said)
    let assert Ok(bob) =
      session_supervisor.start_session(sup, "sim:group-1:bob")
    let assert Ok(Nil) = session_server.append_messages(bob, said)

    let assert Ok(_) = forget.forget(root, "sim:alice", Some(sup))

    history_store.load(store, "sim:group-1:alice") |> should.equal([])
    let bob_kept = history_store.load(store, "sim:group-1:bob")
    list.length(bob_kept) |> should.equal(2)
    let assert Ok(alice_again) =
      session_supervisor.start_session(sup, "sim:group-1:alice")
    session_server.get_history(alice_again) |> should.equal([])
    session_supervisor.stop(sup)
  })
}

/// PRD-I, I-03 and D4: one person on two channels has one folder of
/// conversations; /esquecer said on either wipes both, and the link stays.
pub fn forget_reaches_every_channel_of_the_person_test() {
  support.with_runtime_root(cfg(), fn(root) {
    seed(root)
    let assert Ok(Nil) =
      aliases.link(root, "discord:alice-i03", "sim:alice", "discord", 1)
    let store = history_store.HistoryStore(data_dir: root, limit: 40)
    let assert Ok(sup) = session_supervisor.start_with_history(store)
    let said = [session_server.ChatMessage(role: "user", content: "oi")]
    let assert Ok(on_sim) =
      session_supervisor.start_session(sup, "sim:group-1:alice")
    let assert Ok(Nil) = session_server.append_messages(on_sim, said)
    let assert Ok(on_discord) =
      session_supervisor.start_session(sup, "discord:dm:alice-i03:alice-i03")
    let assert Ok(Nil) = session_server.append_messages(on_discord, said)

    let assert Ok(forget.Counts(sessions: 2, ..)) =
      forget.forget(root, "sim:alice", Some(sup))

    history_store.load(store, "sim:group-1:alice") |> should.equal([])
    history_store.load(store, "discord:dm:alice-i03:alice-i03")
    |> should.equal([])
    aliases.resolve("discord:alice-i03") |> should.equal("sim:alice")
    let assert Ok(Nil) = aliases.unlink(root, "discord:alice-i03")
    session_supervisor.stop(sup)
  })
}

pub fn forgetting_alice_does_not_touch_bob_test() {
  support.with_runtime_root(cfg(), fn(root) {
    seed(root)
    let assert Ok(_) =
      self_core.save_birth(
        root,
        "sim:bob",
        sampler.Sampled(traits: ["curiosa"], seed: 2, attempts: 1),
        1,
        "Núcleo de B.",
        1000,
      )
    let assert Ok(_) =
      journal.append(
        root,
        "sim:bob",
        journal.Entry(
          at: 2000,
          origin: "sim:bob",
          session: "sim:group-1:bob",
          user: "segredo de B",
          agent: "guardei",
        ),
        10,
      )
    let assert Ok(_) =
      memory.append_experiences(root, "sim:bob", [
        memory.Experience(at: 2000, origin: "sim:bob", text: "segredo de B"),
      ])
    let assert Ok(_) =
      memory.append_pressures(root, "sim:bob", [
        memory.Pressure(
          at: 2000,
          origin: "sim:bob",
          from: "curiosa",
          to: "cauta",
          strength: 1.0,
          reason: "segredo de B",
        ),
      ])
    let assert Ok(_) = forget.forget(root, "sim:alice", None)
    journal.load(root, "sim:bob") |> list.length |> should.equal(1)
    memory.experiences(root, "sim:bob") |> list.length |> should.equal(1)
    memory.pressures(root, "sim:bob") |> list.length |> should.equal(1)
    let assert Some(core) = self_core.load(root, "sim:bob")
    core.traits |> should.equal(["curiosa"])
  })
}

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

/// The memory index lives with the conversations: /esquecer takes it too
/// (PRD-M, I4).
pub fn forget_removes_the_memory_index_test() {
  support.with_runtime_root(cfg(), fn(root) {
    seed(root)
    let index = recall.index_path(root, "sim:alice")
    let assert Ok(_) = ensure_dir(history_store.dir(root, "sim:alice"))
    let assert Ok(_) = write_file(index, "{\"h\":\"abc\",\"v\":[0.1,0.2]}\n")
    file_exists(index) |> should.equal(Ok(True))
    let assert Ok(_) = forget.forget(root, "sim:alice", None)
    file_exists(index) |> should.equal(Ok(False))
  })
}

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)
