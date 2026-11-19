//// Periodic reflection: turn the journal into experiences and pressures.
////
//// Runs outside the router. Admission and usage go through the owner's ledger
//// with a `reflect:<principal>:<at>` call id.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
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
import supernova/self/journal
import supernova/self/memory

const prompt_path = "priv/reflection/reflection_prompt.md"

const lock_name = "/.reflection.lock"

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
      by_count || by_time
    }
  }
}

/// Apply the trigger to every known agent. Called by the hourly sweeper.
pub fn sweep(data_dir: String, llm_config: provider.ProviderConfig) -> Nil {
  let now = now_or(closed_group_global.now())
  list_agent_dirs(data_dir <> "/agents")
  |> list.each(fn(encoded) {
    let principal = agent_identity.decode_principal(encoded)
    let _ = reflect(data_dir, principal, llm_config, now)
    Nil
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
  sweep(data_dir, llm_config)
  sweep_loop(data_dir, llm_config)
}

/// Schedule an asynchronous reflection when the trigger fires.
pub fn schedule(principal: String, llm_config: provider.ProviderConfig) -> Nil {
  case closed_group_global.get_config() {
    None -> Nil
    Some(cfg) -> {
      let now = now_or(closed_group_global.now())
      case should_reflect(cfg.data_dir, principal, cfg.reflection, now) {
        False -> Nil
        True -> {
          let _ =
            process.spawn_unlinked(fn() {
              let _ = reflect(cfg.data_dir, principal, llm_config, now)
              Nil
            })
          Nil
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
  let now = now_or(now)
  let cfg = case closed_group_global.get_config() {
    Some(cfg) -> cfg.reflection
    None -> config.default_reflection_config()
  }
  case should_reflect(data_dir, principal, cfg, now) {
    False -> Ok(Skipped)
    True -> {
      let lock = self_dir(data_dir, principal) <> lock_name
      case try_lock(lock) {
        False -> Ok(Skipped)
        True -> {
          let result = reflect_locked(data_dir, principal, llm_config, now, cfg)
          remove_lock(lock)
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
) -> Result(Outcome, String) {
  let entries = journal.load(data_dir, principal)
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
          case parse_response(response.content) {
            Error(reason) -> {
              audit.record(
                principal,
                "reflection_failed",
                "llm",
                audit_types.AuditFailure,
                reason,
              )
              Error(reason)
            }
            Ok(#(raw_experiences, raw_pressures)) -> {
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
    |> list.map(fn(id) { "g: " <> describe_trait(constellation, id) })
    |> string.join("\n")
  let neighbors =
    traits
    |> list.flat_map(fn(id) {
      let dimension = trait_dimension(constellation, id)
      constellation.traits
      |> list.filter(fn(trait) {
        trait.dimension == dimension
        && trait.id != id
        && !list.contains(traits, trait.id)
        && constellation.affinity_weight(constellation, id, trait.id) >. 0.0
      })
      |> list.map(fn(trait) {
        "- " <> id <> " -> " <> describe_trait(constellation, trait.id)
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
  template
  |> string.replace("{{core}}", prose)
  |> string.replace("{{addenda}}", addenda)
  |> string.replace("{{traits}}", trait_lines)
  |> string.replace("{{neighbors}}", neighbors)
  |> string.replace("{{experience}}", experiences)
  |> string.replace("{{journal}}", journal_text)
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
  case json.parse(from: raw, using: decode.dynamic) {
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

fn raw_pressure_decoder() -> decode.Decoder(RawPressure) {
  use from <- decode.field("from", decode.string)
  use to <- decode.field("to", decode.string)
  use strength <- decode.field("strength", decode.float)
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

@external(erlang, "supernova_self_ffi", "try_lock_file")
fn try_lock(path: String) -> Bool

@external(erlang, "supernova_self_ffi", "remove_lock_file")
fn remove_lock(path: String) -> Nil

@external(erlang, "supernova_self_ffi", "list_agent_dirs")
fn list_agent_dirs(path: String) -> List(String)

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_now() -> Int

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
