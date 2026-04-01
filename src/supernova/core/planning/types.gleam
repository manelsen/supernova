//// Planning types for LLM-powered task decomposition.
////
//// Provides types for requesting a plan from an LLM and parsing the response.

import supernova/core/task_graph.{type TaskGraph}
pub type PlanningRequest {
  PlanningRequest(goal: String, agent_id: String, max_tasks: Int)
}

pub type PlanningResult {
  PlanningSuccess(graph: TaskGraph)
  PlanningError(reason: String)
}

pub type PlanningConfig {
  PlanningConfig(model: String, planning_prompt: String)
}

pub const default_planning_config = PlanningConfig(
  model: "glm-5",
  planning_prompt: "Decompose the following goal into independent subtasks. Return a JSON array of tasks where each task has: id, name, and depends_on (array of task ids that must complete first). Tasks that can run in parallel should have no dependencies. Example: [{\"id\":\"task1\",\"name\":\"Do thing A\",\"depends_on\":[]},{\"id\":\"task2\",\"name\":\"Do thing B\",\"depends_on\":[]},{\"id\":\"task3\",\"name\":\"Do thing C\",\"depends_on\":[\"task1\",\"task2\"]}]",
)
