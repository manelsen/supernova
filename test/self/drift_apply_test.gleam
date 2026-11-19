import e2e/e2e_support as support
import envoy
import exception
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/config
import supernova/core/closed_group/global as closed_group_global
import supernova/llm/provider
import supernova/self/core as self_core
import supernova/self/drift
import supernova/self/memory
import supernova/self/sampler

const day = 86_400_000

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
    drift: config.DriftConfig(
      half_life_days: 30.0,
      threshold: 3.0,
      min_interval_days: 90,
    ),
  )
}

pub fn drift_changes_traits_but_not_core_prose_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  support.with_runtime_root(cfg(), fn(root) {
    let now = 1_700_000_000_000
    let assert Ok(_) =
      self_core.save_birth(
        root,
        "sim:alice",
        sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 1, attempts: 1),
        1,
        "PROSA QUE NUNCA MUDA.",
        now - 100 * day,
      )
    let item =
      memory.Pressure(
        at: now,
        origin: "sim:alice",
        from: "temp_1",
        to: "temp_0",
        strength: 1.0,
        reason: "convivência",
      )
    let assert Ok(_) =
      memory.append_pressures(root, "sim:alice", list.repeat(item, 20))
    let assert Ok(True) =
      drift.maybe_apply(root, "sim:alice", mock_provider(), now)
    let assert Some(core) = self_core.load(root, "sim:alice")
    core.traits |> should.equal(["temp_0", "voz_0"])
    self_core.read_prose(root, "sim:alice")
    |> should.equal(Some("PROSA QUE NUNCA MUDA."))
    memory.pressures(root, "sim:alice") |> should.equal([])
    memory.addenda(root, "sim:alice")
    |> should.equal("\n\nMock response\n")
    self_core.last_drift_at(root, "sim:alice") |> should.equal(now)
  })
}

pub fn under_90_days_does_not_change_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  support.with_runtime_root(cfg(), fn(root) {
    let now = 1_700_000_000_000
    let assert Ok(_) =
      self_core.save_birth(
        root,
        "sim:alice",
        sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 1, attempts: 1),
        1,
        "PROSA.",
        now - 89 * day,
      )
    let item =
      memory.Pressure(
        at: now,
        origin: "sim:alice",
        from: "temp_1",
        to: "temp_0",
        strength: 1.0,
        reason: "convivência",
      )
    let assert Ok(_) =
      memory.append_pressures(root, "sim:alice", list.repeat(item, 20))
    let assert Ok(False) =
      drift.maybe_apply(root, "sim:alice", mock_provider(), now)
    let assert Some(core) = self_core.load(root, "sim:alice")
    core.traits |> should.equal(["temp_1", "voz_0"])
    memory.pressures(root, "sim:alice") |> list.length |> should.equal(20)
  })
}

pub fn incoherent_change_does_not_happen_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "priv/constellation/constellation.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  support.with_runtime_root(cfg(), fn(root) {
    let now = 1_700_000_000_000
    let assert Ok(_) =
      self_core.save_birth(
        root,
        "sim:alice",
        sampler.Sampled(
          traits: ["contemplativa", "voz_economica"],
          seed: 1,
          attempts: 1,
        ),
        1,
        "PROSA.",
        now - 100 * day,
      )
    let item =
      memory.Pressure(
        at: now,
        origin: "sim:alice",
        from: "contemplativa",
        to: "inquieta",
        strength: 1.0,
        reason: "convivência",
      )
    let assert Ok(_) =
      memory.append_pressures(root, "sim:alice", list.repeat(item, 20))
    let assert Ok(False) =
      drift.maybe_apply(root, "sim:alice", mock_provider(), now)
    let assert Some(core) = self_core.load(root, "sim:alice")
    core.traits |> should.equal(["contemplativa", "voz_economica"])
    memory.pressures(root, "sim:alice") |> list.length |> should.equal(20)
  })
}

pub fn fifty_runs_without_clock_change_produce_one_drift_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  support.with_runtime_root(cfg(), fn(root) {
    let now = 1_700_000_000_000
    let assert Ok(_) =
      self_core.save_birth(
        root,
        "sim:alice",
        sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 1, attempts: 1),
        1,
        "PROSA.",
        now - 100 * day,
      )
    let changes =
      list.fold(list.repeat(0, 50), 0, fn(count, _) {
        let item =
          memory.Pressure(
            at: now,
            origin: "sim:alice",
            from: "temp_1",
            to: "temp_0",
            strength: 1.0,
            reason: "convivência",
          )
        let assert Ok(_) =
          memory.append_pressures(root, "sim:alice", list.repeat(item, 20))
        case drift.maybe_apply(root, "sim:alice", mock_provider(), now) {
          Ok(True) -> count + 1
          _ -> count
        }
      })
    changes |> should.equal(1)
    let assert Some(core) = self_core.load(root, "sim:alice")
    core.traits |> should.equal(["temp_0", "voz_0"])
  })
}

pub fn missing_runtime_does_not_change_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  closed_group_global.clear_runtime()
  let root =
    "/tmp/supernova-drift-no-runtime-" <> int.to_string(unique_integer())
  let now = 1_700_000_000_000
  let assert Ok(_) =
    self_core.save_birth(
      root,
      "sim:alice",
      sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 1, attempts: 1),
      1,
      "PROSA.",
      now - 100 * day,
    )
  let item =
    memory.Pressure(
      at: now,
      origin: "sim:alice",
      from: "temp_1",
      to: "temp_0",
      strength: 1.0,
      reason: "convivência",
    )
  let assert Ok(_) =
    memory.append_pressures(root, "sim:alice", list.repeat(item, 20))
  let assert Error("runtime unavailable") =
    drift.maybe_apply(root, "sim:alice", mock_provider(), now)
  let assert Some(core) = self_core.load(root, "sim:alice")
  core.traits |> should.equal(["temp_1", "voz_0"])
  memory.pressures(root, "sim:alice") |> list.length |> should.equal(20)
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
