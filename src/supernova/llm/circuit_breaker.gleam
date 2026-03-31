//// Circuit breaker for LLM provider calls.
////
//// States: Closed (normal) -> Open (failing) -> HalfOpen (testing)

pub type CircuitBreaker {
  CircuitBreaker(
    name: String,
    state: CircuitState,
    failure_count: Int,
    success_count: Int,
    last_failure_time_ms: Int,
    cooldown_ms: Int,
  )
}

pub type CircuitState {
  CircuitClosed
  CircuitOpen
  CircuitHalfOpen
}

pub type CircuitConfig {
  CircuitConfig(
    failure_threshold: Int,
    recovery_timeout_ms: Int,
    half_open_max_calls: Int,
  )
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int

pub fn new(name: String, config: CircuitConfig) -> CircuitBreaker {
  CircuitBreaker(
    name: name,
    state: CircuitClosed,
    failure_count: 0,
    success_count: 0,
    last_failure_time_ms: 0,
    cooldown_ms: config.recovery_timeout_ms,
  )
}

pub fn is_call_allowed(breaker: CircuitBreaker, config: CircuitConfig) -> Bool {
  let now = current_timestamp()
  case breaker.state {
    CircuitClosed -> True
    CircuitOpen -> {
      case now - breaker.last_failure_time_ms >= config.recovery_timeout_ms {
        True -> {
          let new_breaker =
            CircuitBreaker(
              name: breaker.name,
              state: CircuitHalfOpen,
              failure_count: 0,
              success_count: 0,
              last_failure_time_ms: breaker.last_failure_time_ms,
              cooldown_ms: breaker.cooldown_ms,
            )
          new_breaker.state == CircuitHalfOpen
        }
        False -> False
      }
    }
    CircuitHalfOpen -> breaker.success_count < config.half_open_max_calls
  }
}

pub fn record_success(
  breaker: CircuitBreaker,
  config: CircuitConfig,
) -> CircuitBreaker {
  case breaker.state {
    CircuitClosed -> {
      CircuitBreaker(
        name: breaker.name,
        state: CircuitClosed,
        failure_count: 0,
        success_count: breaker.success_count + 1,
        last_failure_time_ms: breaker.last_failure_time_ms,
        cooldown_ms: breaker.cooldown_ms,
      )
    }
    CircuitHalfOpen -> {
      let new_success_count = breaker.success_count + 1
      case new_success_count >= config.half_open_max_calls {
        True -> {
          CircuitBreaker(
            name: breaker.name,
            state: CircuitClosed,
            failure_count: 0,
            success_count: 0,
            last_failure_time_ms: breaker.last_failure_time_ms,
            cooldown_ms: breaker.cooldown_ms,
          )
        }
        False -> {
          CircuitBreaker(
            name: breaker.name,
            state: CircuitHalfOpen,
            failure_count: 0,
            success_count: new_success_count,
            last_failure_time_ms: breaker.last_failure_time_ms,
            cooldown_ms: breaker.cooldown_ms,
          )
        }
      }
    }
    CircuitOpen -> breaker
  }
}

pub fn record_failure(
  breaker: CircuitBreaker,
  config: CircuitConfig,
) -> CircuitBreaker {
  let now = current_timestamp()
  let new_failure_count = breaker.failure_count + 1
  case breaker.state {
    CircuitClosed -> {
      case new_failure_count >= config.failure_threshold {
        True -> {
          CircuitBreaker(
            name: breaker.name,
            state: CircuitOpen,
            failure_count: new_failure_count,
            success_count: 0,
            last_failure_time_ms: now,
            cooldown_ms: breaker.cooldown_ms,
          )
        }
        False -> {
          CircuitBreaker(
            name: breaker.name,
            state: CircuitClosed,
            failure_count: new_failure_count,
            success_count: 0,
            last_failure_time_ms: now,
            cooldown_ms: breaker.cooldown_ms,
          )
        }
      }
    }
    CircuitHalfOpen -> {
      CircuitBreaker(
        name: breaker.name,
        state: CircuitOpen,
        failure_count: 1,
        success_count: 0,
        last_failure_time_ms: now,
        cooldown_ms: breaker.cooldown_ms,
      )
    }
    CircuitOpen -> breaker
  }
}

pub fn state_name(state: CircuitState) -> String {
  case state {
    CircuitClosed -> "closed"
    CircuitOpen -> "open"
    CircuitHalfOpen -> "half_open"
  }
}
