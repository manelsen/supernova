import e2e/e2e_support as support
import envoy
import exception
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/config
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
    ),
  )
}

fn seed(data_dir: String, now: Int) -> Nil {
  let assert Ok(_) =
    self_core.save_birth(
      data_dir,
      "sim:alice",
      sampler.Sampled(traits: ["curiosa"], seed: 1, attempts: 1),
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
    let assert Ok(reflection.Reflected(experiences: 1, pressures: 0)) =
      reflection.reflect(root, "sim:alice", mock_provider(), at)
    journal.load(root, "sim:alice") |> should.equal([])
    memory.experiences(root, "sim:alice")
    |> list.map(fn(item) { item.origin })
    |> should.equal(["sim:alice"])
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
        sampler.Sampled(traits: ["curiosa"], seed: 1, attempts: 1),
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
