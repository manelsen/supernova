//// The memory's cost in the resource ledger (docs/prd/PRD-M-memoria.md,
//// 6.7). Its calls go in as LLM usage of the decision provider
//// ("perplexity" or "gemini"), so they count in the day's spend like any
//// model call, and the day's cap turns the memory off. Wired at boot into
//// the memory settings.

import gleam/int
import gleam/list
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/memory/decision

/// Record decision and embedding tokens for `principal`.
pub fn charge(
  ledger: ledger_actor.ResourceLedger,
  endpoint: decision.Endpoint,
  principal: String,
  decision_tokens: Int,
  embed_tokens: Int,
) -> Nil {
  let provider = endpoint.provider
  [
    #(
      endpoint.decision_model,
      decision_tokens,
      decision.decision_usd_per_million(provider),
    ),
    #(
      endpoint.embed_model,
      embed_tokens,
      decision.embed_usd_per_million(provider),
    ),
  ]
  |> list.filter(fn(item) { item.1 > 0 })
  |> list.each(fn(item) {
    let #(model, tokens, usd_per_million) = item
    ledger_actor.record_llm_usage(
      ledger,
      principal,
      decision.provider_name(provider),
      model,
      tokens,
      0,
      int.to_float(tokens) *. usd_per_million /. 1_000_000.0,
    )
  })
}

/// Admit a paid call for `principal`, estimated at `estimate_tokens` of
/// input, against the day's cap; the result settles it. Settling records the
/// decision tokens under the reservation and the embedding tokens apart, or
/// releases the reservation when nothing was spent.
pub fn admit(
  ledger: ledger_actor.ResourceLedger,
  endpoint: decision.Endpoint,
  principal: String,
  cap_usd: Float,
  estimate_tokens: Int,
) -> Result(fn(Int, Int) -> Nil, Nil) {
  let provider = endpoint.provider
  let call_id = "memory:" <> int.to_string(unique_integer())
  let estimate =
    int.to_float(estimate_tokens)
    *. decision.decision_usd_per_million(provider)
    /. 1_000_000.0
  case ledger_actor.admit_llm_call(ledger, call_id, cap_usd, estimate) {
    Error(_) -> Error(Nil)
    Ok(Nil) ->
      Ok(fn(decision_tokens: Int, embed_tokens: Int) {
        case decision_tokens > 0 {
          False -> ledger_actor.release_reservation(ledger, call_id)
          True -> {
            let _ =
              ledger_actor.try_record_llm_usage_with_call_id(
                ledger,
                principal,
                decision.provider_name(provider),
                endpoint.decision_model,
                decision_tokens,
                0,
                int.to_float(decision_tokens)
                  *. decision.decision_usd_per_million(provider)
                  /. 1_000_000.0,
                call_id,
              )
            Nil
          }
        }
        charge(ledger, endpoint, principal, 0, embed_tokens)
      })
  }
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int
