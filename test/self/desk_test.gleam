//// The agent's process (PRD-P, P-02): changes from many processes at once
//// are applied one at a time, and none is lost.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleeunit/should
import supernova/core/agent_identity
import supernova/core/introspection/relationship
import supernova/core/introspection/self_state
import supernova/self/desk
import test_workspace

const principal = "sim:ana"

fn with_desks(body: fn(String) -> a) -> a {
  test_workspace.with_isolated_workspace("desk", fn(root) {
    let data_dir = root <> "/data"
    let assert Ok(supervisor) = desk.start_supervisor()
    let result = body(data_dir)
    desk.stop_supervisor(supervisor)
    result
  })
}

/// Run `n` changes at once, each from its own process, and wait for all.
fn at_once(n: Int, change: fn(Int) -> Nil) -> Nil {
  let done = process.new_subject()
  int.range(1, n + 1, [], list.prepend)
  |> list.each(fn(i) {
    process.spawn(fn() {
      change(i)
      process.send(done, Nil)
    })
  })
  list.each(int.range(1, n + 1, [], list.prepend), fn(_) {
    let assert Ok(Nil) = process.receive(done, within: 30_000)
  })
}

/// Two hundred turns ending at once each count once in the relationship, on
/// disk and in what readers see.
pub fn concurrent_relationship_changes_are_all_kept_test() {
  use data_dir <- with_desks()
  at_once(200, fn(_) {
    let _ =
      desk.modify_relationship(data_dir, principal, "ana", fn(state) {
        relationship.apply_event(state, relationship.TurnSuccess)
      })
    Nil
  })
  desk.read_relationship(data_dir, principal, "ana").interaction_count
  |> should.equal(200)
  relationship.load_in(agent_identity.self_dir(data_dir, principal), "ana").interaction_count
  |> should.equal(200)
}

/// A hundred changes of the state at once (the end of turns, /model,
/// the reflection) all stay.
pub fn concurrent_self_changes_are_all_kept_test() {
  use data_dir <- with_desks()
  at_once(100, fn(_) {
    let _ =
      desk.modify_self(data_dir, principal, fn(state) {
        self_state.SelfState(
          ..state,
          last_reflection_at: state.last_reflection_at + 1,
        )
      })
    Nil
  })
  desk.read_self(data_dir, principal).last_reflection_at
  |> should.equal(100)
  self_state.from_dir(agent_identity.self_dir(data_dir, principal)).last_reflection_at
  |> should.equal(100)
}

/// The relationship before and after the change, as the process applied it.
pub fn modify_relationship_returns_before_and_after_test() {
  use data_dir <- with_desks()
  let #(before, after) =
    desk.modify_relationship(data_dir, principal, "ana", fn(state) {
      relationship.apply_event(state, relationship.TurnSuccess)
    })
  before.interaction_count |> should.equal(0)
  after.interaction_count |> should.equal(1)
}

/// A reset runs its work in the process and drops what it kept: the next
/// change starts from the files the work left.
pub fn reset_drops_what_the_process_kept_test() {
  use data_dir <- with_desks()
  let dir = agent_identity.self_dir(data_dir, principal)
  let _ =
    desk.modify_relationship(data_dir, principal, "ana", fn(state) {
      relationship.apply_event(state, relationship.TurnSuccess)
    })
  let assert Ok(Nil) =
    desk.reset(data_dir, principal, fn() {
      delete_file(relationship.relationship_path_in(dir))
    })
  desk.read_relationship(data_dir, principal, "ana").interaction_count
  |> should.equal(0)
  let #(_, after) =
    desk.modify_relationship(data_dir, principal, "ana", fn(state) {
      relationship.apply_event(state, relationship.TurnSuccess)
    })
  after.interaction_count |> should.equal(1)
}

/// A process that dies is started again on the next change, from the disk.
pub fn a_dead_desk_starts_again_from_disk_test() {
  use data_dir <- with_desks()
  let _ =
    desk.modify_self(data_dir, principal, fn(state) {
      self_state.SelfState(..state, concerns: ["antes"])
    })
  desk.kill_for_test(data_dir, principal)
  let after =
    desk.modify_self(data_dir, principal, fn(state) {
      self_state.SelfState(..state, concerns: ["depois", ..state.concerns])
    })
  after.concerns |> should.equal(["depois", "antes"])
}

/// Without the supervisor (code that runs outside Supernova), changes are
/// applied directly.
pub fn without_supervisor_changes_go_direct_test() {
  use root <- test_workspace.with_isolated_workspace("desk-direct")
  let data_dir = root <> "/data"
  let _ =
    desk.modify_self(data_dir, principal, fn(state) {
      self_state.SelfState(..state, concerns: ["direto"])
    })
  self_state.from_dir(agent_identity.self_dir(data_dir, principal)).concerns
  |> should.equal(["direto"])
}

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn delete_file(path: String) -> Result(Nil, String)
