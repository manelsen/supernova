//// Slots of tool calls in flight, per tool and per agent (PRD-F, F-03, D2).
////
//// | Tool | Per agent | In the instance |
//// |---|---|---|
//// | `computador` | 2 | 8 |
//// | `browser`, `web` | 4 | 32 |
//// | every other | 8 | 64 |
////
//// The counters live in ETS and change with `update_counter`: taking a slot
//// never goes through a process, so a busy tool cannot slow the others
//// down (I5).

pub type Limits {
  Limits(per_agent: Int, instance: Int)
}

/// How long a call waits for a slot before the model is told the tool is
/// busy.
pub const default_wait_ms = 10_000

pub const busy_message =
  "a ferramenta está ocupada; tente de novo ou siga sem ela"

pub fn limits_for(tool: String) -> Limits {
  case tool {
    "computador" -> Limits(per_agent: 2, instance: 8)
    "browser" | "web" | "web_fetch" -> Limits(per_agent: 4, instance: 32)
    _ -> Limits(per_agent: 8, instance: 64)
  }
}

/// A slot taken for one call; give it back when the call ends.
pub opaque type Slot {
  Slot(agent_key: #(String, String, String), instance_key: #(String, String))
}

/// Take a slot of `tool` for `agent`, if both the agent's and the
/// instance's are free.
pub fn try_take(tool: String, agent: String) -> Result(Slot, Nil) {
  let limits = limits_for(tool)
  let agent_key = #("agent", tool, agent)
  let instance_key = #("instance", tool)
  case take(agent_key, limits.per_agent) {
    False -> Error(Nil)
    True ->
      case take(instance_key, limits.instance) {
        True -> Ok(Slot(agent_key: agent_key, instance_key: instance_key))
        False -> {
          give_back_key(agent_key)
          Error(Nil)
        }
      }
  }
}

pub fn give_back(slot: Slot) -> Nil {
  give_back_key(slot.instance_key)
  give_back_key(slot.agent_key)
}

/// A call of `tool` starts waiting for a slot; returns how many wait now.
pub fn wait_started(tool: String) -> Int {
  let _ = take(#("waiting", tool), 1_000_000_000)
  count(#("waiting", tool))
}

/// A call of `tool` stops waiting; returns how many still wait.
pub fn wait_ended(tool: String) -> Int {
  give_back_key(#("waiting", tool))
  count(#("waiting", tool))
}

/// Calls of `tool` running in the whole instance.
pub fn running(tool: String) -> Int {
  count(#("instance", tool))
}

/// Calls of `tool` running for `agent`.
pub fn running_for(tool: String, agent: String) -> Int {
  count(#("agent", tool, agent))
}

@external(erlang, "supernova_tool_slots_ffi", "take")
fn take(key: key, limit: Int) -> Bool

@external(erlang, "supernova_tool_slots_ffi", "give_back")
fn give_back_key(key: key) -> Nil

@external(erlang, "supernova_tool_slots_ffi", "count")
fn count(key: key) -> Int
