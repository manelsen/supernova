//// Slow trait drift driven by accumulated, decaying pressure.

import gleam/dict
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/config
import supernova/core/audit_log/types as audit_types
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/runtime as closed_runtime
import supernova/core/closed_group/types as closed_types
import supernova/core/executor
import supernova/llm/provider
import supernova/self/audit
import supernova/self/constellation
import supernova/self/core as self_core
import supernova/self/memory
import supernova/self/sampler
import supernova/self/template as prompt_template

const day_ms = 86_400_000

const prompt_path = "priv/reflection/drift_prompt.md"

pub type EffectivePressure {
  EffectivePressure(from: String, to: String, value: Float)
}

pub fn effective_pressures(
  pressures: List(memory.Pressure),
  now: Int,
  half_life_days: Float,
) -> List(EffectivePressure) {
  let half_life_ms = float.max(1.0, half_life_days) *. int.to_float(day_ms)
  let contributions =
    pressures
    |> list.index_map(fn(item, index) {
      let previous =
        pressures
        |> list.take(index)
        |> list.filter(fn(prior) {
          prior.from == item.from
          && prior.to == item.to
          && prior.origin == item.origin
          && int.to_float(item.at - prior.at) <=. half_life_ms
        })
      let k = list.length(previous)
      let age = float.max(0.0, int.to_float(now - item.at))
      let decay = case float.power(0.5, age /. half_life_ms) {
        Ok(value) -> value
        Error(_) -> 0.0
      }
      let denominator = 1.0 +. int.to_float(k)
      let value = item.strength *. decay /. denominator
      #(item.from, item.to, value)
    })
  contributions
  |> list.fold(dict.new(), fn(acc, item) {
    let #(from, to, value) = item
    let key = #(from, to)
    case dict.get(acc, key) {
      Ok(existing) -> dict.insert(acc, key, existing +. value)
      Error(_) -> dict.insert(acc, key, value)
    }
  })
  |> dict.to_list
  |> list.map(fn(pair) {
    let #(#(from, to), value) = pair
    EffectivePressure(from: from, to: to, value: value)
  })
  |> list.sort(fn(a, b) { float.compare(a.value, b.value) })
  |> list.reverse
}

pub fn effective_for(
  pressures: List(memory.Pressure),
  from: String,
  to: String,
  now: Int,
  half_life_days: Float,
) -> Float {
  effective_pressures(pressures, now, half_life_days)
  |> list.find(fn(item) { item.from == from && item.to == to })
  |> result.map(fn(item) { item.value })
  |> result.unwrap(0.0)
}

pub fn above_threshold(
  pressures: List(memory.Pressure),
  now: Int,
  drift: config.DriftConfig,
) -> Option(EffectivePressure) {
  case
    effective_pressures(pressures, now, drift.half_life_days)
    |> list.find(fn(item) { item.value >=. drift.threshold })
  {
    Ok(item) -> Some(item)
    Error(_) -> None
  }
}

pub fn eligible_at(
  born_at: Int,
  last_change_at: Int,
  now: Int,
  drift: config.DriftConfig,
) -> Bool {
  let baseline = int.max(born_at, last_change_at)
  now - baseline >= drift.min_interval_days * day_ms
}

pub fn coherent(
  traits: List(String),
  from: String,
  to: String,
  constellation: constellation.Constellation,
) -> Bool {
  let proposed =
    traits
    |> list.map(fn(id) {
      case id == from {
        True -> to
        False -> id
      }
    })
  sampler.coherence(constellation, proposed)
  >=. constellation.coherence_threshold
  && !sampler.has_absolute_incompatibility(constellation, proposed)
}

pub fn maybe_apply(
  data_dir: String,
  principal: String,
  llm_config: provider.ProviderConfig,
  now: Int,
) -> Result(Bool, String) {
  let drift_config = case closed_group_global.get_config() {
    Some(cfg) -> cfg.drift
    None -> config.default_drift_config()
  }
  use core <- result.try(case self_core.load(data_dir, principal) {
    Some(core) -> Ok(core)
    None -> Error("missing core")
  })
  use constellation <- result.try(
    constellation.load(self_core.constellation_path()),
  )
  let pressures = memory.pressures(data_dir, principal)
  let live_pressures =
    pressures
    |> list.filter(fn(item) {
      list.contains(core.traits, item.from)
      && !list.contains(core.traits, item.to)
    })
  case above_threshold(live_pressures, now, drift_config) {
    None -> Ok(False)
    Some(candidate) -> {
      let last_change = self_core.last_drift_at(data_dir, principal)
      case eligible_at(core.born_at, last_change, now, drift_config) {
        False -> Ok(False)
        True ->
          case
            coherent(core.traits, candidate.from, candidate.to, constellation)
          {
            False -> Ok(False)
            True ->
              apply_candidate(
                data_dir,
                principal,
                core,
                constellation,
                candidate,
                pressures,
                llm_config,
                now,
              )
          }
      }
    }
  }
}

fn apply_candidate(
  data_dir: String,
  principal: String,
  core: self_core.Core,
  constellation: constellation.Constellation,
  candidate: EffectivePressure,
  pressures: List(memory.Pressure),
  llm_config: provider.ProviderConfig,
  now: Int,
) -> Result(Bool, String) {
  use template <- result.try(case read_file(prompt_path) {
    Ok(text) -> Ok(text)
    Error(_) -> {
      audit.record(
        principal,
        "drift_unavailable",
        prompt_path,
        audit_types.AuditFailure,
        "missing prompt",
      )
      Error("drift prompt unavailable")
    }
  })
  let reasons =
    pressures
    |> list.filter(fn(item) {
      item.from == candidate.from && item.to == candidate.to
    })
    |> list.map(fn(item) { "- " <> item.reason })
    |> string.join("\n")
  let prompt =
    prompt_template.render(template, [
      #("core", case self_core.read_prose(data_dir, principal) {
        Some(text) -> text
        None -> ""
      }),
      #("addenda", memory.addenda(data_dir, principal)),
      #("from", describe(constellation, candidate.from)),
      #("to", describe(constellation, candidate.to)),
      #("reasons", reasons),
    ])
  let messages = [
    provider.system_message(prompt),
    provider.user_message("Escreva o parágrafo agora."),
  ]
  use runtime <- result.try(case closed_group_global.get_runtime() {
    None -> {
      audit.record(
        principal,
        "drift_denied",
        "ledger",
        audit_types.AuditDenied,
        "runtime unavailable",
      )
      Error("runtime unavailable")
    }
    Some(runtime) -> Ok(runtime)
  })
  let context =
    closed_runtime.run_context(
      runtime,
      closed_types.PrincipalContext(principal_id: principal, role: "member"),
    )
  let run_context =
    executor.RunContext(
      ..context,
      call_id_override: Some("drift:" <> principal <> ":" <> int.to_string(now)),
    )
  case executor.run_with_context(messages, llm_config, [], run_context) {
    Error(executor.PolicyDenied(reason)) -> {
      audit.record(
        principal,
        "drift_denied",
        "ledger",
        audit_types.AuditDenied,
        reason,
      )
      Error(reason)
    }
    Error(_) -> {
      audit.record(
        principal,
        "drift_failed",
        "llm",
        audit_types.AuditFailure,
        "llm error",
      )
      Error("llm error")
    }
    Ok(response) -> {
      let addendum = string.trim(response.content)
      case string.length(addendum) {
        0 -> Error("empty addendum")
        _ -> {
          let proposed_traits =
            core.traits
            |> list.map(fn(id) {
              case id == candidate.from {
                True -> candidate.to
                False -> id
              }
            })
          use _ <- result.try(memory.append_addendum(
            data_dir,
            principal,
            addendum,
          ))
          use _ <- result.try(self_core.save(
            data_dir,
            principal,
            self_core.Core(..core, traits: proposed_traits),
          ))
          let entry =
            json.to_string(
              json.object([
                #("at", json.int(now)),
                #("kind", json.string("drift")),
                #("from", json.string(candidate.from)),
                #("to", json.string(candidate.to)),
                #("reason", json.string(addendum)),
              ]),
            )
          use _ <- result.try(self_core.append_biography_entry(
            data_dir,
            principal,
            entry,
          ))
          let remaining =
            pressures
            |> list.filter(fn(item) {
              !{ item.from == candidate.from && item.to == candidate.to }
            })
          let _ = memory.replace_pressures(data_dir, principal, remaining)
          audit.record(
            principal,
            "drift",
            principal,
            audit_types.AuditSuccess,
            candidate.from <> "->" <> candidate.to,
          )
          Ok(True)
        }
      }
    }
  }
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

fn describe(constellation: constellation.Constellation, id: String) -> String {
  case list.find(constellation.traits, fn(trait) { trait.id == id }) {
    Ok(trait) -> id <> " — " <> trait.description
    Error(_) -> id
  }
}
