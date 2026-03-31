//// Planning actor — LLM-powered task decomposition.
////
//// Actor that receives a planning request, calls an LLM to decompose
//// a complex goal into a task graph, and returns the plan.

import gleam/erlang/process.{type Subject}
import gleam/option
import gleam/otp/actor
import gleam/string
import supernova/core/planning/pure
import supernova/core/planning/types as planning_types
import supernova/llm/client
import supernova/llm/provider

pub type PlanningActor =
  Subject(PlanningCommand)

pub type PlanningCommand {
  Plan(
    reply_to: Subject(planning_types.PlanningResult),
    request: planning_types.PlanningRequest,
  )
  Stop(reply_to: Subject(Nil))
}

pub fn start() -> Result(PlanningActor, actor.StartError) {
  let initial = Nil
  case
    actor.new(initial)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

fn handle_message(
  state: Nil,
  message: PlanningCommand,
) -> actor.Next(Nil, PlanningCommand) {
  case message {
    Plan(reply_to, request) -> {
      let result = create_plan(request)
      process.send(reply_to, result)
      actor.continue(state)
    }
    Stop(reply_to) -> {
      process.send(reply_to, Nil)
      actor.stop()
    }
  }
}

fn create_plan(
  request: planning_types.PlanningRequest,
) -> planning_types.PlanningResult {
  let planning_config = planning_types.default_planning_config
  let prompt = planning_config.planning_prompt <> "\n\nGoal: " <> request.goal

  let messages = [provider.user_message(prompt)]
  let config =
    provider.ProviderConfig(
      name: "zhipu",
      api_key: option.None,
      base_url: option.None,
      default_model: planning_config.model,
    )

  case client.chat(messages, config, []) {
    Ok(response) -> {
      case pure.parse_planning_response(response.content) {
        Ok(graph) -> planning_types.PlanningSuccess(graph: graph)
        Error(e) -> planning_types.PlanningError(reason: e)
      }
    }
    Error(err) -> {
      planning_types.PlanningError(reason: string.inspect(err))
    }
  }
}

pub fn plan(
  actor: PlanningActor,
  goal: String,
  agent_id: String,
) -> planning_types.PlanningResult {
  let request =
    planning_types.PlanningRequest(
      goal: goal,
      agent_id: agent_id,
      max_tasks: 20,
    )
  actor.call(actor, waiting: 60_000, sending: Plan(_, request))
}
