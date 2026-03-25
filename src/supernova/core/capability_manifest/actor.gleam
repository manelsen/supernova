//// Capability Manifest — Actor
////
//// Singleton actor that manages per-agent tool capability manifests.
//// Delegates pure logic to the pure module, executes side effects via FFI.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(caps) = actor.start("workspaces")
//// let assert True = actor.allowed(caps, "agent_1", "filesystem")
//// actor.stop(caps)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import supernova/core/capability_manifest/pure
import supernova/core/capability_manifest/types.{
  type CapabilityManifest, type CapabilityManifestState, CapabilityManifest,
}
import yay

// ============================================================================
// Types
// ============================================================================

/// Messages that the capability manifest actor handles.
pub type ManifestMessage {
  /// Check if a tool is allowed for an agent
  Allowed(reply_to: Subject(Bool), agent_id: String, tool_name: String)
  /// Get the capability manifest for an agent
  GetManifest(reply_to: Subject(CapabilityManifest), agent_id: String)
  /// Set the capability manifest for an agent
  SetManifest(
    reply_to: Subject(Nil),
    agent_id: String,
    manifest: CapabilityManifest,
  )
  /// Allow a tool for an agent
  AllowTool(reply_to: Subject(Nil), agent_id: String, tool_name: String)
  /// Deny a tool for an agent
  DenyTool(reply_to: Subject(Nil), agent_id: String, tool_name: String)
  /// List allowed tools for an agent
  ListAllowed(reply_to: Subject(List(String)), agent_id: String)
  /// List denied tools for an agent
  ListDenied(reply_to: Subject(List(String)), agent_id: String)
  /// Load manifest from CAPABILITIES.yaml for an agent
  LoadFromYaml(reply_to: Subject(Result(Nil, String)), agent_id: String)
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running capability manifest actor.
pub type CapabilityManifestHandle =
  Subject(ManifestMessage)

// ============================================================================
// YAML Parsing
// ============================================================================

/// Parse a list of strings from a YAML node key.
fn parse_string_list(node: yay.Node, key: String) -> List(String) {
  case yay.select_sugar(node, key) {
    Ok(yay.NodeSeq(items)) ->
      items
      |> list.filter_map(fn(item) {
        case item {
          yay.NodeStr(s) -> Ok(s)
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

/// Parse a CapabilityManifest from a YAML node.
fn parse_manifest_node(node: yay.Node) -> CapabilityManifest {
  let allowed = parse_string_list(node, "allowed_tools")
  let denied = parse_string_list(node, "denied_tools")
  CapabilityManifest(allowed_tools: allowed, denied_tools: denied)
}

/// Load a manifest from a YAML file path.
fn load_manifest_from_file(path: String) -> Result(CapabilityManifest, String) {
  case yay.parse_file(path) {
    Ok([doc]) -> {
      let root = yay.document_root(doc)
      Ok(parse_manifest_node(root))
    }
    Ok([]) -> Error("Empty YAML file: " <> path)
    Ok(_) -> Error("Multiple YAML documents in file: " <> path)
    Error(_) -> Error("Failed to parse YAML file: " <> path)
  }
}

// ============================================================================
// Actor Handler
// ============================================================================

/// Handle incoming messages and update state.
fn handle_message(
  state: CapabilityManifestState,
  message: ManifestMessage,
) -> actor.Next(CapabilityManifestState, ManifestMessage) {
  case message {
    Allowed(reply_to, agent_id, tool_name) -> {
      let is_allowed = pure.agent_allowed(state, agent_id, tool_name)
      actor.send(reply_to, is_allowed)
      actor.continue(state)
    }

    GetManifest(reply_to, agent_id) -> {
      let manifest = pure.for_agent(state, agent_id)
      actor.send(reply_to, manifest)
      actor.continue(state)
    }

    SetManifest(reply_to, agent_id, manifest) -> {
      let new_state = pure.set_manifest(state, agent_id, manifest)
      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    AllowTool(reply_to, agent_id, tool_name) -> {
      let new_state = pure.allow_tool(state, agent_id, tool_name)
      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    DenyTool(reply_to, agent_id, tool_name) -> {
      let new_state = pure.deny_tool(state, agent_id, tool_name)
      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    ListAllowed(reply_to, agent_id) -> {
      let tools = pure.list_allowed(state, agent_id)
      actor.send(reply_to, tools)
      actor.continue(state)
    }

    ListDenied(reply_to, agent_id) -> {
      let tools = pure.list_denied(state, agent_id)
      actor.send(reply_to, tools)
      actor.continue(state)
    }

    LoadFromYaml(reply_to, agent_id) -> {
      let path = state.workspace_root <> "/" <> agent_id <> "/CAPABILITIES.yaml"
      case load_manifest_from_file(path) {
        Ok(manifest) -> {
          let new_state = pure.set_manifest(state, agent_id, manifest)
          actor.send(reply_to, Ok(Nil))
          actor.continue(new_state)
        }
        Error(reason) -> {
          actor.send(reply_to, Error(reason))
          actor.continue(state)
        }
      }
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

/// Start the capability manifest actor with a given workspace root.
pub fn start(
  workspace_root: String,
) -> Result(CapabilityManifestHandle, actor.StartError) {
  let initial_state = types.initial_state(workspace_root)

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Check if a tool is allowed for an agent.
pub fn allowed(
  manifest: CapabilityManifestHandle,
  agent_id: String,
  tool_name: String,
) -> Bool {
  actor.call(manifest, waiting: 5000, sending: Allowed(_, agent_id, tool_name))
}

/// Get the capability manifest for an agent.
pub fn get_manifest(
  manifest: CapabilityManifestHandle,
  agent_id: String,
) -> CapabilityManifest {
  actor.call(manifest, waiting: 5000, sending: GetManifest(_, agent_id))
}

/// Set the capability manifest for an agent.
pub fn set_manifest(
  manifest: CapabilityManifestHandle,
  agent_id: String,
  caps: CapabilityManifest,
) -> Nil {
  actor.call(manifest, waiting: 5000, sending: SetManifest(_, agent_id, caps))
}

/// Allow a tool for an agent.
pub fn allow_tool(
  manifest: CapabilityManifestHandle,
  agent_id: String,
  tool_name: String,
) -> Nil {
  actor.call(manifest, waiting: 5000, sending: AllowTool(_, agent_id, tool_name))
}

/// Deny a tool for an agent.
pub fn deny_tool(
  manifest: CapabilityManifestHandle,
  agent_id: String,
  tool_name: String,
) -> Nil {
  actor.call(manifest, waiting: 5000, sending: DenyTool(_, agent_id, tool_name))
}

/// List all allowed tools for an agent.
pub fn list_allowed(
  manifest: CapabilityManifestHandle,
  agent_id: String,
) -> List(String) {
  actor.call(manifest, waiting: 5000, sending: ListAllowed(_, agent_id))
}

/// List all denied tools for an agent.
pub fn list_denied(
  manifest: CapabilityManifestHandle,
  agent_id: String,
) -> List(String) {
  actor.call(manifest, waiting: 5000, sending: ListDenied(_, agent_id))
}

/// Load manifest from CAPABILITIES.yaml for an agent.
pub fn load_from_yaml(
  manifest: CapabilityManifestHandle,
  agent_id: String,
) -> Result(Nil, String) {
  actor.call(manifest, waiting: 5000, sending: LoadFromYaml(_, agent_id))
}

/// Stop the capability manifest actor.
pub fn stop(manifest: CapabilityManifestHandle) -> Nil {
  actor.call(manifest, waiting: 5000, sending: Stop)
}
