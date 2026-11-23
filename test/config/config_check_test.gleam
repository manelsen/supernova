import envoy
import gleam/list
import gleam/string
import gleeunit/should

@external(erlang, "isolation_test_ffi", "read_file")
fn read_file(path: String) -> String

import supernova/config
import supernova/config_check
import supernova/core/tool_dispatch

fn parsed(yaml: String) -> config.Config {
  let assert Ok(cfg) = config.parse_yaml(yaml)
  cfg
}

fn has_error(issues: List(config_check.ConfigIssue), fragment: String) -> Bool {
  list.any(issues, fn(issue) {
    issue.level == config_check.Error
    && string.contains(issue.message, fragment)
  })
}

fn has_warning(
  issues: List(config_check.ConfigIssue),
  fragment: String,
) -> Bool {
  list.any(issues, fn(issue) {
    issue.level == config_check.Warning
    && string.contains(issue.message, fragment)
  })
}

pub fn malformed_principals_are_errors_test() {
  let cfg =
    parsed(string.join(
      [
        "access:",
        "  admins: [\"telegram\", \"slack:1\"]",
        "  members: [\"discord:\", \"telegram:1:2\"]",
      ],
      "\n",
    ))
  let issues = config_check.check(cfg)
  should.be_true(has_error(issues, "access.admins"))
  should.be_true(has_error(issues, "access.members"))
}

pub fn malformed_chat_id_is_error_test() {
  let cfg =
    parsed(string.join(
      [
        "access:",
        "  allowed_chats: [\"telegram:-1\", \"matrix:room\", \"discord:guild:\"]",
      ],
      "\n",
    ))
  let issues = config_check.check(cfg)
  should.be_true(has_error(issues, "access.allowed_chats"))
}

pub fn unknown_capability_tool_is_error_test() {
  let cfg =
    parsed(string.join(
      [
        "capabilities:",
        "  member:",
        "    allowed: [\"web\", \"no_such_tool\"]",
        "    denied: [\"also_missing\"]",
      ],
      "\n",
    ))
  let issues = config_check.check(cfg)
  should.be_true(has_error(issues, "no_such_tool"))
  should.be_true(has_error(issues, "also_missing"))
}

pub fn negative_non_minus_one_is_error_test() {
  let cfg =
    parsed(string.join(
      [
        "budget:",
        "  member: { tokens_per_hour: -2, tool_calls_per_hour: 5 }",
        "rate_limit:",
        "  member: { messages_per_minute: -3 }",
        "instance_budget:",
        "  daily_usd: -2.0",
      ],
      "\n",
    ))
  let issues = config_check.check(cfg)
  should.be_true(has_error(issues, "tokens_per_hour"))
  should.be_true(has_error(issues, "messages_per_minute"))
  should.be_true(has_error(issues, "daily_usd"))
}

pub fn empty_allowlist_is_warning_test() {
  let cfg = parsed("access:\n  mode: allowlist\n")
  let issues = config_check.check(cfg)
  should.be_true(has_warning(issues, "allowlist is empty, nobody can use"))
  should.be_true(config_check.is_bootable(issues))
}

pub fn allowlist_with_members_but_no_admins_warns_test() {
  let cfg = parsed("access:\n  mode: allowlist\n  members: [\"telegram:1\"]\n")
  let issues = config_check.check(cfg)
  should.be_true(has_warning(issues, "no admins"))
}

pub fn experimental_enabled_channel_is_warning_test() {
  let cfg =
    parsed(string.join(["slack:", "  token: \"x\"", "  enabled: true"], "\n"))
  let issues = config_check.check(cfg)
  should.be_true(has_warning(issues, "slack is experimental"))
}

pub fn unlimited_instance_budget_is_warning_test() {
  let cfg = parsed("instance_budget:\n  daily_usd: -1.0\n")
  let issues = config_check.check(cfg)
  should.be_true(has_warning(issues, "no daily spend cap"))
}

pub fn workspace_root_env_is_ignored_with_a_warning_in_closed_groups_test() {
  envoy.set("SUPERNOVA_WORKSPACE_ROOT", "/tmp/legacy-workspaces")
  let cfg = parsed("access:\n  mode: allowlist\n  admins: [\"telegram:123\"]\n")
  let issues = config_check.check(cfg)
  should.be_true(has_warning(issues, "SUPERNOVA_WORKSPACE_ROOT is ignored"))
  envoy.unset("SUPERNOVA_WORKSPACE_ROOT")
}

pub fn workspace_root_follows_access_mode_test() {
  let closed = parsed("data_dir: /dados\naccess:\n  mode: allowlist\n")
  config.workspace_root(closed) |> should.equal("/dados/agents")
  let open = parsed("data_dir: /dados\naccess:\n  mode: open\n")
  config.workspace_root(open) |> should.equal("/dados/workspace")
}

pub fn sim_chat_id_is_a_valid_allowed_chat_test() {
  let cfg =
    parsed(
      "access:\n  mode: allowlist\n  admins: [\"telegram:1\"]\n  allowed_chats: [\"sim:group-1\"]\n",
    )
  let issues = config_check.check(cfg)
  has_error(issues, "allowed_chats") |> should.equal(False)
}

pub fn valid_closed_group_config_is_bootable_test() {
  let cfg =
    parsed(string.join(
      [
        "access:",
        "  mode: allowlist",
        "  admins: [\"telegram:123\"]",
        "  members: [\"discord:456\"]",
        "  allowed_chats: [\"telegram:-1001\", \"discord:guild:789\"]",
        "capabilities:",
        "  member:",
        "    allowed: [\"web\", \"file_system\"]",
        "    denied: [\"safe_shell\"]",
        "  admin:",
        "    allowed: [\"*\"]",
        "    denied: []",
        "budget:",
        "  member: { tokens_per_hour: 50000, tool_calls_per_hour: 60 }",
        "  admin: { tokens_per_hour: -1, tool_calls_per_hour: -1 }",
        "rate_limit:",
        "  member: { messages_per_minute: 10 }",
        "  admin: { messages_per_minute: -1 }",
        "instance_budget:",
        "  daily_usd: 5.0",
      ],
      "\n",
    ))
  let issues = config_check.check(cfg)
  should.equal(config_check.is_bootable(issues), True)
  should.equal(
    list.filter(issues, fn(issue) { issue.level == config_check.Error }),
    [],
  )
}

pub fn format_lists_every_issue_test() {
  let cfg = parsed("access:\n  members: [\"bad\"]\n")
  let text = config_check.format_issues(config_check.check(cfg))
  should.be_true(string.contains(text, "ERROR:"))
  should.be_true(string.contains(text, "WARN:"))
}

pub fn example_config_is_bootable_test() {
  let yaml = read_file("supernova.yaml.example")
  let assert Ok(cfg) = config.parse_yaml(yaml)
  let issues = config_check.check(cfg)
  should.equal(config_check.is_bootable(issues), True)
  should.equal(config_check.exit_code(issues), 0)
}

pub fn errors_produce_exit_code_one_test() {
  let cfg = parsed("access:\n  admins: [\"bad\"]\n")
  let issues = config_check.check(cfg)
  should.equal(config_check.exit_code(issues), 1)
}

// A new built-in tool must also be a known capability name, or listing it in
// supernova.yaml makes the configuration check fail.
pub fn every_builtin_tool_is_a_known_capability_test() {
  let known = config_check.known_tool_names()
  tool_dispatch.builtin_tools()
  |> list.filter(fn(tool) { !list.contains(known, tool.name) })
  |> list.map(fn(tool) { tool.name })
  |> should.equal([])
}

pub fn conversation_history_limit_test() {
  parsed("data_dir: d\n").conversation.history_limit |> should.equal(100)
  parsed("conversation:\n  history_limit: 12\n").conversation.history_limit
  |> should.equal(12)
  // Below 2 there is no exchange to keep.
  parsed("conversation:\n  history_limit: 0\n").conversation.history_limit
  |> should.equal(2)
  let assert Ok(example) =
    config.parse_yaml(read_file("supernova.yaml.example"))
  example.conversation.history_limit |> should.equal(100)
}
