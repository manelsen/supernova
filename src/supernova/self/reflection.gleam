//// Periodic reflection: turn the journal into experiences and pressures.
////
//// Runs outside the router. Admission and usage go through the owner's ledger
//// with a `reflect:<principal>:<at>` call id.

import exception
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import supernova/channel/chat_lanes
import supernova/config
import supernova/core/agent_identity
import supernova/core/audit_log/types as audit_types
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/runtime as closed_runtime
import supernova/core/closed_group/types as closed_types
import supernova/core/executor
import supernova/core/introspection/self_state
import supernova/llm/provider
import supernova/self/audit
import supernova/self/constellation
import supernova/self/core as self_core
import supernova/self/drift
import supernova/self/epoch
import supernova/self/journal
import supernova/self/memory
import supernova/self/template as prompt_template

const prompt_path = "priv/reflection/reflection_prompt.md"

/// Oldest journal entries read by one reflection. The rest wait for the next.
pub const max_batch = 60

const hour_ms = 3_600_000

const max_backoff_ms = 86_400_000

pub type Outcome {
  Reflected(experiences: Int, pressures: Int)
  Skipped
}

pub type RawPressure {
  RawPressure(from: String, to: String, strength: Float, reason: String)
}

fn now_or(value: Int) -> Int {
  case value {
    0 -> ffi_now()
    _ -> value
  }
}

pub fn should_reflect(
  data_dir: String,
  principal: String,
  reflection: config.ReflectionConfig,
  now: Int,
) -> Bool {
  let entries = journal.load(data_dir, principal)
  case entries {
    [] -> False
    _ -> {
      let state = self_state.from_dir(self_dir(data_dir, principal))
      let born_at = case self_core.load(data_dir, principal) {
        Some(core) -> core.born_at
        None -> 0
      }
      let baseline = case state.last_reflection_at {
        0 -> born_at
        at -> at
      }
      let by_count =
        reflection.every_turns > 0
        && list.length(entries) >= reflection.every_turns
      let by_time =
        reflection.every_hours > 0
        && now - baseline >= reflection.every_hours * 3_600_000
      { by_count || by_time } && !backing_off(data_dir, principal, now)
    }
  }
}

/// After a failed reflection, wait 1 h, then 2 h, 4 h... up to 24 h before
/// trying again, so a model that keeps failing does not cost a call per turn.
fn backing_off(data_dir: String, principal: String, now: Int) -> Bool {
  let #(failures, last_attempt_at) = read_backoff(data_dir, principal)
  case failures {
    0 -> False
    _ -> now - last_attempt_at < backoff_ms(failures)
  }
}

fn backoff_ms(failures: Int) -> Int {
  let doublings = int.min(failures - 1, 5)
  int.min(max_backoff_ms, hour_ms * int.bitwise_shift_left(1, doublings))
}

fn backoff_path(data_dir: String, principal: String) -> String {
  self_dir(data_dir, principal) <> "/reflection_backoff.json"
}

fn read_backoff(data_dir: String, principal: String) -> #(Int, Int) {
  let decoder = {
    use failures <- decode.field("failures", decode.int)
    use last_attempt_at <- decode.field("last_attempt_at", decode.int)
    decode.success(#(failures, last_attempt_at))
  }
  case read_file(backoff_path(data_dir, principal)) {
    Error(_) -> #(0, 0)
    Ok(raw) ->
      case json.parse(from: raw, using: decoder) {
        Ok(value) -> value
        Error(_) -> #(0, 0)
      }
  }
}

fn record_attempt(
  data_dir: String,
  principal: String,
  now: Int,
  succeeded: Bool,
) -> Nil {
  let failures = case succeeded {
    True -> 0
    False -> read_backoff(data_dir, principal).0 + 1
  }
  let _ =
    write_file(
      backoff_path(data_dir, principal),
      json.to_string(
        json.object([
          #("failures", json.int(failures)),
          #("last_attempt_at", json.int(now)),
        ]),
      ),
    )
  Nil
}

/// Apply the trigger to every known agent. Called by the hourly sweeper.
pub fn sweep(data_dir: String, llm_config: provider.ProviderConfig) -> Nil {
  let now = now_or(closed_group_global.now())
  list_agent_dirs(data_dir <> "/agents")
  |> list.each(fn(encoded) {
    let principal = agent_identity.decode_principal(encoded)
    guarded(fn() {
      let _ = reflect(data_dir, principal, llm_config, now)
      Nil
    })
  })
}

/// Start the hourly sweeper process. It is deliberately independent from the
/// router so a quiet owner still gets reflected.
pub fn start_sweeper(
  data_dir: String,
  llm_config: provider.ProviderConfig,
) -> Nil {
  let _ = process.spawn_unlinked(fn() { sweep_loop(data_dir, llm_config) })
  Nil
}

fn sweep_loop(data_dir: String, llm_config: provider.ProviderConfig) -> Nil {
  process.sleep(3_600_000)
  guarded(fn() { sweep(data_dir, llm_config) })
  sweep_loop(data_dir, llm_config)
}

/// Run `body`, logging and swallowing any crash, so the hourly sweeper keeps
/// running after one bad agent or one bad sweep.
pub fn guarded(body: fn() -> Nil) -> Nil {
  case exception.rescue(body) {
    Ok(Nil) -> Nil
    Error(error) -> {
      io.println_error(
        "error: reflection sweep crashed: " <> string.inspect(error),
      )
      Nil
    }
  }
}

/// Schedule an asynchronous reflection when the trigger fires.
pub fn schedule(principal: String, llm_config: provider.ProviderConfig) -> Nil {
  case closed_group_global.get_config() {
    None -> Nil
    Some(cfg) -> {
      let now = now_or(closed_group_global.now())
      case should_reflect(cfg.data_dir, principal, cfg.reflection, now) {
        False -> Nil
        True ->
          case cfg.environment {
            // The harness drives time and shuts the runtime down between
            // scenarios: a reflection must finish inside the turn, so it can
            // never outlive the runtime and the turn_end that follows marks
            // its end. Production keeps reflection off the router.
            "harness" -> {
              let _ = reflect(cfg.data_dir, principal, llm_config, now)
              Nil
            }
            _ -> {
              let _ =
                chat_lanes.submit("reflection:" <> principal, fn() {
                  let started = now_or(closed_group_global.now())
                  let _ = reflect(cfg.data_dir, principal, llm_config, started)
                  Nil
                })
              Nil
            }
          }
      }
    }
  }
}

/// Synchronous reflection used by tests and by the sweeper.
pub fn reflect(
  data_dir: String,
  principal: String,
  llm_config: provider.ProviderConfig,
  now: Int,
) -> Result(Outcome, String) {
  reflect_from_epoch(
    data_dir,
    principal,
    llm_config,
    now,
    epoch.current(data_dir, principal),
  )
}

/// Reflect as work that started under forget epoch `started`. If the owner
/// forgets while the model is thinking, the result is discarded.
pub fn reflect_from_epoch(
  data_dir: String,
  principal: String,
  llm_config: provider.ProviderConfig,
  now: Int,
  started: Int,
) -> Result(Outcome, String) {
  let now = now_or(now)
  let cfg = case closed_group_global.get_config() {
    Some(cfg) -> cfg.reflection
    None -> config.default_reflection_config()
  }
  case should_reflect(data_dir, principal, cfg, now) {
    False -> Ok(Skipped)
    True -> {
      case acquire_lock(data_dir, principal) {
        False -> Ok(Skipped)
        True -> {
          let result =
            reflect_locked(data_dir, principal, llm_config, now, cfg, started)
          case result {
            Error("forgotten during reflection") -> Nil
            Error(_) -> record_attempt(data_dir, principal, now, False)
            Ok(_) -> record_attempt(data_dir, principal, now, True)
          }
          release_lock(data_dir, principal)
          result
        }
      }
    }
  }
}

fn reflect_locked(
  data_dir: String,
  principal: String,
  llm_config: provider.ProviderConfig,
  now: Int,
  cfg: config.ReflectionConfig,
  started: Int,
) -> Result(Outcome, String) {
  let entries = journal.load(data_dir, principal) |> list.take(max_batch)
  case entries {
    [] -> Ok(Skipped)
    _ -> {
      use core <- result.try(case self_core.load(data_dir, principal) {
        Some(core) -> Ok(core)
        None -> {
          audit.record(
            principal,
            "reflection_unavailable",
            "core",
            audit_types.AuditFailure,
            "missing core",
          )
          Error("missing core")
        }
      })
      use prose <- result.try(case self_core.read_prose(data_dir, principal) {
        Some(prose) -> Ok(prose)
        None -> {
          audit.record(
            principal,
            "reflection_unavailable",
            "core.md",
            audit_types.AuditFailure,
            "missing core prose",
          )
          Error("missing core prose")
        }
      })
      use template <- result.try(case read_file(prompt_path) {
        Ok(text) -> Ok(text)
        Error(_) -> {
          audit.record(
            principal,
            "reflection_unavailable",
            prompt_path,
            audit_types.AuditFailure,
            "missing prompt",
          )
          Error("reflection prompt unavailable")
        }
      })
      use constellation <- result.try(
        case constellation.load(self_core.constellation_path()) {
          Ok(value) -> Ok(value)
          Error(reason) -> {
            audit.record(
              principal,
              "reflection_unavailable",
              "constellation",
              audit_types.AuditFailure,
              reason,
            )
            Error(reason)
          }
        },
      )
      let prompt =
        build_prompt(
          template,
          data_dir,
          principal,
          prose,
          core.traits,
          constellation,
          entries,
        )
      let model_config = case cfg.model {
        Some(model) ->
          provider.ProviderConfig(..llm_config, default_model: model)
        None -> llm_config
      }
      let messages = [
        provider.system_message(prompt),
        provider.user_message("Reflita agora e responda só o JSON."),
      ]
      use run_context <- result.try(case closed_group_global.get_runtime() {
        None -> {
          audit.record(
            principal,
            "reflection_denied",
            "ledger",
            audit_types.AuditDenied,
            "runtime unavailable",
          )
          Error("runtime unavailable")
        }
        Some(runtime) -> {
          let context =
            closed_runtime.run_context(
              runtime,
              closed_types.PrincipalContext(
                principal_id: principal,
                role: "member",
              ),
            )
          Ok(
            executor.RunContext(
              ..context,
              purpose: "reflection",
              call_id_override: Some(
                "reflect:" <> principal <> ":" <> int.to_string(now),
              ),
            ),
          )
        }
      })
      case executor.run_with_context(messages, model_config, [], run_context) {
        Error(executor.PolicyDenied(reason)) -> {
          audit.record(
            principal,
            "reflection_denied",
            "ledger",
            audit_types.AuditDenied,
            reason,
          )
          Error(reason)
        }
        Error(error) -> {
          audit.record(
            principal,
            "reflection_failed",
            "llm",
            audit_types.AuditFailure,
            error_text(error),
          )
          Error(error_text(error))
        }
        Ok(response) ->
          case
            epoch.unchanged(data_dir, principal, started),
            parse_response(response.content)
          {
            False, _ -> {
              audit.record(
                principal,
                "reflection_discarded",
                principal,
                audit_types.AuditFailure,
                "forgotten during reflection",
              )
              Error("forgotten during reflection")
            }
            True, Error(reason) -> {
              audit.record(
                principal,
                "reflection_failed",
                "llm",
                audit_types.AuditFailure,
                reason,
              )
              Error(reason)
            }
            True, Ok(#(raw_experiences, raw_pressures)) -> {
              let experiences =
                raw_experiences
                |> list.filter_map(valid_experience)
                |> list.take(5)
              let pressures =
                valid_pressures(raw_pressures, core.traits, constellation)
              let origin = case entries {
                [first, ..] -> first.origin
                [] -> principal
              }
              let experience_items =
                list.map(experiences, fn(text) {
                  memory.Experience(at: now, origin: origin, text: text)
                })
              let pressure_items =
                list.map(pressures, fn(item) {
                  memory.Pressure(
                    at: now,
                    origin: origin,
                    from: item.from,
                    to: item.to,
                    strength: item.strength,
                    reason: item.reason,
                  )
                })
              use _ <- result.try(memory.append_experiences(
                data_dir,
                principal,
                experience_items,
              ))
              use _ <- result.try(memory.append_pressures(
                data_dir,
                principal,
                pressure_items,
              ))
              use _ <- result.try(journal.remove_many(
                data_dir,
                principal,
                entries,
              ))
              let state = self_state.from_dir(self_dir(data_dir, principal))
              let _ =
                self_state.save_in(
                  self_dir(data_dir, principal),
                  self_state.SelfState(..state, last_reflection_at: now),
                )
              audit.record(
                principal,
                "reflection",
                principal,
                audit_types.AuditSuccess,
                audit.counts([
                  #("experiences", list.length(experience_items)),
                  #("pressures", list.length(pressure_items)),
                ]),
              )
              let _ = drift.maybe_apply(data_dir, principal, llm_config, now)
              Ok(Reflected(
                experiences: list.length(experience_items),
                pressures: list.length(pressure_items),
              ))
            }
          }
      }
    }
  }
}

fn build_prompt(
  template: String,
  data_dir: String,
  principal: String,
  prose: String,
  traits: List(String),
  constellation: constellation.Constellation,
  entries: List(journal.Entry),
) -> String {
  let addenda = memory.addenda(data_dir, principal)
  let trait_lines =
    traits
    |> list.map(fn(id) { "- " <> describe_trait(constellation, id) })
    |> string.join("\n")
  let neighbors =
    traits
    |> list.flat_map(fn(from) {
      let dimension = trait_dimension(constellation, from)
      let remaining = list.filter(traits, fn(id) { id != from })
      constellation.traits
      |> list.filter(fn(trait) {
        let proposed = list.append(remaining, [trait.id])
        trait.dimension == dimension
        && trait.id != from
        && !list.contains(traits, trait.id)
        && !has_absolute_incompatibility(constellation, proposed)
        && list.any(remaining, fn(id) {
          constellation.affinity_weight(constellation, trait.id, id) >. 0.0
        })
      })
      |> list.map(fn(trait) {
        "- " <> from <> " -> " <> describe_trait(constellation, trait.id)
      })
    })
    |> string.join("\n")
  let experiences =
    memory.recent_experiences(data_dir, principal, 12)
    |> list.map(fn(item) { "- " <> item.text })
    |> string.join("\n")
  let journal_text =
    entries
    |> list.map(fn(entry) {
      "pessoa: " <> entry.user <> "\nagente: " <> entry.agent
    })
    |> string.join("\n---\n")
  prompt_template.render(template, [
    #("core", prose),
    #("addenda", addenda),
    #("traits", trait_lines),
    #("neighbors", neighbors),
    #("experience", experiences),
    #("journal", journal_text),
  ])
}

fn describe_trait(
  constellation: constellation.Constellation,
  id: String,
) -> String {
  case list.find(constellation.traits, fn(trait) { trait.id == id }) {
    Ok(trait) -> id <> " — " <> trait.description
    Error(_) -> id
  }
}

fn trait_dimension(
  constellation: constellation.Constellation,
  id: String,
) -> String {
  case list.find(constellation.traits, fn(trait) { trait.id == id }) {
    Ok(trait) -> trait.dimension
    Error(_) -> ""
  }
}

pub fn parse_response(
  raw: String,
) -> Result(#(List(Dynamic), List(RawPressure)), String) {
  let decoder = {
    use experiences <- decode.optional_field(
      "experiences",
      [],
      decode.list(decode.dynamic),
    )
    use pressures <- decode.optional_field(
      "pressures",
      [],
      decode.list(decode.dynamic),
    )
    decode.success(#(experiences, pressures))
  }
  case json.parse(from: strip_code_fence(raw), using: decode.dynamic) {
    Error(_) -> Error("invalid reflection JSON")
    Ok(dynamic) ->
      case decode.run(dynamic, decoder) {
        Error(_) -> Error("invalid reflection JSON shape")
        Ok(#(experiences, pressures)) -> {
          let parsed_pressures =
            pressures
            |> list.filter_map(fn(item) {
              case decode.run(item, raw_pressure_decoder()) {
                Ok(pressure) -> Ok(pressure)
                Error(_) -> Error(Nil)
              }
            })
          Ok(#(experiences, parsed_pressures))
        }
      }
  }
}

/// Models often wrap JSON in a ``` block despite the instructions.
fn strip_code_fence(raw: String) -> String {
  let trimmed = string.trim(raw)
  case string.starts_with(trimmed, "```") {
    False -> trimmed
    True -> {
      let without_open = case string.split_once(trimmed, "\n") {
        Ok(#(_, rest)) -> rest
        Error(_) -> ""
      }
      let body = string.trim(without_open)
      case string.ends_with(body, "```") {
        True -> string.drop_end(body, 3) |> string.trim
        False -> body
      }
    }
  }
}

fn raw_pressure_decoder() -> decode.Decoder(RawPressure) {
  use from <- decode.field("from", decode.string)
  use to <- decode.field("to", decode.string)
  use strength <- decode.field(
    "strength",
    decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)]),
  )
  use reason <- decode.field("reason", decode.string)
  decode.success(RawPressure(
    from: from,
    to: to,
    strength: strength,
    reason: reason,
  ))
}

fn valid_experience(item: Dynamic) -> Result(String, Nil) {
  case decode.run(item, decode.at(["text"], decode.string)) {
    Error(_) -> Error(Nil)
    Ok(text) -> {
      let trimmed = string.trim(text)
      let length = string.length(trimmed)
      case length >= 1 && length <= 280 {
        True -> Ok(trimmed)
        False -> Error(Nil)
      }
    }
  }
}

pub fn valid_pressures(
  pressures: List(RawPressure),
  traits: List(String),
  constellation: constellation.Constellation,
) -> List(RawPressure) {
  pressures
  |> list.filter(fn(item) { valid_pressure(item, traits, constellation) })
  |> list.take(2)
}

fn valid_pressure(
  pressure: RawPressure,
  traits: List(String),
  constellation: constellation.Constellation,
) -> Bool {
  let current = list.contains(traits, pressure.from)
  let target =
    list.find(constellation.traits, fn(trait) { trait.id == pressure.to })
  case current, target {
    True, Ok(trait) -> {
      let from_dimension = trait_dimension(constellation, pressure.from)
      let remaining = list.filter(traits, fn(id) { id != pressure.from })
      let proposed = list.append(remaining, [pressure.to])
      let no_absolute = !has_absolute_incompatibility(constellation, proposed)
      let has_neighbor =
        list.any(remaining, fn(id) {
          constellation.affinity_weight(constellation, pressure.to, id) >. 0.0
        })
      trait.dimension == from_dimension
      && !list.contains(traits, pressure.to)
      && no_absolute
      && has_neighbor
      && pressure.strength >=. 0.0
      && pressure.strength <=. 1.0
    }
    _, _ -> False
  }
}

fn has_absolute_incompatibility(
  constellation: constellation.Constellation,
  traits: List(String),
) -> Bool {
  case traits {
    [] -> False
    [first, ..rest] ->
      list.any(rest, fn(other) {
        constellation.affinity_weight(constellation, first, other) == -1.0
      })
      || has_absolute_incompatibility(constellation, rest)
  }
}

fn error_text(error: executor.ExecutorError) -> String {
  case error {
    executor.MaxDepthExceeded(_) -> "max depth"
    executor.LLMError(reason) -> "llm: " <> string.inspect(reason)
    executor.ToolError(name, reason) -> name <> ": " <> reason
    executor.YieldPaused(_) -> "yield paused"
    executor.YieldAborted(reason) -> "yield aborted: " <> reason
    executor.PolicyDenied(reason) -> reason
  }
}

fn self_dir(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal)
}

/// Take this agent's reflection lock for the calling process. The lock dies
/// with its holder, so a crash cannot silence the agent.
pub fn acquire_lock(data_dir: String, principal: String) -> Bool {
  try_global_lock(self_dir(data_dir, principal))
}

pub fn release_lock(data_dir: String, principal: String) -> Nil {
  release_global_lock(self_dir(data_dir, principal))
}

@external(erlang, "supernova_self_ffi", "try_global_lock")
fn try_global_lock(key: String) -> Bool

@external(erlang, "supernova_self_ffi", "release_global_lock")
fn release_global_lock(key: String) -> Nil

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_self_ffi", "list_agent_dirs")
fn list_agent_dirs(path: String) -> List(String)

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_now() -> Int

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
