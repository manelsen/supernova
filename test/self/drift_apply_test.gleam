import e2e/e2e_support as support
import envoy
import exception
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import supernova/config
import supernova/core/audit_log/actor as audit_actor
import supernova/core/closed_group/global as closed_group_global
import supernova/llm/provider
import supernova/self/core as self_core
import supernova/self/drift
import supernova/self/memory
import supernova/self/sampler
import test_workspace

const day = 86_400_000

fn mock_addendum() -> String {
  string.join(list.repeat("convivência", 60), " ")
}

fn valid_addendum() -> String {
  story |> drift.validate_addendum |> result.unwrap("")
}

const story =
  "Aprendi que o cuidado mora nos detalhes pequenos e que escutar antes de responder muda o sentido inteiro de uma conversa. Levo comigo a paciência de quem espera o outro terminar, a vontade de perguntar quando não entendo e a disposição de admitir quando errei. Não preciso ter pressa para provar o que sei; prefiro mostrar quem sou no jeito de tratar quem chega. O que ficou de tudo isso foi a certeza de que presença vale mais do que desempenho e que a voz de alguém se reconhece na atenção que oferece. Sigo assim, mais atenta ao que acontece entre as palavras do que ao que elas apenas dizem."

fn pending_for(now: Int) -> self_core.DriftPending {
  self_core.DriftPending(
    from: "temp_1",
    to: "temp_0",
    addendum: valid_addendum(),
    at: now,
  )
}

fn count_occurrences(text: String, needle: String) -> Int {
  list.length(string.split(text, needle)) - 1
}

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

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
    let addenda = memory.addenda(root, "sim:alice")
    addenda |> should.equal("\n\n" <> mock_addendum() <> "\n")
    self_core.last_drift_at(root, "sim:alice") |> should.equal(now)
    file_exists(self_core.drift_pending_path(root, "sim:alice"))
    |> should.equal(Ok(False))
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
  // A fresh directory, removed afterwards. A name from unique_integer/0
  // repeats across VM runs and left stale pressures behind (flaky count).
  use root <- test_workspace.with_isolated_workspace("drift-no-runtime")
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

pub fn stale_source_pressure_does_not_drift_test() {
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
    let first =
      memory.Pressure(
        at: now,
        origin: "sim:alice",
        from: "temp_1",
        to: "temp_0",
        strength: 1.0,
        reason: "convivência",
      )
    let assert Ok(_) =
      memory.append_pressures(root, "sim:alice", list.repeat(first, 20))
    let assert Ok(True) =
      drift.maybe_apply(root, "sim:alice", mock_provider(), now)
    let later = now + 90 * day
    let stale =
      memory.Pressure(
        at: later,
        origin: "sim:alice",
        from: "temp_1",
        to: "temp_2",
        strength: 1.0,
        reason: "pressão antiga",
      )
    let assert Ok(_) =
      memory.append_pressures(root, "sim:alice", list.repeat(stale, 20))
    let assert Ok(False) =
      drift.maybe_apply(root, "sim:alice", mock_provider(), later)
    let assert Some(core) = self_core.load(root, "sim:alice")
    core.traits |> should.equal(["temp_0", "voz_0"])
    memory.pressures(root, "sim:alice") |> list.length |> should.equal(20)
  })
}

fn seed_drift_root(root: String, now: Int, prose: String) -> Nil {
  let assert Ok(_) =
    self_core.save_birth(
      root,
      "sim:alice",
      sampler.Sampled(traits: ["temp_1", "voz_0"], seed: 1, attempts: 1),
      1,
      prose,
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
  Nil
}

fn assert_recovered(root: String, now: Int, expected: String) -> Nil {
  let assert Some(core) = self_core.load(root, "sim:alice")
  core.traits |> should.equal(["temp_0", "voz_0"])
  memory.addenda(root, "sim:alice")
  |> count_occurrences(expected)
  |> should.equal(1)
  self_core.last_drift_at(root, "sim:alice") |> should.equal(now)
  memory.pressures(root, "sim:alice") |> should.equal([])
  file_exists(self_core.drift_pending_path(root, "sim:alice"))
  |> should.equal(Ok(False))
}

fn apply_core_traits(root: String) -> Nil {
  let assert Some(core) = self_core.load(root, "sim:alice")
  let traits =
    list.map(core.traits, fn(id) {
      case id == "temp_1" {
        True -> "temp_0"
        False -> id
      }
    })
  let assert Ok(_) =
    self_core.save(root, "sim:alice", self_core.Core(..core, traits: traits))
  Nil
}

fn apply_biography(root: String, now: Int) -> Nil {
  let assert Ok(_) =
    self_core.append_biography_entry(
      root,
      "sim:alice",
      json.to_string(
        json.object([
          #("at", json.int(now)),
          #("kind", json.string("drift")),
          #("from", json.string("temp_1")),
          #("to", json.string("temp_0")),
          #("reason", json.string(valid_addendum())),
        ]),
      ),
    )
  Nil
}

pub fn drift_recovers_after_each_interrupted_step_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  let now = 1_700_000_000_000
  let interruptions = [
    #("after_pending", fn(_root: String) { Nil }),
    #("after_addenda", fn(root: String) {
      let assert Ok(_) =
        memory.append_addendum(root, "sim:alice", valid_addendum())
      Nil
    }),
    #("after_core", fn(root: String) {
      let assert Ok(_) =
        memory.append_addendum(root, "sim:alice", valid_addendum())
      apply_core_traits(root)
    }),
    #("after_biography", fn(root: String) {
      let assert Ok(_) =
        memory.append_addendum(root, "sim:alice", valid_addendum())
      apply_core_traits(root)
      apply_biography(root, now)
    }),
    #("after_pressures", fn(root: String) {
      let assert Ok(_) =
        memory.append_addendum(root, "sim:alice", valid_addendum())
      apply_core_traits(root)
      apply_biography(root, now)
      let assert Ok(_) = memory.replace_pressures(root, "sim:alice", [])
      Nil
    }),
  ]
  interruptions
  |> list.each(fn(interruption) {
    let #(_name, apply_partial) = interruption
    support.with_runtime_root(cfg(), fn(root) {
      seed_drift_root(root, now, "PROSA QUE NUNCA MUDA.")
      apply_partial(root)
      let assert Ok(_) =
        self_core.write_drift_pending(root, "sim:alice", pending_for(now))
      assert_recovered(root, now, valid_addendum())
    })
  })
}

pub fn short_addendum_is_rejected_and_retried_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  support.with_runtime_root(cfg(), fn(root) {
    let now = 1_700_000_000_000
    seed_drift_root(root, now, "PROSA. [mock-drift-20]")
    let assert Ok(False) =
      drift.maybe_apply(root, "sim:alice", mock_provider(), now)
    let assert Some(core) = self_core.load(root, "sim:alice")
    core.traits |> should.equal(["temp_1", "voz_0"])
    memory.pressures(root, "sim:alice") |> list.length |> should.equal(20)
    memory.addenda(root, "sim:alice") |> should.equal("")
    let assert Some(log) = closed_group_global.get_audit()
    audit_actor.get_by_operation(log, "drift_rejected")
    |> list.any(fn(entry) { string.contains(entry.details, "too short") })
    |> should.equal(True)
    // The same pressures are tried again after the next reflection.
    let assert Ok(_) =
      write_file(self_core.prose_path(root, "sim:alice"), "PROSA.")
    let assert Ok(True) =
      drift.maybe_apply(root, "sim:alice", mock_provider(), now)
    assert_recovered(root, now, mock_addendum())
  })
}

pub fn long_addendum_is_rejected_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  support.with_runtime_root(cfg(), fn(root) {
    let now = 1_700_000_000_000
    seed_drift_root(root, now, "PROSA. [mock-drift-200]")
    let assert Ok(False) =
      drift.maybe_apply(root, "sim:alice", mock_provider(), now)
    let assert Some(core) = self_core.load(root, "sim:alice")
    core.traits |> should.equal(["temp_1", "voz_0"])
    memory.pressures(root, "sim:alice") |> list.length |> should.equal(20)
    let assert Some(log) = closed_group_global.get_audit()
    audit_actor.get_by_operation(log, "drift_rejected")
    |> list.any(fn(entry) { string.contains(entry.details, "too long") })
    |> should.equal(True)
  })
}

pub fn validate_addendum_rejects_headings_test() {
  drift.validate_addendum(
    "# título\n" <> string.join(list.repeat("palavra", 60), " "),
  )
  |> should.equal(Error("addendum contains a heading"))
}

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)
