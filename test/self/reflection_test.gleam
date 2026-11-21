import e2e/e2e_support as support
import envoy
import exception
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/config
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types as audit_types
import supernova/core/closed_group/global as closed_group_global
import supernova/core/introspection/self_state
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/resource_ledger/types.{LLMUsage}
import supernova/llm/provider
import supernova/self/core as self_core
import supernova/self/journal
import supernova/self/memory
import supernova/self/reflection
import supernova/self/sampler
import test_workspace

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
      ..support.access_config([], ["sim:alice"]),
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

fn seed(data_dir: String, now: Int) -> Nil {
  let assert Ok(_) =
    self_core.save_birth(
      data_dir,
      "sim:alice",
      sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 1, attempts: 1),
      1,
      "Núcleo provisório.",
      now - 1000,
    )
  let assert Ok(_) =
    journal.append(
      data_dir,
      "sim:alice",
      journal.Entry(
        at: now - 10,
        origin: "sim:alice",
        session: "sim:group-1:alice",
        user: "oi",
        agent: "olá",
      ),
      10,
    )
  Nil
}

pub fn reflection_writes_experience_and_charges_owner_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  support.with_runtime_root(cfg(), fn(root) {
    let at = 1_700_000_000_000
    seed(root, at)
    let assert Ok(reflection.Reflected(experiences: 1, pressures: 1)) =
      reflection.reflect(root, "sim:alice", mock_provider(), at)
    journal.load(root, "sim:alice") |> should.equal([])
    memory.experiences(root, "sim:alice")
    |> list.map(fn(item) { item.origin })
    |> should.equal(["sim:alice"])
    memory.pressures(root, "sim:alice")
    |> list.map(fn(item) { #(item.origin, item.from, item.to) })
    |> should.equal([#("sim:alice", "temp_1", "temp_0")])
    let state = self_state.from_dir(root <> "/agents/sim_alice/self")
    state.last_reflection_at |> should.equal(at)
    case closed_group_global.get_ledger() {
      Some(ledger) -> {
        ledger_actor.get_all_usage(ledger)
        |> list.any(fn(event) {
          case event {
            LLMUsage(principal_id: "sim:alice", call_id: call_id, ..) ->
              call_id == "reflect:sim:alice:" <> int.to_string(at)
            _ -> False
          }
        })
        |> should.be_true()
      }
      None -> should.fail()
    }
  })
}

pub fn no_entries_means_no_reflection_test() {
  support.with_runtime_root(cfg(), fn(root) {
    let assert Ok(reflection.Skipped) =
      reflection.reflect(root, "sim:alice", mock_provider(), 1_700_000_000_000)
  })
}

pub fn trigger_count_and_time_test() {
  support.with_runtime_root(cfg(), fn(root) {
    let reflection_config =
      config.ReflectionConfig(
        every_turns: 20,
        every_hours: 24,
        model: None,
        journal_limit: 500,
      )
    let now = 1_700_000_000_000
    let assert Ok(_) =
      self_core.save_birth(
        root,
        "sim:alice",
        sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 1, attempts: 1),
        1,
        "Núcleo.",
        now,
      )
    let add = fn(at: Int) {
      let assert Ok(_) =
        journal.append(
          root,
          "sim:alice",
          journal.Entry(
            at: at,
            origin: "sim:alice",
            session: "s",
            user: "oi",
            agent: "olá",
          ),
          100,
        )
      Nil
    }
    add(now)
    reflection.should_reflect(root, "sim:alice", reflection_config, now)
    |> should.equal(False)
    reflection.should_reflect(
      root,
      "sim:alice",
      config.ReflectionConfig(..reflection_config, every_turns: 1),
      now,
    )
    |> should.equal(True)
    reflection.should_reflect(
      root,
      "sim:alice",
      config.ReflectionConfig(
        ..reflection_config,
        every_turns: 100,
        every_hours: 1,
      ),
      now + 3_600_000,
    )
    |> should.equal(True)
  })
}

pub fn invalid_json_is_rejected_test() {
  let assert Error(_) = reflection.parse_response("not json")
}

pub fn sweep_without_agents_is_a_noop_test() {
  support.with_runtime_root(cfg(), fn(root) {
    reflection.sweep(root, mock_provider())
  })
}

pub fn missing_runtime_keeps_journal_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  closed_group_global.clear_runtime()
  // A fresh directory, removed afterwards (remove_dir_recursive only deletes
  // /tmp/supernova-test-* paths, so a unique_integer name was never cleaned).
  use root <- test_workspace.with_isolated_workspace("reflection-no-runtime")
  let assert Ok(_) =
    self_core.save_birth(
      root,
      "sim:alice",
      sampler.Sampled(traits: ["temp_0"], seed: 1, attempts: 1),
      1,
      "Núcleo.",
      1_700_000_000_000,
    )
  let at = 1_700_000_000_000
  [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
  |> list.each(fn(index) {
    let assert Ok(_) =
      journal.append(
        root,
        "sim:alice",
        journal.Entry(
          at: at + index,
          origin: "sim:alice",
          session: "s",
          user: "oi",
          agent: "olá",
        ),
        100,
      )
    Nil
  })
  let assert Error("runtime unavailable") =
    reflection.reflect(root, "sim:alice", mock_provider(), at + 100)
  journal.load(root, "sim:alice") |> list.length |> should.equal(20)
  memory.experiences(root, "sim:alice") |> should.equal([])
}

fn seed_twenty(root: String, at: Int, user: String) -> Nil {
  let assert Ok(_) =
    self_core.save_birth(
      root,
      "sim:alice",
      sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 1, attempts: 1),
      1,
      "Núcleo.",
      at - 1000,
    )
  [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
  |> list.each(fn(index) {
    let assert Ok(_) =
      journal.append(
        root,
        "sim:alice",
        journal.Entry(
          at: at + index,
          origin: "sim:alice",
          session: "s",
          user: user,
          agent: "olá",
        ),
        100,
      )
    Nil
  })
  Nil
}

pub fn twenty_turns_trigger_reflection_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  let config20 =
    config.Config(
      ..cfg(),
      reflection: config.ReflectionConfig(
        every_turns: 20,
        every_hours: 24,
        model: None,
        journal_limit: 500,
      ),
    )
  support.with_runtime_root(config20, fn(root) {
    let at = 1_700_000_000_000
    seed_twenty(root, at, "oi")
    let assert Ok(reflection.Reflected(experiences: 1, pressures: 1)) =
      reflection.reflect(root, "sim:alice", mock_provider(), at + 100)
    journal.load(root, "sim:alice") |> should.equal([])
    memory.experiences(root, "sim:alice")
    |> list.map(fn(item) { item.origin })
    |> should.equal(["sim:alice"])
    memory.pressures(root, "sim:alice")
    |> list.map(fn(item) { item.origin })
    |> should.equal(["sim:alice"])
  })
}

pub fn sweeper_reflects_after_24_hours_and_skips_empty_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  let config24 =
    config.Config(
      ..cfg(),
      reflection: config.ReflectionConfig(
        every_turns: 100,
        every_hours: 24,
        model: None,
        journal_limit: 500,
      ),
    )
  support.with_runtime_root(config24, fn(root) {
    let at = 1_700_000_000_000
    let assert Ok(_) =
      self_core.save_birth(
        root,
        "sim:alice",
        sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 1, attempts: 1),
        1,
        "Núcleo A.",
        at - 3_600_000,
      )
    let assert Ok(_) =
      self_core.save_birth(
        root,
        "sim:bob",
        sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 2, attempts: 1),
        1,
        "Núcleo B.",
        at - 3_600_000,
      )
    let assert Ok(_) =
      journal.append(
        root,
        "sim:alice",
        journal.Entry(
          at: at,
          origin: "sim:alice",
          session: "s",
          user: "oi",
          agent: "olá",
        ),
        100,
      )
    closed_group_global.set_clock(fn() { at + 24 * 3_600_000 })
    reflection.sweep(root, mock_provider())
    journal.load(root, "sim:alice") |> should.equal([])
    memory.experiences(root, "sim:alice") |> list.length |> should.equal(1)
    journal.load(root, "sim:bob") |> should.equal([])
    memory.experiences(root, "sim:bob") |> should.equal([])
  })
}

pub fn denied_admission_keeps_everything_and_audits_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  let budgets =
    config.RoleBudgetsConfig(
      member: config.RoleBudgetConfig(
        tokens_per_hour: 0,
        tool_calls_per_hour: 60,
      ),
      admin: config.RoleBudgetConfig(
        tokens_per_hour: -1,
        tool_calls_per_hour: -1,
      ),
    )
  support.with_runtime_root(
    config.Config(..cfg(), role_budgets: budgets),
    fn(root) {
      let at = 1_700_000_000_000
      seed(root, at)
      let before = journal.load(root, "sim:alice")
      let assert Error(_) =
        reflection.reflect(root, "sim:alice", mock_provider(), at)
      journal.load(root, "sim:alice") |> should.equal(before)
      memory.experiences(root, "sim:alice") |> should.equal([])
      memory.pressures(root, "sim:alice") |> should.equal([])
      case closed_group_global.get_audit() {
        Some(audit) ->
          audit_actor.get_all(audit)
          |> list.any(fn(entry) {
            entry.operation == "reflection_denied"
            && entry.result == audit_types.AuditDenied
          })
          |> should.be_true()
        None -> should.fail()
      }
    },
  )
}

pub fn invalid_response_keeps_journal_and_charges_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  support.with_runtime_root(cfg(), fn(root) {
    let at = 1_700_000_000_000
    seed(root, at)
    let assert Ok(_) =
      journal.append(
        root,
        "sim:alice",
        journal.Entry(
          at: at,
          origin: "sim:alice",
          session: "s",
          user: "[mock-invalid-reflection]",
          agent: "olá",
        ),
        100,
      )
    let before = journal.load(root, "sim:alice")
    let assert Error("invalid reflection JSON") =
      reflection.reflect(root, "sim:alice", mock_provider(), at)
    journal.load(root, "sim:alice") |> should.equal(before)
    memory.experiences(root, "sim:alice") |> should.equal([])
    case closed_group_global.get_ledger() {
      Some(ledger) ->
        ledger_actor.get_all_usage(ledger)
        |> list.any(fn(event) {
          case event {
            LLMUsage(principal_id: "sim:alice", ..) -> True
            _ -> False
          }
        })
        |> should.be_true()
      None -> should.fail()
    }
  })
}
