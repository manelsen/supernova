//// WorldModel — Actor
////
//// OTP actor managing the shared, versioned fact repository.
//// Delegates pure logic to the pure module, executes side effects (PubSub
//// notifications, permission checks) here.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(wm) = actor.start()
//// let assert Ok(fact_id) = actor.assert_fact(wm, "agent_1", "sky is blue", FactEntity, 0.9)
//// let assert Ok(Nil) = actor.retract(wm, "agent_1", fact_id, "outdated")
//// let facts = actor.query(wm, FactPattern(fact_type: Some(FactEntity), author: None, content_contains: None))
//// let v = actor.version(wm)
//// actor.stop(wm)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import supernova/core/workspace_policy/actor as policy_actor
import supernova/core/workspace_policy/types as policy_types
import supernova/core/world_model/pure
import supernova/core/world_model/types.{
  type Fact, type FactPattern, type FactType, type WorldModelCommand,
  type WorldModelState, NotifyChange, WriteAssertAudit, WriteRetractAudit,
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

/// A registered subscriber: pattern to match + subject to send notifications to.
type Subscriber {
  Subscriber(pattern: FactPattern, subject: Subject(Fact))
}

/// Internal actor state: pure model state + side-effectful handles.
type ActorState {
  ActorState(
    /// Pure world model state (facts, version, next_id)
    model: WorldModelState,
    /// Active subscribers for real-time notifications
    subscribers: List(Subscriber),
    /// Optional workspace policy for permission enforcement
    policy: Option(policy_actor.WorkspacePolicy),
  )
}

/// Messages handled by the world model actor.
pub type WorldModelMessage {
  /// Assert a new fact into the world model
  AssertFact(
    reply_to: Subject(Result(String, String)),
    agent_id: String,
    content: String,
    fact_type: FactType,
    confidence: Float,
  )
  /// Retract (tombstone) a fact by ID
  RetractFact(
    reply_to: Subject(Result(Nil, String)),
    agent_id: String,
    fact_id: String,
    reason: String,
  )
  /// Query facts matching a pattern (excludes tombstoned facts)
  Query(reply_to: Subject(List(Fact)), pattern: FactPattern)
  /// Subscribe to real-time fact changes matching a pattern
  Subscribe(
    reply_to: Subject(Nil),
    pattern: FactPattern,
    subject: Subject(Fact),
  )
  /// Get the current version number
  GetVersion(reply_to: Subject(Int))
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running world model actor.
pub type WorldModelHandle =
  Subject(WorldModelMessage)

// ============================================================================
// Permission Check
// ============================================================================

/// Check if an agent has permission for an operation.
/// If no policy is configured, all agents are permitted.
fn check_permission(
  policy: Option(policy_actor.WorkspacePolicy),
  agent_id: String,
  operation: policy_types.Operation,
) -> Result(Nil, String) {
  case policy {
    None -> Ok(Nil)
    Some(p) ->
      case policy_actor.authorize(p, agent_id, operation, "world_model") {
        Ok(_) -> Ok(Nil)
        Error(msg) -> Error(msg)
      }
  }
}

// ============================================================================
// Command Execution
// ============================================================================

/// Execute commands returned by pure functions.
/// Dispatches NotifyChange to matching subscribers via process.send.
fn execute_commands(
  commands: List(WorldModelCommand),
  subscribers: List(Subscriber),
) -> Nil {
  list.each(commands, fn(cmd) {
    case cmd {
      NotifyChange(fact) -> {
        list.each(subscribers, fn(sub) {
          case pure.matches_pattern(fact, sub.pattern) {
            True -> process.send(sub.subject, fact)
            False -> Nil
          }
        })
      }
      WriteAssertAudit(_, _, _) -> {
        // TODO: integrate with audit_log actor when wired up
        Nil
      }
      WriteRetractAudit(_, _) -> {
        // TODO: integrate with audit_log actor when wired up
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
  actor_state: ActorState,
  message: WorldModelMessage,
) -> actor.Next(ActorState, WorldModelMessage) {
  case message {
    AssertFact(reply_to, agent_id, content, fact_type, confidence) -> {
      case
        check_permission(actor_state.policy, agent_id, policy_types.OpWrite)
      {
        Error(msg) -> {
          actor.send(reply_to, Error(msg))
          actor.continue(actor_state)
        }
        Ok(_) -> {
          let now = ffi_current_timestamp()
          let #(new_model, result, commands) =
            pure.assert_fact(
              actor_state.model,
              content,
              fact_type,
              agent_id,
              confidence,
              now,
            )
          execute_commands(commands, actor_state.subscribers)
          actor.send(reply_to, result)
          actor.continue(ActorState(..actor_state, model: new_model))
        }
      }
    }

    RetractFact(reply_to, agent_id, fact_id, reason) -> {
      case
        check_permission(actor_state.policy, agent_id, policy_types.OpWrite)
      {
        Error(msg) -> {
          actor.send(reply_to, Error(msg))
          actor.continue(actor_state)
        }
        Ok(_) -> {
          let #(new_model, result, commands) =
            pure.retract(actor_state.model, fact_id, reason)
          execute_commands(commands, actor_state.subscribers)
          actor.send(reply_to, result)
          actor.continue(ActorState(..actor_state, model: new_model))
        }
      }
    }

    Query(reply_to, pattern) -> {
      let facts = pure.query(actor_state.model, pattern)
      actor.send(reply_to, facts)
      actor.continue(actor_state)
    }

    Subscribe(reply_to, pattern, subject) -> {
      let sub = Subscriber(pattern: pattern, subject: subject)
      let new_subs = [sub, ..actor_state.subscribers]
      actor.send(reply_to, Nil)
      actor.continue(ActorState(..actor_state, subscribers: new_subs))
    }

    GetVersion(reply_to) -> {
      actor.send(reply_to, pure.version(actor_state.model))
      actor.continue(actor_state)
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

/// Start the world model actor (no permission enforcement).
pub fn start() -> Result(WorldModelHandle, actor.StartError) {
  let initial =
    ActorState(model: types.initial_state(), subscribers: [], policy: None)

  case
    actor.new(initial)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Start the world model actor with workspace policy enforcement.
/// Agents without OpWrite permission will receive an error on assert/retract.
pub fn start_with_policy(
  policy: policy_actor.WorkspacePolicy,
) -> Result(WorldModelHandle, actor.StartError) {
  let initial =
    ActorState(
      model: types.initial_state(),
      subscribers: [],
      policy: Some(policy),
    )

  case
    actor.new(initial)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Assert a new fact into the world model.
///
/// Returns Ok(fact_id) on success, Error(reason) if confidence is invalid
/// or the agent lacks permission.
pub fn assert_fact(
  handle: WorldModelHandle,
  agent_id: String,
  content: String,
  fact_type: FactType,
  confidence: Float,
) -> Result(String, String) {
  actor.call(handle, waiting: 5000, sending: AssertFact(
    _,
    agent_id,
    content,
    fact_type,
    confidence,
  ))
}

/// Retract (tombstone) a fact by ID.
///
/// Returns Ok(Nil) on success, Error(reason) if not found, already retracted,
/// or the agent lacks permission.
pub fn retract(
  handle: WorldModelHandle,
  agent_id: String,
  fact_id: String,
  reason: String,
) -> Result(Nil, String) {
  actor.call(handle, waiting: 5000, sending: RetractFact(
    _,
    agent_id,
    fact_id,
    reason,
  ))
}

/// Query facts matching a pattern.
/// Excludes tombstoned facts.
pub fn query(handle: WorldModelHandle, pattern: FactPattern) -> List(Fact) {
  actor.call(handle, waiting: 5000, sending: Query(_, pattern))
}

/// Subscribe to real-time fact changes matching a pattern.
///
/// When a matching fact is asserted or retracted, it will be sent to `subject`.
/// Use `process.new_subject()` to create a subject, and `process.receive/2`
/// to collect notifications.
pub fn subscribe(
  handle: WorldModelHandle,
  pattern: FactPattern,
  subject: Subject(Fact),
) -> Nil {
  actor.call(handle, waiting: 5000, sending: Subscribe(_, pattern, subject))
}

/// Get the current version number.
/// Incremented on every assert or retract.
pub fn version(handle: WorldModelHandle) -> Int {
  actor.call(handle, waiting: 5000, sending: GetVersion)
}

/// Stop the world model actor.
pub fn stop(handle: WorldModelHandle) -> Nil {
  actor.call(handle, waiting: 5000, sending: Stop)
}
