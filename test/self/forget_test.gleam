import e2e/e2e_support as support
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/config
import supernova/core/audit_log/actor as audit_actor
import supernova/core/closed_group/global as closed_group_global
import supernova/core/introspection/lesson
import supernova/core/introspection/relationship
import supernova/core/introspection/self_state
import supernova/self/core as self_core
import supernova/self/forget
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
    )) = forget.forget(root, "sim:alice", None)
    let self_dir = root <> "/agents/sim_alice/self"
    journal.load(root, "sim:alice") |> should.equal([])
    memory.experiences(root, "sim:alice") |> should.equal([])
    memory.pressures(root, "sim:alice") |> should.equal([])
    memory.addenda(root, "sim:alice") |> should.equal("\n\nAdendo que fica.\n")
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
          == "journal=1,experiences=1,pressures=1,lessons=1,relationship=1,sessions=0"
        })
        |> should.be_true()
      None -> should.fail()
    }
  })
}
