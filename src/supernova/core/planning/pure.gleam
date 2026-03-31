//// Planning pure functions — task decomposition parsing.
////
//// Pure logic for parsing LLM planning responses into TaskGraphs.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import supernova/core/task_graph

pub fn parse_planning_response(
  json_string: String,
) -> Result(task_graph.TaskGraph, String) {
  case json.parse(from: json_string, using: planning_response_decoder()) {
    Error(_) -> Error("Invalid JSON response")
    Ok(tasks) -> {
      case validate_no_cycles(tasks) {
        True -> {
          let nodes_list = list.map(tasks, fn(t) { #(t.id, t) })
          let graph =
            task_graph.TaskGraph(
              nodes: dict.from_list(nodes_list),
              edges: build_edges(tasks),
            )
          case task_graph.validate(graph) {
            Ok(_) -> Ok(graph)
            Error(e) -> Error(e)
          }
        }
        False -> Error("Dependency cycle detected")
      }
    }
  }
}

fn planning_task_decoder() -> decode.Decoder(task_graph.TaskNode) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use deps <- decode.field("depends_on", decode.list(decode.string))
  decode.success(task_graph.TaskNode(
    id: id,
    name: name,
    status: task_graph.Ready,
    deps: deps,
  ))
}

fn planning_response_decoder() -> decode.Decoder(List(task_graph.TaskNode)) {
  decode.list(planning_task_decoder())
}

fn build_edges(nodes: List(task_graph.TaskNode)) -> List(#(String, String)) {
  list.flat_map(nodes, fn(node) {
    list.map(node.deps, fn(dep) { #(dep, node.id) })
  })
}

fn validate_no_cycles(nodes: List(task_graph.TaskNode)) -> Bool {
  let deps_map =
    list.fold(nodes, dict.new(), fn(acc, node) {
      dict.insert(acc, node.id, node.deps)
    })
  list.all(nodes, fn(node) {
    case has_cycle(node.id, deps_map, []) {
      True -> False
      False -> True
    }
  })
}

fn has_cycle(
  node_id: String,
  deps: dict.Dict(String, List(String)),
  visited: List(String),
) -> Bool {
  case list.contains(visited, node_id) {
    True -> True
    False -> {
      case dict.get(deps, node_id) {
        Ok(node_deps) ->
          list.any(node_deps, fn(dep) {
            has_cycle(dep, deps, [node_id, ..visited])
          })
        Error(_) -> False
      }
    }
  }
}
