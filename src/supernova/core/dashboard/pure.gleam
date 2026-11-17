//// Dashboard — Pure Functions
////
//// Pure functions for rendering the Supernova system dashboard.
//// No FFI, no side effects. Takes dashboard data and returns formatted string.
////
//// ## Usage
////
//// ```gleam
//// let data = DashboardData(...)
//// let output = render(data)
//// ```

import gleam/int
import gleam/list
import gleam/string
import supernova/core/kernel_scheduler/types as scheduler_types

// ============================================================================
// Types
// ============================================================================

/// Information about a single agent for the dashboard.
pub type DashboardAgentInfo {
  DashboardAgentInfo(
    agent_id: String,
    status: String,
    priority: String,
    budget_remaining: Int,
    llm_tokens_total: Int,
    tool_calls_total: Int,
  )
}

/// Dashboard data containing all system metrics to render.
pub type DashboardData {
  DashboardData(
    /// Kernel version string (e.g., "1.0.0")
    kernel_version: String,
    /// System uptime in milliseconds
    uptime_ms: Int,
    /// List of active agents with their metrics
    agents: List(DashboardAgentInfo),
    /// World Model statistics
    world_model_stats: WorldModelStats,
    /// System start timestamp (ms)
    started_at_ms: Int,
  )
}

/// Statistics from the World Model.
pub type WorldModelStats {
  WorldModelStats(
    /// Total number of facts (including tombstoned)
    total_facts: Int,
    /// Number of active (non-tombstoned) facts
    active_facts: Int,
    /// Current world model version
    version: Int,
  )
}

// ============================================================================
// Public API
// ============================================================================

/// Render the dashboard as a formatted text panel.
///
/// Takes DashboardData containing all system metrics and produces
/// a human-readable text dashboard with sections for:
/// - Header with kernel version and uptime
/// - Active agents table with budgets
/// - World Model statistics
pub fn render(data: DashboardData) -> String {
  let header =
    render_header(data.kernel_version, data.uptime_ms, data.started_at_ms)
  let agents_section = render_agents(data.agents)
  let world_model_section = render_world_model(data.world_model_stats)

  string.join([header, agents_section, world_model_section], "\n")
}

// ============================================================================
// Internal Rendering Functions
// ============================================================================

/// Render the dashboard header with kernel version and uptime.
fn render_header(
  version: String,
  uptime_ms: Int,
  _started_at_ms: Int,
) -> String {
  let uptime_str = format_uptime(uptime_ms)
  string.join(
    [
      "╔══════════════════════════════════════════════════════════════════╗",
      "║                  Supernova System Dashboard                     ║",
      "╠══════════════════════════════════════════════════════════════════╣",
      "║ Kernel Version: " <> pad_right(version, 44) <> "║",
      "║ Uptime: " <> pad_right(uptime_str, 48) <> "║",
      "╚══════════════════════════════════════════════════════════════════╝",
    ],
    "\n",
  )
}

/// Render the agents section as a table.
fn render_agents(agents: List(DashboardAgentInfo)) -> String {
  case list.is_empty(agents) {
    True ->
      "\n── Active Agents (0) ──────────────────────────────────────────────\n   No active agents"
    False -> {
      let header_row =
        "   AGENT ID          STATUS      PRIORITY   BUDGET   TOKENS   TOOLS"
      let separator = "   " <> string.repeat("-", 66)
      let agent_rows =
        list.map(agents, fn(agent) {
          let budget_str = case agent.budget_remaining {
            -1 -> "unlimited"
            n -> int.to_string(n)
          }
          let row =
            "   "
            <> pad_right(agent.agent_id, 17)
            <> " "
            <> pad_right(agent.status, 10)
            <> " "
            <> pad_right(agent.priority, 9)
            <> " "
            <> pad_right(budget_str, 7)
            <> " "
            <> pad_right(int.to_string(agent.llm_tokens_total), 6)
            <> " "
            <> int.to_string(agent.tool_calls_total)
          row
        })
        |> string.join("\n")

      "\n── Active Agents ("
      <> int.to_string(list.length(agents))
      <> ") ──────────────────────────────────────────────\n"
      <> header_row
      <> "\n"
      <> separator
      <> "\n"
      <> agent_rows
    }
  }
}

/// Render the World Model statistics section.
fn render_world_model(stats: WorldModelStats) -> String {
  string.join(
    [
      "\n── World Model ────────────────────────────────────────────────────",
      "   Version: " <> int.to_string(stats.version),
      "   Total Facts: " <> int.to_string(stats.total_facts),
      "   Active Facts: " <> int.to_string(stats.active_facts),
    ],
    "\n",
  )
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Pad a string on the right with spaces to reach the target length.
fn pad_right(s: String, length: Int) -> String {
  let s_len = string.length(s)
  case s_len >= length {
    True -> s
    False -> s <> string.repeat(" ", length - s_len)
  }
}

/// Format uptime in milliseconds to a human-readable string.
fn format_uptime(ms: Int) -> String {
  let total_seconds = ms / 1000
  let days = total_seconds / 86_400
  let hours = { total_seconds % 86_400 } / 3600
  let minutes = { total_seconds % 3600 } / 60
  let seconds = total_seconds % 60

  case days > 0 {
    True ->
      int.to_string(days)
      <> "d "
      <> int.to_string(hours)
      <> "h "
      <> int.to_string(minutes)
      <> "m "
      <> int.to_string(seconds)
      <> "s"
    False ->
      case hours > 0 {
        True ->
          int.to_string(hours)
          <> "h "
          <> int.to_string(minutes)
          <> "m "
          <> int.to_string(seconds)
          <> "s"
        False ->
          case minutes > 0 {
            True ->
              int.to_string(minutes) <> "m " <> int.to_string(seconds) <> "s"
            False -> int.to_string(seconds) <> "s"
          }
      }
  }
}

/// Convert scheduler AgentStatus to a display string.
pub fn status_to_string(status: scheduler_types.AgentStatus) -> String {
  case status {
    scheduler_types.Idle -> "idle"
    scheduler_types.Running -> "running"
    scheduler_types.Starved -> "starved"
    scheduler_types.Exhausted -> "exhausted"
  }
}

/// Convert scheduler SchedulerPriority to a display string.
pub fn priority_to_string(
  priority: scheduler_types.SchedulerPriority,
) -> String {
  scheduler_types.priority_to_string(priority)
}

/// Create DashboardAgentInfo from scheduler and ledger data.
pub fn agent_info_from_parts(
  agent_id: String,
  status: scheduler_types.AgentStatus,
  priority: scheduler_types.SchedulerPriority,
  budget_remaining: Int,
  llm_tokens: Int,
  tool_calls: Int,
) -> DashboardAgentInfo {
  DashboardAgentInfo(
    agent_id: agent_id,
    status: status_to_string(status),
    priority: priority_to_string(priority),
    budget_remaining: budget_remaining,
    llm_tokens_total: llm_tokens,
    tool_calls_total: tool_calls,
  )
}
