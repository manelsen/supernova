//// The memory settings, published once at boot when `conversation.recall`
//// is on (docs/prd/PRD-M-memoria.md). The `lembrar` tool, called through
//// the syscall gateway, and the gate, in the turn, read them here.

import gleam/option.{type Option, None, Some}
import supernova/memory/decision

pub type Settings {
  Settings(
    transport: decision.Transport,
    api_key: String,
    gate_threshold: Float,
    gate_timeout_ms: Int,
    recall_timeout_ms: Int,
    /// Record a call's cost for `principal`: Decision tokens and embedding
    /// tokens (the ledger, wired at boot).
    charge: fn(String, Int, Int) -> Nil,
    /// Whether the day's spend still allows the memory; past the cap the
    /// gate and `lembrar` stand aside and `buscar_conversa` remains.
    within_budget: fn() -> Bool,
  )
}

/// No ledger: nothing recorded, always within budget (tests, the bench).
pub fn no_charge(_principal: String, _decision: Int, _embed: Int) -> Nil {
  Nil
}

pub fn always_within() -> Bool {
  True
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
