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
  now: fn() -> Int,
) -> Option(runtime.Settings) {
  let recall = cfg.conversation.recall
  case recall.enabled, recall.api_key {
    True, Some(key) ->
      Some(
        runtime.Settings(
          transport: transport,
          api_key: key,
          gate_threshold: recall.gate_threshold,
          gate_timeout_ms: recall.gate_timeout_ms,
          recall_timeout_ms: recall.recall_timeout_ms,
          charge: charge,
          within_budget: fn() {
            case closed_group_global.get_ledger() {
              None -> True
              Some(book) ->
                ledger.within_budget(book, cfg.instance_budget.daily_usd, now())
            }
          },
        ),
      )
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

fn charge(principal: String, decision_tokens: Int, embed_tokens: Int) -> Nil {
  case closed_group_global.get_ledger() {
    None -> Nil
    Some(book) -> ledger.charge(book, principal, decision_tokens, embed_tokens)
  }
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int
