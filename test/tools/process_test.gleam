//// Process tool tests

import gleam/erlang/process as beam_process
import gleam/int
import gleam/string
import gleeunit
import gleeunit/should
import supernova/core/workspace_policy/actor as policy_actor
import supernova/tools/process

pub fn main() -> Nil {
  gleeunit.main()
}

@external(erlang, "supernova_process_ffi", "spawn_background")
fn spawn_background(command: String, working_dir: String) -> Result(Int, String)

fn wait_for_process() -> Nil {
  beam_process.sleep(200)
}

pub fn list_info_and_kill_round_trip_test() {
  let assert Ok(pid) = spawn_background("sleep 30", ".")
  wait_for_process()

  let assert Ok(listing) = process.list()
  string.contains(listing, int.to_string(pid))
  |> should.equal(True)

  let assert Ok(info) = process.info(pid)
  string.contains(info, "pid=" <> int.to_string(pid))
  |> should.equal(True)
  string.contains(info, "cpu=")
  |> should.equal(True)
  string.contains(info, "memory=")
  |> should.equal(True)

  let assert Ok(killed) = process.kill(pid)
  killed |> should.equal("killed " <> int.to_string(pid))

  beam_process.sleep(300)
  process.info(pid)
  |> should.be_error()
}

pub fn info_authorized_denies_external_process_test() {
  let assert Ok(pid) = spawn_background("sleep 30", ".")
  wait_for_process()

  let assert Ok(policy) = policy_actor.start("test/fixtures/process_workspace")

  process.info_authorized(policy, "agent_1", pid)
  |> should.be_error()

  let _ = process.kill(pid)
  policy_actor.stop(policy)
  beam_process.sleep(200)
}

pub fn info_and_kill_authorized_allow_workspace_script_test() {
  let assert Ok(pid) =
    spawn_background(
      "sh ./process_fixture.sh",
      "test/fixtures/process_workspace/agent_1",
    )
  wait_for_process()

  let assert Ok(policy) = policy_actor.start("test/fixtures/process_workspace")

  let assert Ok(info) = process.info_authorized(policy, "agent_1", pid)
  string.contains(info, "./process_fixture.sh")
  |> should.equal(True)

  let assert Ok(killed) = process.kill_authorized(policy, "agent_1", pid)
  killed |> should.equal("killed " <> int.to_string(pid))

  beam_process.sleep(300)
  process.info(pid)
  |> should.be_error()

  policy_actor.stop(policy)
}
