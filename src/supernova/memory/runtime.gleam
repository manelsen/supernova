//// The memory settings, published once at boot when `conversation.recall`
//// is on (docs/prd/PRD-M-memoria.md). The `lembrar` tool, called through
//// the syscall gateway, and the gate, in the turn, read them here.

import gleam/option.{type Option, None, Some}
import supernova/memory/decision

pub type Settings {
  Settings(
    transport: decision.Transport,
    /// Provider, key and models.
    endpoint: decision.Endpoint,
    /// Cutoffs measured for that provider: probabilities are not on the same
    /// scale from one model to another.
    thresholds: Thresholds,
    gate_timeout_ms: Int,
    recall_timeout_ms: Int,
    /// Admit a paid call for `principal`, estimated at this many input
    /// tokens, before making it (the ledger, wired at boot). Refused past the
    /// day's cap or without a ledger (fail closed): the gate and `lembrar`
    /// stand aside and `buscar_conversa` remains. Admitted, it gives the
    /// function that settles the call with its decision and embedding
    /// tokens; settling with nothing spent releases the reservation.
    admit: fn(String, Int) -> Result(Settle, Nil),
  )
}

/// Cutoffs of the gate and of `lembrar`'s tone.
pub type Thresholds {
  Thresholds(
    /// The gate fires at this probability or more.
    gate: Float,
    /// Below this general probability: "acho que não".
    unlikely_below: Float,
    /// From this general probability: confident.
    likely_from: Float,
    /// Excerpts shown from this probability.
    shown_from: Float,
  )
}

/// The cutoffs measured on the bench and on LongMemEval for each provider
/// (docs/relatorios/BUSCA-bancada.md).
pub fn default_thresholds(provider: decision.Provider) -> Thresholds {
  case provider {
    // Gate: four-way choice, 20/20 and 0/40 on unseen messages. Tone: 2/60
    // answerable questions below 0.05, none of 30 abstentions from 0.6.
    decision.Perplexity ->
      Thresholds(
        gate: 0.25,
        unlikely_below: 0.05,
        likely_from: 0.6,
        shown_from: 0.1,
      )
    decision.Gemini ->
      Thresholds(
        gate: 0.1,
        unlikely_below: 0.2,
        likely_from: 0.75,
        shown_from: 0.2,
      )
  }
}

/// Settles an admitted call: decision tokens, embedding tokens.
pub type Settle =
  fn(Int, Int) -> Nil

/// Admits every call and records nothing (tests, the bench).
pub fn no_ledger(_principal: String, _estimate: Int) -> Result(Settle, Nil) {
  Ok(fn(_decision, _embed) { Nil })
}

/// Refuses every call (past the cap).
pub fn refuse(_principal: String, _estimate: Int) -> Result(Settle, Nil) {
  Error(Nil)
}

const key = "supernova_memory_settings"

pub fn configure(settings: Settings) -> Nil {
  global_put(key, settings)
}

/// Memory off: no gate, no `lembrar`.
pub fn clear() -> Nil {
  global_erase(key)
}

pub fn get() -> Option(Settings) {
  case global_has(key) {
    True -> Some(global_get(key))
    False -> None
  }
}

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: a) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn global_get(key: String) -> a

@external(erlang, "supernova_global_ffi", "global_has")
fn global_has(key: String) -> Bool

@external(erlang, "supernova_global_ffi", "global_erase")
fn global_erase(key: String) -> Nil
