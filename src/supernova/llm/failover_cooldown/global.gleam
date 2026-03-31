//// Global failover cooldown registry.
////
//// Provides a process-dictionary backed global reference to the cooldown actor.

import gleam/erlang/process.{type Subject}
import gleam/option
import gleam/otp/actor

import supernova/llm/failover_cooldown/actor as cd_actor
import supernova/llm/failover_cooldown/types as cd_types

pub type CooldownActor =
  Subject(cd_actor.CooldownCommand)

@external(erlang, "erlang", "put")
fn erlang_put(key: String, value: any) -> any

@external(erlang, "erlang", "get")
fn erlang_get(key: String) -> any

@external(erlang, "erlang", "is_process_alive")
fn is_process_alive(pid: any) -> Bool

const cd_key = "supernova_global_cooldown"

const cd_marker = "supernova_cd_active"

pub fn set_cooldown(cd: CooldownActor) -> Nil {
  erlang_put(cd_key, cd)
  erlang_put(cd_marker, True)
  Nil
}

pub fn get_cooldown() -> option.Option(CooldownActor) {
  let marker = erlang_get(cd_marker)
  case marker {
    True -> {
      let cd = erlang_get(cd_key)
      case is_process_alive(cd) {
        True -> option.Some(cd)
        False -> option.None
      }
    }
    _ -> option.None
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
