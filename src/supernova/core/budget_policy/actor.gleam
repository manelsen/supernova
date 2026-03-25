//// Budget Policy — Actor
////
//// Singleton actor that manages configurable resource limits per agent.
//// Delegates pure logic to the pure module, executes side effects via FFI.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(policy) = actor.start()
//// let assert Ok(_) = actor.check(policy, "agent_1", BudgetTokens, 100)
//// actor.set_budget(policy, "agent_1", config)
//// actor.stop(policy)
//// ```

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import supernova/core/budget_policy/pure
import supernova/core/budget_policy/types.{
  type BudgetCommand, type BudgetConfig, type BudgetExceeded,
  type BudgetPolicyState, type BudgetResource, BudgetPolicyState,
  EmitBudgetViolation, WriteBudgetAudit,
}

// ============================================================================
// FFI — Timestamp (Erlang)
// ============================================================================

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

// ============================================================================
// Types
// ============================================================================

/// Messages that the budget policy actor handles.
pub type BudgetMessage {
  /// Check if a resource consumption is within budget
  Check(
    reply_to: Subject(Result(Nil, BudgetExceeded)),
    agent_id: String,
    resource: BudgetResource,
    amount: Int,
  )
  /// Set a budget configuration for an agent
  SetBudget(reply_to: Subject(Nil), agent_id: String, config: BudgetConfig)
  /// Get the budget configuration for an agent
  GetBudget(reply_to: Subject(BudgetConfig), agent_id: String)
  /// Record consumption after a successful operation
  RecordConsumption(
    reply_to: Subject(Nil),
    agent_id: String,
    resource: BudgetResource,
    amount: Int,
  )
  /// Set parent agent for budget inheritance
  SetParent(reply_to: Subject(Nil), agent_id: String, parent_id: String)
  /// Release a sub-agent slot
  ReleaseSubAgent(reply_to: Subject(Nil), agent_id: String)
  /// Reset time windows for an agent
  ResetWindows(reply_to: Subject(Nil), agent_id: String)
  /// Get current consumption for a resource
  GetConsumption(
    reply_to: Subject(Int),
    agent_id: String,
    resource: BudgetResource,
  )
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running budget policy actor.
pub type BudgetPolicy =
  Subject(BudgetMessage)

// ============================================================================
// Command Execution
// ============================================================================

/// Execute a list of commands returned by pure functions.
fn execute_commands(commands: List(BudgetCommand)) -> Nil {
  list.each(commands, fn(cmd) {
    case cmd {
      EmitBudgetViolation(_agent_id, _resource, _current, _limit) -> {
        // TODO: Integrate with actual telemetry system when available
        Nil
      }
      WriteBudgetAudit(_agent_id, _action, _timestamp) -> {
        // TODO: Integrate with actual audit system when available
        Nil
      }
    }
  })
}

// ============================================================================
// Actor Handler
// ============================================================================

/// Handle incoming messages and update state.
fn handle_message(
  state: BudgetPolicyState,
  message: BudgetMessage,
) -> actor.Next(BudgetPolicyState, BudgetMessage) {
  case message {
    Check(reply_to, agent_id, resource, amount) -> {
      let timestamp = ffi_current_timestamp()
      let #(new_state, result, commands) =
        pure.check(state, agent_id, resource, amount, timestamp)
      execute_commands(commands)

      actor.send(reply_to, result)
      actor.continue(new_state)
    }

    SetBudget(reply_to, agent_id, config) -> {
      let timestamp = ffi_current_timestamp()
      let #(new_state, commands) =
        pure.set_budget(state, agent_id, config, timestamp)
      execute_commands(commands)

      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    GetBudget(reply_to, agent_id) -> {
      let config = pure.get_budget(state, agent_id)
      actor.send(reply_to, config)
      actor.continue(state)
    }

    RecordConsumption(reply_to, agent_id, resource, amount) -> {
      let timestamp = ffi_current_timestamp()
      let new_state =
        pure.record_consumption(state, agent_id, resource, amount, timestamp)

      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    SetParent(reply_to, agent_id, parent_id) -> {
      let timestamp = ffi_current_timestamp()
      let #(new_state, commands) =
        pure.set_parent(state, agent_id, parent_id, timestamp)
      execute_commands(commands)

      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    ReleaseSubAgent(reply_to, agent_id) -> {
      let timestamp = ffi_current_timestamp()
      let #(new_state, commands) =
        pure.release_sub_agent(state, agent_id, timestamp)
      execute_commands(commands)

      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    ResetWindows(reply_to, agent_id) -> {
      let timestamp = ffi_current_timestamp()
      let new_state = pure.reset_windows(state, agent_id, timestamp)

      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    GetConsumption(reply_to, agent_id, resource) -> {
      let timestamp = ffi_current_timestamp()
      let consumption =
        pure.get_consumption(state, agent_id, resource, timestamp)

      actor.send(reply_to, consumption)
      actor.continue(state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start the budget policy actor with default configuration.
pub fn start() -> Result(BudgetPolicy, actor.StartError) {
  let initial_state =
    BudgetPolicyState(
      agents: dict.new(),
      default_config: types.default_budget_config(),
      inheritance_ratio: 20,
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Start the budget policy actor with custom default config and inheritance ratio.
pub fn start_with_config(
  default_config: BudgetConfig,
  inheritance_ratio: Int,
) -> Result(BudgetPolicy, actor.StartError) {
  let initial_state =
    BudgetPolicyState(
      agents: dict.new(),
      default_config: default_config,
      inheritance_ratio: inheritance_ratio,
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Check if a resource consumption is within budget.
///
/// Returns Ok(Nil) if within budget, Error(BudgetExceeded) if exceeded.
pub fn check(
  policy: BudgetPolicy,
  agent_id: String,
  resource: BudgetResource,
  amount: Int,
) -> Result(Nil, BudgetExceeded) {
  actor.call(policy, waiting: 5000, sending: Check(
    _,
    agent_id,
    resource,
    amount,
  ))
}

/// Set a budget configuration for an agent.
pub fn set_budget(
  policy: BudgetPolicy,
  agent_id: String,
  config: BudgetConfig,
) -> Nil {
  actor.call(policy, waiting: 5000, sending: SetBudget(_, agent_id, config))
}

/// Get the budget configuration for an agent.
pub fn get_budget(policy: BudgetPolicy, agent_id: String) -> BudgetConfig {
  actor.call(policy, waiting: 5000, sending: GetBudget(_, agent_id))
}

/// Record consumption after a successful operation.
pub fn record_consumption(
  policy: BudgetPolicy,
  agent_id: String,
  resource: BudgetResource,
  amount: Int,
) -> Nil {
  actor.call(policy, waiting: 5000, sending: RecordConsumption(
    _,
    agent_id,
    resource,
    amount,
  ))
}

/// Set parent agent for budget inheritance.
///
/// The child agent's budget is calculated as a percentage of the parent's.
pub fn set_parent(
  policy: BudgetPolicy,
  agent_id: String,
  parent_id: String,
) -> Nil {
  actor.call(policy, waiting: 5000, sending: SetParent(_, agent_id, parent_id))
}

/// Release a sub-agent slot (decrement parent's sub-agent count).
pub fn release_sub_agent(policy: BudgetPolicy, agent_id: String) -> Nil {
  actor.call(policy, waiting: 5000, sending: ReleaseSubAgent(_, agent_id))
}

/// Reset time windows for an agent.
pub fn reset_windows(policy: BudgetPolicy, agent_id: String) -> Nil {
  actor.call(policy, waiting: 5000, sending: ResetWindows(_, agent_id))
}

/// Get current consumption for a resource type.
pub fn get_consumption(
  policy: BudgetPolicy,
  agent_id: String,
  resource: BudgetResource,
) -> Int {
  actor.call(policy, waiting: 5000, sending: GetConsumption(
    _,
    agent_id,
    resource,
  ))
}

/// Stop the budget policy actor.
pub fn stop(policy: BudgetPolicy) -> Nil {
  actor.call(policy, waiting: 5000, sending: Stop)
}
