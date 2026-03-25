//// Kernel Scheduler — Actor
////
//// Singleton actor that manages central agent scheduling.
//// Delegates pure logic to the pure module, executes side effects via FFI.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(scheduler) = actor.start()
//// actor.register(scheduler, "agent_1", subject, Normal, 100)
//// actor.tick(scheduler)
//// let assert Ok(infos) = actor.status(scheduler)
//// actor.stop(scheduler)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import supernova/core/kernel_scheduler/pure
import supernova/core/kernel_scheduler/types.{
  type AgentInfo, type KernelSchedulerState, type SchedulerPriority,
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

/// Messages that the kernel scheduler actor handles.
pub type SchedulerMessage {
  /// Register a new agent
  Register(
    reply_to: Subject(Result(Nil, String)),
    agent_id: String,
    subject: Subject(Nil),
    priority: SchedulerPriority,
    budget: Int,
  )
  /// Unregister an agent
  Unregister(reply_to: Subject(Result(Nil, String)), agent_id: String)
  /// Set agent priority
  SetPriority(
    reply_to: Subject(Result(Nil, String)),
    agent_id: String,
    priority: SchedulerPriority,
  )
  /// Get status of all agents
  Status(reply_to: Subject(List(AgentInfo)))
  /// Trigger a scheduler tick (select next agent and send tick)
  Tick(reply_to: Subject(Result(AgentInfo, String)))
  /// Detect and handle starved agents
  DetectStarved(reply_to: Subject(Int))
  /// Reset budgets for all agents
  ResetBudgets(reply_to: Subject(Nil), budget: Int)
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running kernel scheduler actor.
pub type KernelSchedulerHandle =
  Subject(SchedulerMessage)

// ============================================================================
// Actor Handler
// ============================================================================

/// Handle incoming messages and update state.
fn handle_message(
  state: KernelSchedulerState,
  message: SchedulerMessage,
) -> actor.Next(KernelSchedulerState, SchedulerMessage) {
  case message {
    Register(reply_to, agent_id, subject, priority, budget) -> {
      let opts =
        types.SchedulerOpts(
          subject: subject,
          priority: priority,
          budget: budget,
        )
      let #(new_state, result) = pure.register(state, agent_id, opts)
      case result {
        Ok(_) -> actor.send(reply_to, Ok(Nil))
        Error(err) -> actor.send(reply_to, Error(err))
      }
      actor.continue(new_state)
    }

    Unregister(reply_to, agent_id) -> {
      let #(new_state, result) = pure.unregister(state, agent_id)
      case result {
        Ok(_) -> actor.send(reply_to, Ok(Nil))
        Error(err) -> actor.send(reply_to, Error(err))
      }
      actor.continue(new_state)
    }

    SetPriority(reply_to, agent_id, priority) -> {
      let #(new_state, result) = pure.set_priority(state, agent_id, priority)
      case result {
        Ok(_) -> actor.send(reply_to, Ok(Nil))
        Error(err) -> actor.send(reply_to, Error(err))
      }
      actor.continue(new_state)
    }

    Status(reply_to) -> {
      let infos = pure.status(state)
      actor.send(reply_to, infos)
      actor.continue(state)
    }

    Tick(reply_to) -> {
      let now = ffi_current_timestamp()
      let #(new_state, result) = pure.next_agent(state, now)
      case result {
        Ok(info) -> {
          // Send tick to the selected agent
          process.send(info.subject, Nil)
          actor.send(reply_to, Ok(info))
        }
        Error(err) -> actor.send(reply_to, Error(err))
      }
      actor.continue(new_state)
    }

    DetectStarved(reply_to) -> {
      let now = ffi_current_timestamp()
      let #(new_state, commands) = pure.detect_starved(state, now)
      execute_commands(commands)
      actor.send(reply_to, list.length(commands))
      actor.continue(new_state)
    }

    ResetBudgets(reply_to, budget) -> {
      let new_state = pure.reset_budgets(state, budget)
      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

/// Execute commands returned by pure functions.
fn execute_commands(commands: List(types.SchedulerCommand)) -> Nil {
  list.each(commands, fn(cmd) {
    let _ = cmd
    // TODO: Integrate with telemetry/audit systems when available
    Nil
  })
}

// ============================================================================
// Public API
// ============================================================================

/// Start the kernel scheduler actor.
pub fn start() -> Result(KernelSchedulerHandle, actor.StartError) {
  let initial_state = types.initial_state()

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Register a new agent in the scheduler.
pub fn register(
  scheduler: KernelSchedulerHandle,
  agent_id: String,
  subject: Subject(Nil),
  priority: SchedulerPriority,
  budget: Int,
) -> Result(Nil, String) {
  actor.call(scheduler, waiting: 5000, sending: Register(
    _,
    agent_id,
    subject,
    priority,
    budget,
  ))
}

/// Unregister an agent from the scheduler.
pub fn unregister(
  scheduler: KernelSchedulerHandle,
  agent_id: String,
) -> Result(Nil, String) {
  actor.call(scheduler, waiting: 5000, sending: Unregister(_, agent_id))
}

/// Set the priority of a registered agent.
pub fn set_priority(
  scheduler: KernelSchedulerHandle,
  agent_id: String,
  priority: SchedulerPriority,
) -> Result(Nil, String) {
  actor.call(scheduler, waiting: 5000, sending: SetPriority(
    _,
    agent_id,
    priority,
  ))
}

/// Get the status of all registered agents.
pub fn status(scheduler: KernelSchedulerHandle) -> List(AgentInfo) {
  actor.call(scheduler, waiting: 5000, sending: Status)
}

/// Trigger a scheduler tick — selects next agent and sends tick message.
pub fn tick(scheduler: KernelSchedulerHandle) -> Result(AgentInfo, String) {
  actor.call(scheduler, waiting: 5000, sending: Tick)
}

/// Detect starved agents and elevate their priority.
/// Returns the number of starved agents detected.
pub fn detect_starved(scheduler: KernelSchedulerHandle) -> Int {
  actor.call(scheduler, waiting: 5000, sending: DetectStarved)
}

/// Reset budgets for all agents.
pub fn reset_budgets(scheduler: KernelSchedulerHandle, budget: Int) -> Nil {
  actor.call(scheduler, waiting: 5000, sending: ResetBudgets(_, budget))
}

/// Stop the kernel scheduler actor.
pub fn stop(scheduler: KernelSchedulerHandle) -> Nil {
  actor.call(scheduler, waiting: 5000, sending: Stop)
}
