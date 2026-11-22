//// Global failover cooldown registry.
////
//// Provides a persistent_term backed global reference to the cooldown actor.

import gleam/erlang/process.{type Subject}
import gleam/option
import gleam/otp/actor

import supernova/llm/failover_cooldown/actor as cd_actor
import supernova/llm/failover_cooldown/types as cd_types

pub type CooldownActor =
  Subject(cd_actor.CooldownCommand)

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: any) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn global_get(key: String) -> any

@external(erlang, "supernova_global_ffi", "global_has")
fn global_has(key: String) -> Bool

const cd_key = "supernova_global_cooldown"

pub fn set_cooldown(cd: CooldownActor) -> Nil {
  global_put(cd_key, cd)
}

pub fn get_cooldown() -> option.Option(CooldownActor) {
  case global_has(cd_key) {
    True -> {
      let cd = global_get(cd_key)
      case subject_alive(cd) {
        True -> option.Some(cd)
        False -> option.None
      }
    }
    False -> option.None
  }
}

pub fn check_cooldown(provider: String) -> cd_types.InCooldown {
  case get_cooldown() {
    option.Some(cd) ->
      actor.call(cd, waiting: 5000, sending: cd_actor.CheckCooldown(provider, _))
    option.None -> cd_types.NotInCooldown
  }
}

pub fn record_failure(provider: String) {
  case get_cooldown() {
    option.Some(cd) -> {
      process.send(cd, cd_actor.RecordFailure(provider, process.new_subject()))
      Nil
    }
    option.None -> Nil
  }
}

pub fn record_success(provider: String) {
  case get_cooldown() {
    option.Some(cd) -> {
      process.send(cd, cd_actor.RecordSuccess(provider, process.new_subject()))
      Nil
    }
    option.None -> Nil
  }
}

/// A global holds a `Subject`, not a pid: ask its owner process whether it
/// is alive. (`erlang:is_process_alive` on a Subject raises, which made every
/// lookup report the actor as missing.)
fn subject_alive(subject: process.Subject(message)) -> Bool {
  case process.subject_owner(subject) {
    Ok(pid) -> process.is_alive(pid)
    Error(_) -> False
  }
}
