//// Core Agent module for Supernova
//// Implements the Actor pattern for managing agent state asynchronously.
////
//// This module provides a typed Agent that processes messages using Gleam's
//// actor system from gleam_otp. Agents maintain isolated state and can be
//// communicated with via message passing.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string

// ============================================================================
// Types
// ============================================================================

/// Agent status indicating the current state of the agent
pub type Status {
  /// Agent is starting up
  Starting
  /// Agent is ready to process messages
  Ready
  /// Agent is busy processing a message
  Busy
  /// Agent is stopping
  Stopping
  /// Agent has encountered an error
  StatusError(reason: String)
}

/// Configuration for an agent
pub type Config {
  Config(
    /// Unique identifier for the agent
    id: String,
    /// Agent name for human-readable identification
    name: String,
    /// Optional system prompt for LLM interactions
    system_prompt: Option(String),
    /// Maximum messages to keep in memory
    max_memory_size: Int,
  )
}

/// Memory entry storing conversation history
pub type MemoryEntry {
  MemoryEntry(role: String, content: String, timestamp: Int)
}

/// Agent state containing configuration, memory, and current status
pub type AgentState {
  AgentState(
    config: Config,
    memory: Dict(Int, MemoryEntry),
    memory_count: Int,
    status: Status,
  )
}

/// Messages that can be sent to an agent
pub type Message {
  /// Get the current status of the agent
  GetStatus(reply_to: Subject(Status))
  /// Get the agent's configuration
  GetConfig(reply_to: Subject(Config))
  /// Get the agent's memory (all entries)
  GetMemory(reply_to: Subject(Dict(Int, MemoryEntry)))
  /// Send a message to be processed by the agent
  SendMessage(
    reply_to: Subject(Result(Nil, String)),
    role: String,
    content: String,
  )
  /// Clear the agent's memory
  ClearMemory(reply_to: Subject(Nil))
  /// Update the agent's status
  SetStatus(reply_to: Subject(Nil), status: Status)
  /// Stop the agent gracefully
  Stop(reply_to: Subject(Nil))
}

/// A handle to a running agent
pub type Agent =
  Subject(Message)

// ============================================================================
// Logging Helpers
// ============================================================================

/// Log level for structured logging
type LogLevel {
  Debug
  Info
  Warning
  LogError
}

/// Format log level to string
fn log_level_to_string(level: LogLevel) -> String {
  case level {
    Debug -> "DEBUG"
    Info -> "INFO"
    Warning -> "WARN"
    LogError -> "ERROR"
  }
}

/// Format status to string for logging
fn format_status(status: Status) -> String {
  case status {
    Starting -> "starting"
    Ready -> "ready"
    Busy -> "busy"
    Stopping -> "stopping"
    StatusError(reason) -> "error: " <> reason
  }
}

/// Log a structured message (internal helper)
fn log(
  level: LogLevel,
  component: String,
  message: String,
  attrs: List(#(String, String)),
) -> String {
  let level_str = log_level_to_string(level)

  let attrs_str =
    attrs
    |> list.map(fn(pair) {
      let #(key, value) = pair
      key <> "=" <> value
    })
    |> string.join(" ")

  case attrs_str {
    "" -> "[" <> level_str <> "] [" <> component <> "] " <> message
    _ ->
      "["
      <> level_str
      <> "] ["
      <> component
      <> "] "
      <> message
      <> " | "
      <> attrs_str
  }
}

// ============================================================================
// Actor Implementation
// ============================================================================

/// Handle incoming messages and update state
fn handle_message(
  state: AgentState,
  message: Message,
) -> actor.Next(AgentState, Message) {
  case message {
    GetStatus(reply_to) -> {
      let _ =
        log(Debug, "agent", "GetStatus", [
          #("agent_id", state.config.id),
          #("status", format_status(state.status)),
        ])
      actor.send(reply_to, state.status)
      actor.continue(state)
    }

    GetConfig(reply_to) -> {
      let _ = log(Debug, "agent", "GetConfig", [#("agent_id", state.config.id)])
      actor.send(reply_to, state.config)
      actor.continue(state)
    }

    GetMemory(reply_to) -> {
      let _ =
        log(Debug, "agent", "GetMemory", [
          #("agent_id", state.config.id),
          #("count", int.to_string(state.memory_count)),
        ])
      actor.send(reply_to, state.memory)
      actor.continue(state)
    }

    SendMessage(reply_to, role, content) -> {
      let _ =
        log(Info, "agent", "SendMessage", [
          #("agent_id", state.config.id),
          #("role", role),
        ])

      // Check if memory is full
      case state.memory_count >= state.config.max_memory_size {
        True -> {
          let _ =
            log(Warning, "agent", "Memory full", [
              #("agent_id", state.config.id),
              #("max_size", int.to_string(state.config.max_memory_size)),
            ])
          actor.send(reply_to, Error("Memory full"))
          actor.continue(state)
        }
        False -> {
          // Create new memory entry
          let entry = MemoryEntry(role: role, content: content, timestamp: 0)

          // Add to memory
          let new_memory = dict.insert(state.memory, state.memory_count, entry)

          // Update state
          let new_state =
            AgentState(
              ..state,
              memory: new_memory,
              memory_count: state.memory_count + 1,
            )

          actor.send(reply_to, Ok(Nil))
          actor.continue(new_state)
        }
      }
    }

    ClearMemory(reply_to) -> {
      let _ =
        log(Info, "agent", "ClearMemory", [#("agent_id", state.config.id)])

      let new_state = AgentState(..state, memory: dict.new(), memory_count: 0)

      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    SetStatus(reply_to, status) -> {
      let _ =
        log(Info, "agent", "SetStatus", [
          #("agent_id", state.config.id),
          #("status", format_status(status)),
        ])

      let new_state = AgentState(..state, status: status)
      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    Stop(reply_to) -> {
      let _ = log(Info, "agent", "Stop", [#("agent_id", state.config.id)])
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Create a default configuration for an agent
pub fn default_config(id: String, name: String) -> Config {
  Config(id: id, name: name, system_prompt: None, max_memory_size: 100)
}

/// Create a configuration with custom settings
pub fn config_with_system_prompt(
  id: String,
  name: String,
  system_prompt: String,
) -> Config {
  Config(
    id: id,
    name: name,
    system_prompt: Some(system_prompt),
    max_memory_size: 100,
  )
}

/// Start a new agent with the given configuration.
/// Returns a Subject that can be used to send messages to the agent.
pub fn start(config: Config) -> Result(Agent, actor.StartError) {
  let initial_state =
    AgentState(
      config: config,
      memory: dict.new(),
      memory_count: 0,
      status: Starting,
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

/// Send a message to the agent asynchronously.
/// Returns Ok(Nil) on success, Error(reason) on failure.
pub fn send_message(
  agent: Agent,
  role: String,
  content: String,
) -> Result(Nil, String) {
  let reply_subject = process.new_subject()
  actor.send(agent, SendMessage(reply_subject, role, content))

  // Wait for reply with timeout
  case process.receive(reply_subject, 5000) {
    Ok(result) -> result
    Error(_) -> Error("Timeout waiting for agent response")
  }
}

/// Get the current status of the agent.
pub fn get_status(agent: Agent) -> Status {
  actor.call(agent, waiting: 1000, sending: GetStatus)
}

/// Get the agent's configuration.
pub fn get_config(agent: Agent) -> Config {
  actor.call(agent, waiting: 1000, sending: GetConfig)
}

/// Get the agent's memory (all entries).
pub fn get_memory(agent: Agent) -> Dict(Int, MemoryEntry) {
  actor.call(agent, waiting: 1000, sending: GetMemory)
}

/// Clear the agent's memory.
pub fn clear_memory(agent: Agent) -> Nil {
  actor.call(agent, waiting: 1000, sending: ClearMemory)
}

/// Update the agent's status.
pub fn set_status(agent: Agent, status: Status) -> Nil {
  actor.call(agent, waiting: 1000, sending: SetStatus(_, status))
}

/// Stop the agent gracefully.
pub fn stop(agent: Agent) -> Nil {
  actor.call(agent, waiting: 1000, sending: Stop)
}
