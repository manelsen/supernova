//// The agent's process: the one writer of an agent's state.
////
//// The end of every turn, /model, /reasoning, the reflection and /esquecer
//// all change `self_state` and the relationship. They used to read the file,
//// change it and write it back, each in its own process: two at once could
//// lose one of the writes. Now every change is a function sent to the
//// agent's process, which applies it to the current state and writes it, one
//// change at a time. Reads do not go through the process: it publishes what
//// it wrote in an ETS table, and readers look there first.
////
//// One process per agent (per data_dir and principal), started on first use
//// under the desk supervisor, which traps exits: a desk that dies is
//// forgotten and started again on the next change, from the disk. A desk
//// with no change for 30 minutes stops. With no supervisor running (tests
//// that do not boot Supernova), changes are applied directly, as before.
////
//// PRD-P, P-02.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import supernova/core/agent_identity
import supernova/core/introspection/relationship.{type RelationshipState}
import supernova/core/introspection/self_state.{type SelfState}
import supernova/infra/safe_io

// ============================================================================
// The agent's process
// ============================================================================

pub opaque type DeskMessage {
  ModifySelf(reply: Subject(SelfState), change: fn(SelfState) -> SelfState)
  ModifyRelationship(
    reply: Subject(#(RelationshipState, RelationshipState)),
    user_id: String,
    change: fn(RelationshipState) -> RelationshipState,
  )
  Reset(reply: Subject(Result(Nil, String)), work: fn() -> Result(Nil, String))
  Tick
}

type Desk =
  Subject(DeskMessage)

type DeskState {
  DeskState(
    data_dir: String,
    principal: String,
    current: Option(SelfState),
    relationships: Dict(String, RelationshipState),
    last_touch: Int,
    me: Desk,
  )
}

/// A desk with no change for this long stops; the next change starts it.
const idle_ms = 1_800_000

const tick_ms = 300_000

fn start_desk(
  data_dir: String,
  principal: String,
) -> Result(Desk, actor.StartError) {
  actor.new_with_initialiser(5000, fn(me) {
    process.send_after(me, tick_ms, Tick)
    actor.initialised(DeskState(
      data_dir: data_dir,
      principal: principal,
      current: None,
      relationships: dict.new(),
      last_touch: now_ms(),
      me: me,
    ))
    |> actor.returning(me)
    |> Ok
  })
  |> actor.on_message(handle_desk)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn handle_desk(
  state: DeskState,
  message: DeskMessage,
) -> actor.Next(DeskState, DeskMessage) {
  let dir = agent_identity.self_dir(state.data_dir, state.principal)
  case message {
    ModifySelf(reply, change) -> {
      let current = case state.current {
        Some(known) -> known
        None -> self_state.from_dir(dir)
      }
      let next = change(current)
      log_failure(self_state.save_in(dir, next), state.principal, "self_state")
      view_put(self_key(state.data_dir, state.principal), next)
      actor.send(reply, next)
      actor.continue(
        DeskState(..state, current: Some(next), last_touch: now_ms()),
      )
    }
    ModifyRelationship(reply, user_id, change) -> {
      let current = case dict.get(state.relationships, user_id) {
        Ok(known) -> known
        Error(Nil) -> relationship.load_in(dir, user_id)
      }
      let next = change(current)
      log_failure(
        relationship.save_in(dir, next),
        state.principal,
        "relationship",
      )
      view_put(relationship_key(state.data_dir, state.principal, user_id), next)
      actor.send(reply, #(current, next))
      actor.continue(
        DeskState(
          ..state,
          relationships: dict.insert(state.relationships, user_id, next),
          last_touch: now_ms(),
        ),
      )
    }
    Reset(reply, work) -> {
      let done = work()
      view_delete(self_key(state.data_dir, state.principal))
      dict.keys(state.relationships)
      |> list_each(fn(user_id) {
        view_delete(relationship_key(state.data_dir, state.principal, user_id))
      })
      actor.send(reply, done)
      actor.continue(
        DeskState(
          ..state,
          current: None,
          relationships: dict.new(),
          last_touch: now_ms(),
        ),
      )
    }
    Tick ->
      case now_ms() - state.last_touch > idle_ms {
        True -> actor.stop()
        False -> {
          process.send_after(state.me, tick_ms, Tick)
          actor.continue(state)
        }
      }
  }
}

fn log_failure(saved: Result(Nil, String), principal: String, what: String) {
  case saved {
    Ok(Nil) -> Nil
    Error(reason) ->
      safe_io.println(
        "warn: agent state not written agent="
        <> principal
        <> " file="
        <> what
        <> " error="
        <> reason,
      )
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Apply `change` to the agent's state and write it, one change at a time
/// per agent; the state as written.
pub fn modify_self(
  data_dir: String,
  principal: String,
  change: fn(SelfState) -> SelfState,
) -> SelfState {
  case desk_for(data_dir, principal) {
    Some(desk) ->
      actor.call(desk, waiting: 10_000, sending: ModifySelf(_, change))
    None -> {
      let dir = agent_identity.self_dir(data_dir, principal)
      let next = change(self_state.from_dir(dir))
      log_failure(self_state.save_in(dir, next), principal, "self_state")
      next
    }
  }
}

/// The agent's state: what its process last wrote, or the file.
pub fn read_self(data_dir: String, principal: String) -> SelfState {
  case view_get(self_key(data_dir, principal)) {
    Ok(state) -> state
    Error(Nil) ->
      self_state.from_dir(agent_identity.self_dir(data_dir, principal))
  }
}

/// Apply `change` to the agent's relationship with `user_id` and write it;
/// the relationship before and after.
pub fn modify_relationship(
  data_dir: String,
  principal: String,
  user_id: String,
  change: fn(RelationshipState) -> RelationshipState,
) -> #(RelationshipState, RelationshipState) {
  case desk_for(data_dir, principal) {
    Some(desk) ->
      actor.call(desk, waiting: 10_000, sending: ModifyRelationship(
        _,
        user_id,
        change,
      ))
    None -> {
      let dir = agent_identity.self_dir(data_dir, principal)
      let current = relationship.load_in(dir, user_id)
      let next = change(current)
      log_failure(relationship.save_in(dir, next), principal, "relationship")
      #(current, next)
    }
  }
}

/// The agent's relationship with `user_id`: what its process last wrote, or
/// the file.
pub fn read_relationship(
  data_dir: String,
  principal: String,
  user_id: String,
) -> RelationshipState {
  case view_get(relationship_key(data_dir, principal, user_id)) {
    Ok(state) -> state
    Error(Nil) ->
      relationship.load_in(
        agent_identity.self_dir(data_dir, principal),
        user_id,
      )
  }
}

/// Run `work` in the agent's process, with no change of its state in
/// between, then forget what the process keeps in memory: the next change
/// reads the files again. For work that rewrites the state files on disk
/// (/esquecer).
pub fn reset(
  data_dir: String,
  principal: String,
  work: fn() -> Result(Nil, String),
) -> Result(Nil, String) {
  case desk_for(data_dir, principal) {
    Some(desk) -> actor.call(desk, waiting: 30_000, sending: Reset(_, work))
    None -> work()
  }
}

// ============================================================================
// Supervisor
// ============================================================================

pub opaque type SupervisorMessage {
  Start(reply: Subject(Result(Desk, Nil)), data_dir: String, principal: String)
  Exited(process.ExitMessage)
  StopAll(reply: Subject(Nil))
}

pub type DeskSupervisor =
  Subject(SupervisorMessage)

type SupervisorState {
  SupervisorState(desks: Dict(Pid, #(String, String)))
}

/// Start the desk supervisor and publish it; changes then go through the
/// agents' processes.
pub fn start_supervisor() -> Result(DeskSupervisor, actor.StartError) {
  actor.new_with_initialiser(5000, fn(me) {
    process.trap_exits(True)
    let selector =
      process.new_selector()
      |> process.select(me)
      |> process.select_trapped_exits(Exited)
    actor.initialised(SupervisorState(desks: dict.new()))
    |> actor.selecting(selector)
    |> actor.returning(me)
    |> Ok
  })
  |> actor.on_message(handle_supervisor)
  |> actor.start
  |> result.map(fn(started) {
    global_put(supervisor_key, started.data)
    started.data
  })
}

/// Stop every desk and the supervisor; changes go direct again.
pub fn stop_supervisor(supervisor: DeskSupervisor) -> Nil {
  global_erase(supervisor_key)
  let _ = actor.call(supervisor, waiting: 10_000, sending: StopAll)
  Nil
}

fn handle_supervisor(
  state: SupervisorState,
  message: SupervisorMessage,
) -> actor.Next(SupervisorState, SupervisorMessage) {
  case message {
    Start(reply, data_dir, principal) ->
      case registered(data_dir, principal) {
        Some(desk) -> {
          actor.send(reply, Ok(desk))
          actor.continue(state)
        }
        None ->
          case start_desk(data_dir, principal) {
            Ok(desk) -> {
              table_put(desks_table, #(data_dir, principal), desk)
              actor.send(reply, Ok(desk))
              case process.subject_owner(desk) {
                Ok(pid) ->
                  actor.continue(
                    SupervisorState(
                      desks: dict.insert(state.desks, pid, #(
                        data_dir,
                        principal,
                      )),
                    ),
                  )
                Error(Nil) -> actor.continue(state)
              }
            }
            Error(_) -> {
              actor.send(reply, Error(Nil))
              actor.continue(state)
            }
          }
      }
    Exited(process.ExitMessage(pid, reason)) ->
      case dict.get(state.desks, pid), reason {
        Ok(key), _ -> {
          table_delete(desks_table, key)
          case reason {
            process.Normal -> Nil
            _ ->
              safe_io.println(
                "warn: agent process exited agent="
                <> key.1
                <> " reason="
                <> string.inspect(reason),
              )
          }
          actor.continue(SupervisorState(desks: dict.delete(state.desks, pid)))
        }
        // Not a desk: the process that started the supervisor.
        Error(Nil), process.Normal -> actor.continue(state)
        Error(Nil), _ -> actor.stop_abnormal("parent exited")
      }
    StopAll(reply) -> {
      dict.to_list(state.desks)
      |> list_each(fn(pair) {
        let #(pid, key) = pair
        table_delete(desks_table, key)
        process.kill(pid)
      })
      actor.send(reply, Nil)
      actor.stop()
    }
  }
}

fn list_each(items: List(a), f: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [item, ..rest] -> {
      f(item)
      list_each(rest, f)
    }
  }
}

/// The agent's desk, started if there is a supervisor; None without one.
fn desk_for(data_dir: String, principal: String) -> Option(Desk) {
  case registered(data_dir, principal) {
    Some(desk) -> Some(desk)
    None ->
      case global_lookup(supervisor_key) {
        Error(Nil) -> None
        Ok(supervisor) ->
          case
            actor.call(supervisor, waiting: 10_000, sending: Start(
              _,
              data_dir,
              principal,
            ))
          {
            Ok(desk) -> Some(desk)
            Error(Nil) -> None
          }
      }
  }
}

fn registered(data_dir: String, principal: String) -> Option(Desk) {
  case table_get(desks_table, #(data_dir, principal)) {
    Ok(desk) ->
      case process.subject_owner(desk) {
        Ok(pid) ->
          case process.is_alive(pid) {
            True -> Some(desk)
            False -> None
          }
        Error(Nil) -> None
      }
    Error(Nil) -> None
  }
}

// ============================================================================
// Tables
// ============================================================================

const supervisor_key = "supernova_desk_supervisor"

type Table {
  SupernovaDesks
  SupernovaAgentView
}

const desks_table = SupernovaDesks

const view_table = SupernovaAgentView

fn self_key(data_dir: String, principal: String) -> #(String, String, String) {
  #("self", data_dir, principal)
}

fn relationship_key(
  data_dir: String,
  principal: String,
  user_id: String,
) -> #(String, String, String) {
  #(data_dir, principal, "relationship:" <> user_id)
}

fn view_put(key: k, value: v) -> Nil {
  table_put(view_table, key, value)
}

fn view_get(key: k) -> Result(v, Nil) {
  table_get(view_table, key)
}

fn view_delete(key: k) -> Nil {
  table_delete(view_table, key)
}

@external(erlang, "supernova_table_ffi", "get")
fn table_get(table: Table, key: k) -> Result(v, Nil)

@external(erlang, "supernova_table_ffi", "put")
fn table_put(table: Table, key: k, value: v) -> Nil

@external(erlang, "supernova_table_ffi", "delete")
fn table_delete(table: Table, key: k) -> Nil

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: DeskSupervisor) -> Nil

@external(erlang, "supernova_global_ffi", "global_lookup")
fn global_lookup(key: String) -> Result(DeskSupervisor, Nil)

@external(erlang, "supernova_global_ffi", "global_erase")
fn global_erase(key: String) -> Nil

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

/// Kill the agent's process and wait until it is gone (tests of a restart).
pub fn kill_for_test(data_dir: String, principal: String) -> Nil {
  case registered(data_dir, principal) {
    Some(desk) ->
      case process.subject_owner(desk) {
        Ok(pid) -> {
          let monitor = process.monitor(pid)
          process.kill(pid)
          let _ =
            process.new_selector()
            |> process.select_specific_monitor(monitor, fn(_) { Nil })
            |> process.selector_receive(5000)
          Nil
        }
        Error(Nil) -> Nil
      }
    None -> Nil
  }
}
