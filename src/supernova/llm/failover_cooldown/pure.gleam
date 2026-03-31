//// Failover cooldown — pure business logic.
////
//// Calculates exponential backoff and checks cooldown state.

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import supernova/llm/failover_cooldown/types as cd_types

pub fn cooldown_duration_ms(
  failure_count: Int,
  config: cd_types.FailoverCooldownConfig,
) -> Int {
  case failure_count {
    0 -> config.initial_cooldown_ms
    _ -> {
      let multiplier =
        int.power(2, int.to_float(failure_count))
        |> result.unwrap(1.0)
        |> float.round()
      let duration = config.initial_cooldown_ms * multiplier
      case duration > config.max_cooldown_ms {
        True -> config.max_cooldown_ms
        False -> duration
      }
    }
  }
}

pub fn check_cooldown(
  state: cd_types.FailoverCooldownState,
  provider_name: String,
  _config: cd_types.FailoverCooldownConfig,
  now: Int,
) -> cd_types.InCooldown {
  case list.key_find(state.providers, provider_name) {
    Ok(cooldown) -> {
      case now >= cooldown.cooldown_end_ms {
        True -> cd_types.NotInCooldown
        False ->
          cd_types.InCooldown(
            provider_name: provider_name,
            remaining_ms: cooldown.cooldown_end_ms - now,
          )
      }
    }
    Error(_) -> cd_types.NotInCooldown
  }
}

pub fn record_failure(
  state: cd_types.FailoverCooldownState,
  provider_name: String,
  config: cd_types.FailoverCooldownConfig,
  now: Int,
) -> cd_types.FailoverCooldownState {
  let current = case list.key_find(state.providers, provider_name) {
    Ok(cooldown) -> cooldown.failure_count
    Error(_) -> 0
  }
  let new_failure_count = current + 1
  let duration = cooldown_duration_ms(new_failure_count, config)
  let new_end = now + duration
  let new_cooldown =
    cd_types.ProviderCooldown(
      failure_count: new_failure_count,
      cooldown_end_ms: new_end,
    )
  cd_types.FailoverCooldownState(providers: list.key_set(
    state.providers,
    provider_name,
    new_cooldown,
  ))
}

pub fn record_success(
  state: cd_types.FailoverCooldownState,
  provider_name: String,
) -> cd_types.FailoverCooldownState {
  cd_types.FailoverCooldownState(
    providers: list.filter(state.providers, fn(entry) {
      entry.0 != provider_name
    }),
  )
}
