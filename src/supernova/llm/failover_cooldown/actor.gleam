//// Failover cooldown actor — manages per-provider cooldown state.
////
//// Tracks failure counts and cooldown end times, providing an actor interface
//// for the failover system to check and update cooldown state.

import gleam/erlang/process
import gleam/otp/actor
import supernova/llm/failover_cooldown/pure as cd_pure
import supernova/llm/failover_cooldown/types as cd_types

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int

pub type CooldownCommand {
  CheckCooldown(
    provider_name: String,
    reply_to: process.Subject(cd_types.InCooldown),
  )
  RecordFailure(
    provider_name: String,
    reply_to: process.Subject(FailureRecorded),
  )
  RecordSuccess(
    provider_name: String,
    reply_to: process.Subject(SuccessRecorded),
  )
}

pub type FailureRecorded {
  FailureRecorded(cooldown_state: cd_types.FailoverCooldownState)
}

pub type SuccessRecorded {
  SuccessRecorded(cooldown_state: cd_types.FailoverCooldownState)
}

pub type State {
  State(
    cooldown: cd_types.FailoverCooldownState,
    config: cd_types.FailoverCooldownConfig,
  )
}

pub fn start(
  config: cd_types.FailoverCooldownConfig,
) -> Result(process.Subject(CooldownCommand), actor.StartError) {
  let initial_state = State(cooldown: cd_types.empty(), config: config)
  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

fn handle_message(
  state: State,
  message: CooldownCommand,
) -> actor.Next(State, CooldownCommand) {
  case message {
    CheckCooldown(provider_name, reply_to) -> {
      let now = current_timestamp()
      let result =
        cd_pure.check_cooldown(state.cooldown, provider_name, state.config, now)
      process.send(reply_to, result)
      actor.continue(state)
    }
    RecordFailure(provider_name, reply_to) -> {
      let now = current_timestamp()
      let new_cooldown =
        cd_pure.record_failure(state.cooldown, provider_name, state.config, now)
      process.send(reply_to, FailureRecorded(new_cooldown))
      actor.continue(State(cooldown: new_cooldown, config: state.config))
    }
    RecordSuccess(provider_name, reply_to) -> {
      let new_cooldown = cd_pure.record_success(state.cooldown, provider_name)
      process.send(reply_to, SuccessRecorded(new_cooldown))
      actor.continue(State(cooldown: new_cooldown, config: state.config))
    }
  }
}
