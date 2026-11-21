//// Regression tests for the maintainer review of B2 phase C.

import e2e/e2e_support as support
import envoy
import exception
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/config
import supernova/core/agent_identity
import supernova/core/audit_log/types as audit_types
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/pure as closed_pure
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/resource_ledger/types.{LLMUsage}
import supernova/llm/provider
import supernova/self/core as self_core
import supernova/self/drift
import supernova/self/epoch
import supernova/self/forget
import supernova/self/journal
import supernova/self/memory
import supernova/self/reflection
import supernova/self/sampler
import supernova/self/template

fn mock_provider() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

fn cfg() -> config.Config {
  config.Config(
    ..support.channel_config(),
    access: config.AccessConfig(
      ..support.access_config([], ["sim:alice", "sim:bob"]),
      allowed_chats: ["sim:group-1"],
    ),
    reflection: config.ReflectionConfig(
      every_turns: 1,
      every_hours: 24,
      model: None,
      journal_limit: 500,
    ),
    drift: config.DriftConfig(
      half_life_days: 30.0,
      threshold: 3.0,
      min_interval_days: 90,
      min_pressure_days: 4,
    ),
  )
}

fn with_constellation(body: fn() -> a) -> a {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  body()
}

fn born(root: String, principal: String, now: Int) -> Nil {
  let assert Ok(_) =
    self_core.save_birth(
      root,
      principal,
      sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 1, attempts: 1),
      1,
      "Núcleo provisório.",
      now - 1000,
    )
  Nil
}

fn turn(root: String, principal: String, at: Int, user: String) -> Nil {
  let assert Ok(_) =
    journal.append(
      root,
      principal,
      journal.Entry(
        at: at,
        origin: principal,
        session: "sim:group-1:alice",
        user: user,
        agent: "olá",
      ),
      500,
    )
  Nil
}

fn usage_count(principal: String) -> Int {
  case closed_group_global.get_ledger() {
    Some(ledger) ->
      ledger_actor.get_all_usage(ledger)
      |> list.filter(fn(event) {
        case event {
          LLMUsage(principal_id: p, ..) -> p == principal
          _ -> False
        }
      })
      |> list.length
    None -> -1
  }
}

const at = 1_700_000_000_000

// 1. A model that wraps the JSON in a code fence still reflects.
pub fn fenced_reflection_json_is_accepted_test() {
  use <- with_constellation()
  support.with_runtime_root(cfg(), fn(root) {
    born(root, "sim:alice", at)
    turn(root, "sim:alice", at - 10, "[mock-fenced-reflection]")
    let assert Ok(reflection.Reflected(experiences: 1, ..)) =
      reflection.reflect(root, "sim:alice", mock_provider(), at)
  })
}

// 2. A failed reflection is not retried on every turn.
pub fn failed_reflection_backs_off_test() {
  use <- with_constellation()
  support.with_runtime_root(cfg(), fn(root) {
    born(root, "sim:alice", at)
    turn(root, "sim:alice", at - 10, "[mock-invalid-reflection]")
    let assert Error(_) =
      reflection.reflect(root, "sim:alice", mock_provider(), at)
    let charged = usage_count("sim:alice")
    // A minute later, with a new turn, nothing is attempted or charged.
    turn(root, "sim:alice", at + 60_000, "mais uma")
    let assert Ok(reflection.Skipped) =
      reflection.reflect(root, "sim:alice", mock_provider(), at + 60_000)
    usage_count("sim:alice") |> should.equal(charged)
    // After the first backoff window (1 h) it tries again.
    let assert Error(_) =
      reflection.reflect(root, "sim:alice", mock_provider(), at + 3_600_001)
    // The second failure doubles the wait.
    let assert Ok(reflection.Skipped) =
      reflection.reflect(
        root,
        "sim:alice",
        mock_provider(),
        at + 3_600_001 + 3_600_001,
      )
  })
}

// 3. One reflection reads a bounded batch of the oldest entries.
pub fn reflection_reads_a_bounded_batch_test() {
  use <- with_constellation()
  support.with_runtime_root(cfg(), fn(root) {
    born(root, "sim:alice", at)
    int.range(from: 0, to: 100, with: Nil, run: fn(_, i) {
      turn(root, "sim:alice", at - 1000 + i, "turno " <> int.to_string(i))
    })
    let assert Ok(reflection.Reflected(..)) =
      reflection.reflect(root, "sim:alice", mock_provider(), at)
    let remaining = journal.load(root, "sim:alice")
    list.length(remaining) |> should.equal(100 - reflection.max_batch)
    let assert [first, ..] = remaining
    first.user |> should.equal("turno " <> int.to_string(reflection.max_batch))
  })
}

// 4. A live holder blocks a second reflection; a dead one does not.
pub fn reflection_lock_dies_with_its_holder_test() {
  use <- with_constellation()
  support.with_runtime_root(cfg(), fn(root) {
    born(root, "sim:alice", at)
    turn(root, "sim:alice", at - 10, "oi")
    let held = process.new_subject()
    let release = process.new_subject()
    let holder =
      process.spawn_unlinked(fn() {
        process.send(held, reflection.acquire_lock(root, "sim:alice"))
        process.receive_forever(release)
      })
    let assert Ok(True) = process.receive(held, 1000)
    let assert Ok(reflection.Skipped) =
      reflection.reflect(root, "sim:alice", mock_provider(), at)
    process.kill(holder)
    wait_until_dead(holder, 50)
    let assert Ok(reflection.Reflected(..)) =
      reflection.reflect(root, "sim:alice", mock_provider(), at)
  })
}

fn wait_until_dead(pid: process.Pid, tries: Int) -> Nil {
  case process.is_alive(pid), tries {
    False, _ -> Nil
    True, 0 -> should.fail()
    True, _ -> {
      let _ = process.new_subject() |> process.receive(10)
      wait_until_dead(pid, tries - 1)
    }
  }
}

// 5. A reflection that started before /esquecer does not commit.
pub fn reflection_started_before_forget_is_discarded_test() {
  use <- with_constellation()
  support.with_runtime_root(cfg(), fn(root) {
    born(root, "sim:alice", at)
    turn(root, "sim:alice", at - 10, "segredo")
    let started = epoch.current(root, "sim:alice")
    let assert Ok(_) = forget.forget(root, "sim:alice", None)
    // The owner talks again after forgetting; that turn must survive.
    turn(root, "sim:alice", at, "depois")
    let assert Error("forgotten during reflection") =
      reflection.reflect_from_epoch(
        root,
        "sim:alice",
        mock_provider(),
        at,
        started,
      )
    memory.experiences(root, "sim:alice") |> should.equal([])
    journal.load(root, "sim:alice")
    |> list.map(fn(entry) { entry.user })
    |> should.equal(["depois"])
  })
}

// 6. /esquecer also clears the owner's workspace, and only theirs.
pub fn forget_clears_the_owner_workspace_test() {
  support.with_runtime_root(cfg(), fn(root) {
    born(root, "sim:alice", at)
    born(root, "sim:bob", at)
    let alice_ws = agent_identity.workspace_dir(root, "sim:alice")
    let bob_ws = agent_identity.workspace_dir(root, "sim:bob")
    let assert Ok(_) = ensure_dir(alice_ws <> "/pasta")
    let assert Ok(_) = ensure_dir(bob_ws)
    let assert Ok(_) = write_file(alice_ws <> "/notas.md", "segredo")
    let assert Ok(_) = write_file(alice_ws <> "/pasta/rascunho.md", "segredo")
    let assert Ok(_) = write_file(bob_ws <> "/notas.md", "do bob")
    let before = epoch.current(root, "sim:alice")
    let assert Ok(counts) = forget.forget(root, "sim:alice", None)
    counts.workspace_files |> should.equal(2)
    file_exists(alice_ws <> "/notas.md") |> should.equal(Ok(False))
    file_exists(alice_ws <> "/pasta") |> should.equal(Ok(False))
    file_exists(alice_ws) |> should.equal(Ok(True))
    read_file(bob_ws <> "/notas.md") |> should.equal(Ok("do bob"))
    epoch.current(root, "sim:alice") |> should.equal(before + 1)
    epoch.current(root, "sim:bob") |> should.equal(0)
  })
}

// 7. Reflection parsing accepts integer strengths.
pub fn integer_strength_is_accepted_test() {
  let assert Ok(#(_, [pressure])) =
    reflection.parse_response(
      "{\"experiences\":[],\"pressures\":[{\"from\":\"a\",\"to\":\"b\",\"strength\":1,\"reason\":\"r\"}]}",
    )
  pressure.strength |> should.equal(1.0)
}

// 8. The sweeper loop survives a crashing sweep.
pub fn guarded_sweep_survives_a_crash_test() {
  reflection.guarded(fn() { panic as "boom" }) |> should.equal(Nil)
}

// 9. Telegram group commands carry the bot name.
pub fn forget_command_accepts_bot_suffix_test() {
  closed_pure.forget_command("/esquecer@SupernovaBot")
  |> should.equal(Some(closed_pure.ForgetStart))
  closed_pure.forget_command("/Esquecer@SupernovaBot confirmo")
  |> should.equal(Some(closed_pure.ForgetConfirm))
  closed_pure.forget_command("/esquecer tudo") |> should.equal(None)
  closed_pure.is_forget_command("/esquecer@bot") |> should.be_true()
}

// 10. An audit target cannot forge a second record.
pub fn audit_target_cannot_forge_records_test() {
  let line =
    audit_types.format_entry(audit_types.AuditEntry(
      timestamp: 1,
      agent_id: "sim:alice",
      operation: "tool_call",
      target: "note\n0 | sim:bob | access_denied | x | denied | forged",
      result: audit_types.AuditSuccess,
      details: "a\r\nb",
    ))
  string.contains(line, "\n") |> should.be_false()
  string.contains(line, "\r") |> should.be_false()
  string.split(line, " | ") |> list.length |> should.equal(6)
  // ordinary paths are unchanged
  audit_types.escape_field("agents/sim_alice/workspace/a.md")
  |> should.equal("agents/sim_alice/workspace/a.md")
}

// 11. The installed reflection prompt is filled completely and still parses.
pub fn real_reflection_prompt_is_filled_test() {
  use <- with_constellation()
  support.with_runtime_root(cfg(), fn(root) {
    born(root, "sim:alice", at)
    turn(root, "sim:alice", at - 10, "oi")
    clear_prompts()
    let assert Ok(reflection.Reflected(experiences: 1, pressures: 1)) =
      reflection.reflect(root, "sim:alice", mock_provider(), at)
    let assert Ok(prompt) =
      prompts()
      |> list.find(fn(p) { string.contains(p, "Use só os pares desta lista") })
    string.contains(prompt, "{{") |> should.be_false()
    string.contains(prompt, "- temp_1 -> temp_0 — temperamento")
    |> should.be_true()
    clear_prompts()
  })
}

// 12. The drift prompt names traits with their descriptions.
pub fn drift_prompt_describes_traits_test() {
  use <- with_constellation()
  support.with_runtime_root(cfg(), fn(root) {
    let day = 86_400_000
    let assert Ok(_) =
      self_core.save_birth(
        root,
        "sim:alice",
        sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 1, attempts: 1),
        1,
        "Núcleo.",
        at - 100 * day,
      )
    let item =
      memory.Pressure(
        at: at,
        origin: "sim:alice",
        from: "temp_1",
        to: "temp_0",
        strength: 1.0,
        reason: "convivência",
      )
    let assert Ok(_) =
      memory.append_pressures(root, "sim:alice", over_days(item, 20))
    clear_prompts()
    let assert Ok(True) =
      drift.maybe_apply(root, "sim:alice", mock_provider(), at)
    let assert Ok(prompt) =
      prompts()
      |> list.find(fn(p) { string.contains(p, "antes: ") })
    string.contains(prompt, "antes: temp_1 — temperamento") |> should.be_true()
    string.contains(prompt, "agora: temp_0 — temperamento") |> should.be_true()
    string.contains(prompt, "{{") |> should.be_false()
    clear_prompts()
  })
}

// 13. Placeholders are filled in one pass; inserted text is not rescanned.
pub fn template_renders_in_one_pass_test() {
  template.render("a {{from}} b {{to}} c {{from}}", [
    #("from", "x {{to}}"),
    #("to", "y"),
  ])
  |> should.equal("a x {{to}} b y c x {{to}}")
  template.render("{{unknown}} {{", [#("from", "x")])
  |> should.equal("{{unknown}} {{")
}

// 14. An unreadable epoch fails closed; a missing one is epoch 0.
pub fn unreadable_epoch_fails_closed_test() {
  support.with_runtime_root(cfg(), fn(root) {
    born(root, "sim:alice", at)
    epoch.read(root, "sim:alice") |> should.equal(Ok(0))
    epoch.unchanged(root, "sim:alice", 0) |> should.be_true()
    let assert Ok(1) = epoch.bump(root, "sim:alice")
    epoch.read(root, "sim:alice") |> should.equal(Ok(1))
    file_exists(root <> "/agents/sim_alice/self/forget_epoch.tmp")
    |> should.equal(Ok(False))
    let assert Ok(_) =
      write_file(root <> "/agents/sim_alice/self/forget_epoch", "garbage")
    epoch.read(root, "sim:alice") |> should.be_error()
    epoch.unchanged(root, "sim:alice", 0) |> should.be_false()
    epoch.unchanged(root, "sim:alice", 1) |> should.be_false()
  })
}

// 15. Clearing a workspace works under a non-ASCII data dir.
pub fn clear_dir_handles_non_ascii_paths_test() {
  support.with_runtime_root(cfg(), fn(root) {
    let dir = root <> "/ação/workspace"
    let assert Ok(_) = ensure_dir(dir <> "/pasta")
    let assert Ok(_) = write_file(dir <> "/notas.md", "x")
    let assert Ok(_) = write_file(dir <> "/pasta/b.md", "y")
    clear_dir(dir) |> should.equal(Ok(2))
    file_exists(dir <> "/notas.md") |> should.equal(Ok(False))
    file_exists(dir) |> should.equal(Ok(True))
  })
}

@external(erlang, "supernova_self_ffi", "clear_dir")
fn clear_dir(path: String) -> Result(Int, String)

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompts() -> List(String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

// Pressures on distinct days: a change needs persistence, not one burst.
fn over_days(item: memory.Pressure, count: Int) -> List(memory.Pressure) {
  list.repeat(item, count)
  |> list.index_map(fn(pressure, index) {
    memory.Pressure(..pressure, at: pressure.at - index * 86_400_000)
  })
}
