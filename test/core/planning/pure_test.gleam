import gleam/dict
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import supernova/core/planning/pure
import supernova/core/task_graph

pub fn main() {
  gleeunit.main()
}

fn sorted(ids: List(String)) -> List(String) {
  list.sort(ids, string.compare)
}

pub fn parse_planning_response_valid_graph_test() {
  let json =
    "[{\"id\":\"a\",\"name\":\"Task A\",\"depends_on\":[]},{\"id\":\"b\",\"name\":\"Task B\",\"depends_on\":[\"a\"]},{\"id\":\"c\",\"name\":\"Task C\",\"depends_on\":[\"a\"]}]"

  let assert Ok(graph) = pure.parse_planning_response(json)

  dict.size(graph.nodes) |> should.equal(3)
  list.length(graph.edges) |> should.equal(2)
  task_graph.get_descendants(graph, "a") |> sorted |> should.equal(["b", "c"])
  task_graph.ready_tasks(graph, []) |> should.equal([])
}

pub fn parse_planning_response_invalid_json_test() {
  pure.parse_planning_response("not-json")
  |> should.equal(Error("Invalid JSON response"))
}

pub fn parse_planning_response_cycle_returns_error_test() {
  let json =
    "[{\"id\":\"a\",\"name\":\"Task A\",\"depends_on\":[\"b\"]},{\"id\":\"b\",\"name\":\"Task B\",\"depends_on\":[\"a\"]}]"

  pure.parse_planning_response(json)
  |> should.equal(Error("Dependency cycle detected"))
}
