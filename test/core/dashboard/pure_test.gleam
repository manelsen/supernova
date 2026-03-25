import gleam/string
import gleeunit/should
import supernova/core/dashboard/pure
import supernova/core/kernel_scheduler/types as scheduler_types

// ---------------------------------------------------------------------------
// render — basic structure
// ---------------------------------------------------------------------------

pub fn render_includes_dashboard_header_test() {
  let data = minimal_data()
  let output = pure.render(data)
  should.be_true(string.contains(output, "Supernova System Dashboard"))
}

pub fn render_includes_kernel_version_test() {
  let data = minimal_data()
  let output = pure.render(data)
  should.be_true(string.contains(output, "Kernel Version: 1.0.0"))
}

pub fn render_includes_uptime_test() {
  let data = minimal_data()
  let output = pure.render(data)
  should.be_true(string.contains(output, "Uptime:"))
}

pub fn render_includes_world_model_section_test() {
  let data = minimal_data()
  let output = pure.render(data)
  should.be_true(string.contains(output, "World Model"))
  should.be_true(string.contains(output, "Version:"))
  should.be_true(string.contains(output, "Total Facts:"))
  should.be_true(string.contains(output, "Active Facts:"))
}

// ---------------------------------------------------------------------------
// render — agents section
// ---------------------------------------------------------------------------

pub fn render_empty_agents_shows_no_active_agents_test() {
  let data = minimal_data()
  let output = pure.render(data)
  should.be_true(string.contains(output, "Active Agents (0)"))
  should.be_true(string.contains(output, "No active agents"))
}

pub fn render_with_agents_shows_agent_count_test() {
  let data = data_with_agents()
  let output = pure.render(data)
  should.be_true(string.contains(output, "Active Agents (2)"))
}

pub fn render_with_agents_shows_agent_id_test() {
  let data = data_with_agents()
  let output = pure.render(data)
  should.be_true(string.contains(output, "agent_alpha"))
  should.be_true(string.contains(output, "agent_beta"))
}

pub fn render_with_agents_shows_agent_status_test() {
  let data = data_with_agents()
  let output = pure.render(data)
  should.be_true(string.contains(output, "running"))
  should.be_true(string.contains(output, "idle"))
}

pub fn render_with_agents_shows_agent_priority_test() {
  let data = data_with_agents()
  let output = pure.render(data)
  should.be_true(string.contains(output, "high"))
  should.be_true(string.contains(output, "normal"))
}

pub fn render_with_agents_shows_budget_test() {
  let data = data_with_agents()
  let output = pure.render(data)
  // agent_alpha has budget_remaining: 50
  should.be_true(string.contains(output, "50"))
  // agent_beta has unlimited (-1)
  should.be_true(string.contains(output, "unlimited"))
}

pub fn render_with_agents_shows_token_count_test() {
  let data = data_with_agents()
  let output = pure.render(data)
  // agent_alpha has 1500 tokens
  should.be_true(string.contains(output, "1500"))
  // agent_beta has 500 tokens
  should.be_true(string.contains(output, "500"))
}

pub fn render_with_agents_shows_tool_calls_test() {
  let data = data_with_agents()
  let output = pure.render(data)
  // agent_alpha has 12 tool calls
  should.be_true(string.contains(output, "12"))
  // agent_beta has 5 tool calls
  should.be_true(string.contains(output, "5"))
}

// ---------------------------------------------------------------------------
// render — world model stats
// ---------------------------------------------------------------------------

pub fn render_shows_world_model_version_test() {
  let data = data_with_world_model_stats(42, 10, 8)
  let output = pure.render(data)
  should.be_true(string.contains(output, "Version: 42"))
}

pub fn render_shows_world_model_total_facts_test() {
  let data = data_with_world_model_stats(42, 10, 8)
  let output = pure.render(data)
  should.be_true(string.contains(output, "Total Facts: 10"))
}

pub fn render_shows_world_model_active_facts_test() {
  let data = data_with_world_model_stats(42, 10, 8)
  let output = pure.render(data)
  should.be_true(string.contains(output, "Active Facts: 8"))
}

// ---------------------------------------------------------------------------
// format uptime
// ---------------------------------------------------------------------------

pub fn render_shows_uptime_in_seconds_test() {
  // 30 seconds = 30000ms
  let data = minimal_data() |> with_uptime(30_000)
  let output = pure.render(data)
  should.be_true(string.contains(output, "30s"))
}

pub fn render_shows_uptime_in_minutes_test() {
  // 5 minutes = 300000ms
  let data = minimal_data() |> with_uptime(300_000)
  let output = pure.render(data)
  should.be_true(string.contains(output, "5m"))
}

pub fn render_shows_uptime_in_hours_test() {
  // 3 hours = 10800000ms
  let data = minimal_data() |> with_uptime(10_800_000)
  let output = pure.render(data)
  should.be_true(string.contains(output, "3h"))
}

pub fn render_shows_uptime_in_days_test() {
  // 2 days = 172800000ms
  let data = minimal_data() |> with_uptime(172_800_000)
  let output = pure.render(data)
  should.be_true(string.contains(output, "2d"))
}

// ---------------------------------------------------------------------------
// status_to_string
// ---------------------------------------------------------------------------

pub fn status_to_string_idle_test() {
  let result = pure.status_to_string(scheduler_types.Idle)
  should.equal(result, "idle")
}

pub fn status_to_string_running_test() {
  let result = pure.status_to_string(scheduler_types.Running)
  should.equal(result, "running")
}

pub fn status_to_string_starved_test() {
  let result = pure.status_to_string(scheduler_types.Starved)
  should.equal(result, "starved")
}

pub fn status_to_string_exhausted_test() {
  let result = pure.status_to_string(scheduler_types.Exhausted)
  should.equal(result, "exhausted")
}

// ---------------------------------------------------------------------------
// priority_to_string
// ---------------------------------------------------------------------------

pub fn priority_to_string_critical_test() {
  let result = pure.priority_to_string(scheduler_types.Critical)
  should.equal(result, "critical")
}

pub fn priority_to_string_high_test() {
  let result = pure.priority_to_string(scheduler_types.High)
  should.equal(result, "high")
}

pub fn priority_to_string_normal_test() {
  let result = pure.priority_to_string(scheduler_types.Normal)
  should.equal(result, "normal")
}

pub fn priority_to_string_low_test() {
  let result = pure.priority_to_string(scheduler_types.Low)
  should.equal(result, "low")
}

// ---------------------------------------------------------------------------
// agent_info_from_parts
// ---------------------------------------------------------------------------

pub fn agent_info_from_parts_creates_correct_info_test() {
  let result =
    pure.agent_info_from_parts(
      "test_agent",
      scheduler_types.Running,
      scheduler_types.High,
      100,
      2000,
      15,
    )
  should.equal(result.agent_id, "test_agent")
  should.equal(result.status, "running")
  should.equal(result.priority, "high")
  should.equal(result.budget_remaining, 100)
  should.equal(result.llm_tokens_total, 2000)
  should.equal(result.tool_calls_total, 15)
}

pub fn agent_info_from_parts_with_unlimited_budget_test() {
  let result =
    pure.agent_info_from_parts(
      "unlimited_agent",
      scheduler_types.Idle,
      scheduler_types.Normal,
      -1,
      0,
      0,
    )
  should.equal(result.budget_remaining, -1)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn minimal_data() -> pure.DashboardData {
  pure.DashboardData(
    kernel_version: "1.0.0",
    uptime_ms: 0,
    agents: [],
    world_model_stats: pure.WorldModelStats(
      total_facts: 0,
      active_facts: 0,
      version: 0,
    ),
    started_at_ms: 0,
  )
}

fn data_with_agents() -> pure.DashboardData {
  pure.DashboardData(
    kernel_version: "1.0.0",
    uptime_ms: 3_600_000,
    agents: [
      pure.DashboardAgentInfo(
        agent_id: "agent_alpha",
        status: "running",
        priority: "high",
        budget_remaining: 50,
        llm_tokens_total: 1500,
        tool_calls_total: 12,
      ),
      pure.DashboardAgentInfo(
        agent_id: "agent_beta",
        status: "idle",
        priority: "normal",
        budget_remaining: -1,
        llm_tokens_total: 500,
        tool_calls_total: 5,
      ),
    ],
    world_model_stats: pure.WorldModelStats(
      total_facts: 10,
      active_facts: 8,
      version: 42,
    ),
    started_at_ms: 0,
  )
}

fn data_with_world_model_stats(
  version: Int,
  total: Int,
  active: Int,
) -> pure.DashboardData {
  pure.DashboardData(
    kernel_version: "1.0.0",
    uptime_ms: 0,
    agents: [],
    world_model_stats: pure.WorldModelStats(
      total_facts: total,
      active_facts: active,
      version: version,
    ),
    started_at_ms: 0,
  )
}

fn with_uptime(data: pure.DashboardData, uptime_ms: Int) -> pure.DashboardData {
  pure.DashboardData(
    kernel_version: data.kernel_version,
    uptime_ms: uptime_ms,
    agents: data.agents,
    world_model_stats: data.world_model_stats,
    started_at_ms: data.started_at_ms,
  )
}
