//// Kernel Scheduler — Pure Functions
////
//// Pure functions for the central agent scheduler. No FFI, no side effects.
//// Functions take state and return new state + commands for the actor to execute.
////
//// ## Usage
////
//// ```gleam
//// let opts = SchedulerOpts(subject, Normal, 100)
//// let #(state, result) = pure.register(state, "agent_1", opts)
//// let #(state, result) = pure.next_agent(state, now)
//// ```

import gleam/dict
import gleam/int
import gleam/list
import gleam/order
import supernova/core/kernel_scheduler/types.{
  type AgentInfo, type KernelSchedulerState, type SchedulerCommand, AgentInfo,
  Exhausted, Idle, KernelSchedulerState, Running, Starved,
}

// ============================================================================
// Public API
// ============================================================================

/// Register a new agent in the scheduler.
///
/// Returns `#(new_state, Ok(Nil))` on success.
/// Returns `#(state, Error("Agent already registered: ..."))` if duplicate.
pub fn register(
  state: KernelSchedulerState,
  agent_id: String,
  opts: types.SchedulerOpts,
) -> #(KernelSchedulerState, Result(Nil, String)) {
  case dict.get(state.agents, agent_id) {
    Ok(_) -> #(state, Error("Agent already registered: " <> agent_id))
    Error(_) -> {
      let info =
        AgentInfo(
          agent_id: agent_id,
          subject: opts.subject,
          status: Idle,
          priority: opts.priority,
          last_run: 0,
          budget_remaining: opts.budget,
        )
      let new_agents = dict.insert(state.agents, agent_id, info)
      #(KernelSchedulerState(..state, agents: new_agents), Ok(Nil))
    }
  }
}

/// Unregister an agent from the scheduler.
///
/// Returns `#(new_state, Ok(Nil))` on success.
/// Returns `#(state, Error("Agent not found: ..."))` if not registered.
pub fn unregister(
  state: KernelSchedulerState,
  agent_id: String,
) -> #(KernelSchedulerState, Result(Nil, String)) {
  case dict.get(state.agents, agent_id) {
    Ok(_) -> {
      let new_agents = dict.delete(state.agents, agent_id)
      #(KernelSchedulerState(..state, agents: new_agents), Ok(Nil))
    }
    Error(_) -> #(state, Error("Agent not found: " <> agent_id))
  }
}

/// Set the priority of a registered agent.
///
/// Returns `#(new_state, Ok(Nil))` on success.
/// Returns `#(state, Error("Agent not found: ..."))` if not registered.
pub fn set_priority(
  state: KernelSchedulerState,
  agent_id: String,
  priority: types.SchedulerPriority,
) -> #(KernelSchedulerState, Result(Nil, String)) {
  case dict.get(state.agents, agent_id) {
    Ok(info) -> {
      let updated = AgentInfo(..info, priority: priority)
      let new_agents = dict.insert(state.agents, agent_id, updated)
      #(KernelSchedulerState(..state, agents: new_agents), Ok(Nil))
    }
    Error(_) -> #(state, Error("Agent not found: " <> agent_id))
  }
}

/// Get the status of all registered agents.
pub fn status(state: KernelSchedulerState) -> List(AgentInfo) {
  dict.values(state.agents)
}

/// Select the next agent to receive a tick using weighted round-robin.
///
/// Returns `#(new_state, Ok(agent_info))` on success.
/// Returns `#(state, Error("No ready agents"))` if no agents are ready.
///
/// Agents with budget <= 0 are skipped.
/// Agents are sorted by effective priority (base + starvation boost).
/// Each agent appears `priority_weight` times in the selection list.
pub fn next_agent(
  state: KernelSchedulerState,
  now: Int,
) -> #(KernelSchedulerState, Result(AgentInfo, String)) {
  let all_agents = dict.values(state.agents)
  let ready = list.filter(all_agents, fn(info) { info.budget_remaining != 0 })
  case list.is_empty(ready) {
    True -> #(state, Error("No ready agents"))
    False -> {
      let sorted = sort_by_effective_priority(ready, now)
      let weighted = build_weighted_list(sorted, now)
      let index = state.cursor % list.length(weighted)
      case list_drop(weighted, index) {
        [selected, ..] -> {
          let updated =
            AgentInfo(
              ..selected,
              last_run: now,
              budget_remaining: case selected.budget_remaining {
                -1 -> -1
                n -> int.max(0, n - 1)
              },
              status: Running,
            )
          let new_agents = dict.insert(state.agents, selected.agent_id, updated)
          let new_state =
            KernelSchedulerState(
              ..state,
              agents: new_agents,
              cursor: state.cursor + 1,
            )
          #(new_state, Ok(selected))
        }
        [] -> #(state, Error("No ready agents"))
      }
    }
  }
}

/// Detect starved agents and elevate their priority.
///
/// An agent is starved if it has not received a tick for longer than
/// the starvation threshold and has remaining budget.
///
/// Returns `#(new_state, commands)` where commands include telemetry events.
pub fn detect_starved(
  state: KernelSchedulerState,
  now: Int,
) -> #(KernelSchedulerState, List(SchedulerCommand)) {
  let all_agents = dict.values(state.agents)
  let #(new_agents, commands) =
    list.fold(all_agents, #(dict.new(), []), fn(acc, info) {
      let #(agents_acc, cmds_acc) = acc
      case info.last_run, info.budget_remaining {
        0, budget if budget != 0 -> {
          // Never run and has budget — mark as starved
          let boosted = boost_priority(info.priority)
          let updated = AgentInfo(..info, status: Starved, priority: boosted)
          let cmd =
            types.EmitStarvationTelemetry(
              agent_id: info.agent_id,
              old_priority: types.priority_to_string(info.priority),
              new_priority: types.priority_to_string(boosted),
            )
          #(dict.insert(agents_acc, info.agent_id, updated), [cmd, ..cmds_acc])
        }
        last, budget
          if last > 0 && budget != 0 && now - last > state.starvation_threshold
        -> {
          let boosted = boost_priority(info.priority)
          let updated = AgentInfo(..info, status: Starved, priority: boosted)
          let cmd =
            types.EmitStarvationTelemetry(
              agent_id: info.agent_id,
              old_priority: types.priority_to_string(info.priority),
              new_priority: types.priority_to_string(boosted),
            )
          #(dict.insert(agents_acc, info.agent_id, updated), [cmd, ..cmds_acc])
        }
        _, _ -> #(dict.insert(agents_acc, info.agent_id, info), cmds_acc)
      }
    })
  #(KernelSchedulerState(..state, agents: new_agents), commands)
}

/// Reset budgets for all agents (called at budget window reset).
///
/// Returns the new state with all budgets restored to the given amount.
pub fn reset_budgets(
  state: KernelSchedulerState,
  budget: Int,
) -> KernelSchedulerState {
  let all_agents = dict.values(state.agents)
  let new_agents =
    list.fold(all_agents, dict.new(), fn(acc, info) {
      let updated =
        AgentInfo(..info, budget_remaining: budget, status: case info.status {
          Exhausted -> Idle
          other -> other
        })
      dict.insert(acc, info.agent_id, updated)
    })
  KernelSchedulerState(..state, agents: new_agents)
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Sort agents by effective priority (highest weight first).
/// Within same priority, FIFO by last_run (oldest first).
fn sort_by_effective_priority(
  agents: List(AgentInfo),
  now: Int,
) -> List(AgentInfo) {
  list.sort(agents, fn(a, b) {
    let aw = effective_weight(a, now)
    let bw = effective_weight(b, now)
    case aw > bw {
      True -> order.Lt
      False ->
        case aw == bw {
          True ->
            case a.last_run < b.last_run {
              True -> order.Lt
              False -> order.Gt
            }
          False -> order.Gt
        }
    }
  })
}

/// Calculate effective weight considering starvation boost.
fn effective_weight(info: AgentInfo, now: Int) -> Int {
  case is_starved(info, now) {
    True -> types.priority_weight(boost_priority(info.priority))
    False -> types.priority_weight(info.priority)
  }
}

/// Check if an agent is currently starved.
fn is_starved(info: AgentInfo, now: Int) -> Bool {
  case info.last_run {
    0 -> True
    _ -> now - info.last_run > 30_000
  }
}

/// Boost a priority by one level (for starvation recovery).
fn boost_priority(priority: types.SchedulerPriority) -> types.SchedulerPriority {
  case priority {
    types.Low -> types.Normal
    types.Normal -> types.High
    types.High -> types.Critical
    types.Critical -> types.Critical
  }
}

/// Build a weighted list where each agent appears weight times.
/// Agents with budget <= 0 are excluded.
fn build_weighted_list(agents: List(AgentInfo), now: Int) -> List(AgentInfo) {
  list.flat_map(agents, fn(info) {
    let weight = effective_weight(info, now)
    list.repeat(info, weight)
  })
}

/// Drop the first n elements from a list.
fn list_drop(l: List(a), n: Int) -> List(a) {
  case n <= 0 {
    True -> l
    False ->
      case l {
        [] -> []
        [_, ..rest] -> list_drop(rest, n - 1)
      }
  }
}
