//// Gateway tool tests

import gleam/string
import gleeunit
import gleeunit/should
import supernova/tools/gateway

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn describe_scope_test() {
  let assert Ok(description) = gateway.execute("{\"action\":\"describe\"}")

  string.contains(description, "one-shot facade")
  |> should.equal(True)
  string.contains(description, "get_budget")
  |> should.equal(True)
  string.contains(description, "write_world")
  |> should.equal(True)
}

pub fn invoke_get_budget_round_trip_test() {
  let assert Ok(result) =
    gateway.execute("{\"action\":\"get_budget\",\"agent_id\":\"gateway_tool\"}")

  result
  |> should.equal("ok: budget:agent=gateway_tool")
}

pub fn invoke_write_world_round_trip_test() {
  let assert Ok(result) =
    gateway.execute(
      "{\"action\":\"write_world\",\"agent_id\":\"gateway_tool\",\"content\":\"sky is blue\",\"confidence\":0.9}",
    )

  result
  |> should.equal("ok: fact_asserted:confidence=0.9:sky is blue")
}

pub fn unregistered_agent_denied_test() {
  let assert Ok(result) =
    gateway.execute(
      "{\"action\":\"get_budget\",\"agent_id\":\"ghost\",\"register_agent\":false}",
    )

  result
  |> should.equal("denied: Agent not registered: ghost")
}

pub fn read_file_blocks_absolute_path_and_traversal_test() {
  let assert Ok(abs_result) =
    gateway.execute(
      "{\"action\":\"read_file\",\"agent_id\":\"gateway_tool\",\"path\":\"/etc/passwd\"}",
    )
  string.starts_with(abs_result, "denied:") |> should.equal(True)

  let assert Ok(trav_result) =
    gateway.execute(
      "{\"action\":\"write_file\",\"agent_id\":\"gateway_tool\",\"path\":\"../escape.txt\",\"content\":\"x\"}",
    )
  string.starts_with(trav_result, "denied:") |> should.equal(True)

  let assert Ok(rel_result) =
    gateway.execute(
      "{\"action\":\"read_file\",\"agent_id\":\"gateway_tool\",\"path\":\"notes.txt\"}",
    )
  rel_result |> should.equal("ok: file_content:path=notes.txt")
}
