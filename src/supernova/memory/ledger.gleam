//// The memory's cost in the resource ledger (docs/prd/PRD-M-memoria.md,
//// 6.7). Its calls go in as LLM usage of provider "gemini", so they count
//// in the day's spend like any model call, and the day's cap turns the
//// memory off. Wired at boot into the memory settings.

import gleam/int
import gleam/list
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/memory/decision

pub const provider = "gemini"

pub const embed_model = "gemini-embedding-2"

/// Record Decision and embedding tokens for `principal`.
pub fn charge(
  ledger: ledger_actor.ResourceLedger,
  principal: String,
  decision_tokens: Int,
  embed_tokens: Int,
) -> Nil {
  [
    #(decision.model, decision_tokens, decision.decision_usd_per_million),
    #(embed_model, embed_tokens, decision.embed_usd_per_million),
  ]
  |> list.filter(fn(item) { item.1 > 0 })
  |> list.each(fn(item) {
    let #(model, tokens, usd_per_million) = item
    ledger_actor.record_llm_usage(
      ledger,
      principal,
      provider,
      model,
      tokens,
      0,
      int.to_float(tokens) *. usd_per_million /. 1_000_000.0,
    )
  })
}

/// Whether the day's spend is still under `daily_usd`. A ledger that does
/// not answer leaves the memory on: the turn's own LLM admission still
/// guards the cap.
pub fn within_budget(
  ledger: ledger_actor.ResourceLedger,
  daily_usd: Float,
  now: Int,
) -> Bool {
  case ledger_actor.try_spend_today(ledger, now) {
    Ok(#(_, spent)) -> spent <. daily_usd
    Error(Nil) -> True
  }
}
