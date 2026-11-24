//// The memory as the boot sets it up (docs/prd/PRD-M-memoria.md): the
//// settings from `conversation.recall`, the real transport, and the
//// ledger the closed group publishes.

import gleam/option.{type Option, None, Some}
import supernova/config
import supernova/core/closed_group/global as closed_group_global
import supernova/memory/decision
import supernova/memory/ledger
import supernova/memory/runtime

/// The settings when the memory is on; None when off or without a key (the
/// boot refuses that before getting here).
pub fn settings(
  cfg: config.Config,
  transport: decision.Transport,
  _now: fn() -> Int,
) -> Option(runtime.Settings) {
  let recall = cfg.conversation.recall
  case recall.enabled, recall.api_key {
    True, Some(key) -> {
      let provider = case recall.provider {
        "gemini" -> decision.Gemini
        _ -> decision.Perplexity
      }
      let endpoint = decision.endpoint(provider, key)
      let defaults = runtime.default_thresholds(provider)
      Some(runtime.Settings(
        transport: transport,
        endpoint: endpoint,
        thresholds: runtime.Thresholds(
          gate: option.unwrap(recall.gate_threshold, defaults.gate),
          unlikely_below: option.unwrap(
            recall.unlikely_below,
            defaults.unlikely_below,
          ),
          likely_from: option.unwrap(recall.likely_from, defaults.likely_from),
          shown_from: defaults.shown_from,
        ),
        gate_timeout_ms: recall.gate_timeout_ms,
        recall_timeout_ms: recall.recall_timeout_ms,
        // Fail closed: without a ledger to admit the call, no paid call.
        admit: fn(principal, estimate) {
          case closed_group_global.get_ledger() {
            None -> Error(Nil)
            Some(book) ->
              ledger.admit(
                book,
                endpoint,
                principal,
                cfg.instance_budget.daily_usd,
                estimate,
              )
          }
        },
      ))
    }
    _, _ -> None
  }
}

/// Publish the settings, or turn the memory off. True when on.
pub fn publish(cfg: config.Config) -> Bool {
  case settings(cfg, decision.hackney_transport(), now_ms) {
    Some(s) -> {
      runtime.configure(s)
      True
    }
    None -> {
      runtime.clear()
      False
    }
  }
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int
