//// Failover cooldown types — per-provider exponential backoff.
////
//// Tracks failure count and cooldown end time per provider.
//// Cooldown: 30s → 60s → 120s → max 300s (5min), cleared on success.

pub const default_initial_cooldown_ms: Int = 30_000

pub const default_max_cooldown_ms: Int = 300_000

pub type ProviderCooldown {
  ProviderCooldown(failure_count: Int, cooldown_end_ms: Int)
}

pub type FailoverCooldownConfig {
  FailoverCooldownConfig(initial_cooldown_ms: Int, max_cooldown_ms: Int)
}

pub fn default_config() -> FailoverCooldownConfig {
  FailoverCooldownConfig(
    initial_cooldown_ms: default_initial_cooldown_ms,
    max_cooldown_ms: default_max_cooldown_ms,
  )
}

pub type InCooldown {
  InCooldown(provider_name: String, remaining_ms: Int)
  NotInCooldown
}

pub type FailoverCooldownState {
  FailoverCooldownState(providers: List(#(String, ProviderCooldown)))
}

pub fn empty() -> FailoverCooldownState {
  FailoverCooldownState(providers: [])
}
