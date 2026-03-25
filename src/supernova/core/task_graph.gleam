//// TaskGraph — Directed Acyclic Graph of Tasks
////
//// Pure module — no FFI, no side effects, no OTP imports.
//// Represents tasks with dependencies for parallel execution coordination.
////
//// ## Usage
////
//// ```gleam
//// let g = task_graph.new()
//// let g = task_graph.add_task(g, "a", "Task A", [])
//// let g = task_graph.add_task(g, "b", "Task B", ["a"])
//// let assert Ok(Nil) = task_graph.validate(g)
//// let ready = task_graph.ready_tasks(g, [])  // ["a"]
//// let g = task_graph.mark_done(g, "a")
//// let ready = task_graph.ready_tasks(g, ["a"])  // ["b"]
//// ```

import gleam/dict.{type Dict}
import gleam/list
import gleam/set

// ============================================================================
// Types
// ============================================================================

/// Status of a task in the graph.
pub type TaskStatus {
  Pending
  Ready
  Running
  Done
  Failed
  Cancelled
}

/// A node in the task graph.
pub type TaskNode {
  TaskNode(
    /// Unique task identifier
    id: String,
    /// Human-readable task name
    name: String,
    /// Current execution status
    status: TaskStatus,
    /// IDs of tasks that must complete before this one can run
    deps: List(String),
  )
}

/// A directed acyclic graph of tasks with dependencies.
pub type TaskGraph {
  TaskGraph(
    /// All task nodes indexed by id
    nodes: Dict(String, TaskNode),
    /// Dependency edges as list of #(from, to) — from must complete before to
    edges: List(#(String, String)),
  )
}

// ============================================================================
// API
// ============================================================================

/// Create an empty task graph.
pub fn new() -> TaskGraph {
  TaskGraph(nodes: dict.new(), edges: [])
}

/// Add a task to the graph.
///
/// `deps` is a list of task IDs that must complete before this task can run.
/// Tasks can be added in any order — deps need not exist yet.
pub fn add_task(
  graph: TaskGraph,
  id: String,
  name: String,
  deps: List(String),
) -> TaskGraph {
  let node = TaskNode(id: id, name: name, status: Pending, deps: deps)
  let new_nodes = dict.insert(graph.nodes, id, node)
  // Add edges: each dep -> this task
  let new_edges =
    list.fold(deps, graph.edges, fn(acc, dep) { [#(dep, id), ..acc] })
  TaskGraph(nodes: new_nodes, edges: new_edges)
}

/// Validate the graph — detects cycles using DFS with 3-color marking.
///
/// Returns `Ok(Nil)` if the graph is a valid DAG.
/// Returns `Error(description)` if a cycle is detected.
pub fn validate(graph: TaskGraph) -> Result(Nil, String) {
  let ids = dict.keys(graph.nodes)
  detect_cycle(graph, ids)
}

/// Return task IDs whose dependencies are all satisfied by `completed`.
///
/// A task is "ready" if:
/// - Its status is `Pending`
/// - All of its `deps` appear in `completed`
pub fn ready_tasks(graph: TaskGraph, completed: List(String)) -> List(String) {
  let completed_set = set.from_list(completed)
  dict.values(graph.nodes)
  |> list.filter(fn(node) {
    node.status == Pending
    && !set.contains(completed_set, node.id)
    && list.all(node.deps, fn(dep) { set.contains(completed_set, dep) })
  })
  |> list.map(fn(node) { node.id })
}

/// Mark a task as done.
///
/// If the task does not exist, the graph is returned unchanged.
pub fn mark_done(graph: TaskGraph, task_id: String) -> TaskGraph {
  update_status(graph, task_id, Done)
}

/// Mark a task as failed.
///
/// If the task does not exist, the graph is returned unchanged.
pub fn mark_failed(graph: TaskGraph, task_id: String) -> TaskGraph {
  update_status(graph, task_id, Failed)
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn update_status(
  graph: TaskGraph,
  task_id: String,
  status: TaskStatus,
) -> TaskGraph {
  case dict.get(graph.nodes, task_id) {
    Error(_) -> graph
    Ok(node) -> {
      let updated = TaskNode(..node, status: status)
      TaskGraph(..graph, nodes: dict.insert(graph.nodes, task_id, updated))
    }
  }
}

/// DFS cycle detection with 3-color marking.
/// White (unvisited), Grey (in current path), Black (fully processed).
fn detect_cycle(graph: TaskGraph, ids: List(String)) -> Result(Nil, String) {
  let grey = set.new()
  let black = set.new()
  dfs_all(graph, ids, grey, black)
}

fn dfs_all(
  graph: TaskGraph,
  remaining: List(String),
  grey: set.Set(String),
  black: set.Set(String),
) -> Result(Nil, String) {
  case remaining {
    [] -> Ok(Nil)
    [id, ..rest] ->
      case set.contains(black, id) {
        True -> dfs_all(graph, rest, grey, black)
        False ->
          case dfs_visit(graph, id, grey, black) {
            Error(msg) -> Error(msg)
            Ok(new_black) -> dfs_all(graph, rest, grey, new_black)
          }
      }
  }
}

fn dfs_visit(
  graph: TaskGraph,
  id: String,
  grey: set.Set(String),
  black: set.Set(String),
) -> Result(set.Set(String), String) {
  case set.contains(grey, id) {
    True -> Error("Cycle detected involving task: " <> id)
    False ->
      case set.contains(black, id) {
        True -> Ok(black)
        False -> {
          let new_grey = set.insert(grey, id)
          let neighbors = get_neighbors(graph, id)
          case visit_neighbors(graph, neighbors, new_grey, black) {
            Error(msg) -> Error(msg)
            Ok(new_black) -> Ok(set.insert(new_black, id))
          }
        }
      }
  }
}

fn visit_neighbors(
  graph: TaskGraph,
  neighbors: List(String),
  grey: set.Set(String),
  black: set.Set(String),
) -> Result(set.Set(String), String) {
  case neighbors {
    [] -> Ok(black)
    [n, ..rest] ->
      case dfs_visit(graph, n, grey, black) {
        Error(msg) -> Error(msg)
        Ok(new_black) -> visit_neighbors(graph, rest, grey, new_black)
      }
  }
}

/// Get all tasks that depend on `id` (outgoing edges from `id`).
fn get_neighbors(graph: TaskGraph, id: String) -> List(String) {
  list.filter_map(graph.edges, fn(edge) {
    let #(from, to) = edge
    case from == id {
      True -> Ok(to)
      False -> Error(Nil)
    }
  })
}

/// Mark a task as running.
///
/// If the task does not exist, the graph is returned unchanged.
pub fn mark_running(graph: TaskGraph, task_id: String) -> TaskGraph {
  update_status(graph, task_id, Running)
}

/// Mark a task as cancelled.
///
/// If the task does not exist, the graph is returned unchanged.
pub fn mark_cancelled(graph: TaskGraph, task_id: String) -> TaskGraph {
  update_status(graph, task_id, Cancelled)
}

/// Get all task IDs that transitively depend on the given task.
///
/// Returns all tasks reachable via dependency edges starting from `task_id`.
/// Does NOT include `task_id` itself.
pub fn get_descendants(graph: TaskGraph, task_id: String) -> List(String) {
  let direct = get_neighbors(graph, task_id)
  collect_descendants(graph, direct, set.new())
  |> set.to_list()
}

fn collect_descendants(
  graph: TaskGraph,
  to_visit: List(String),
  visited: set.Set(String),
) -> set.Set(String) {
  case to_visit {
    [] -> visited
    [id, ..rest] ->
      case set.contains(visited, id) {
        True -> collect_descendants(graph, rest, visited)
        False -> {
          let new_visited = set.insert(visited, id)
          let children = get_neighbors(graph, id)
          collect_descendants(graph, list.append(rest, children), new_visited)
        }
      }
  }
}
