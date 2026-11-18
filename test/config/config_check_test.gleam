import gleam/list
import gleam/string
import gleeunit/should

@external(erlang, "isolation_test_ffi", "read_file")
fn read_file(path: String) -> String

import supernova/config
import supernova/config_check

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
        "  members: [\"discord:\"]",
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
        "    denied: []",
      ],
      "\n",
    ))
  let issues = config_check.check(cfg)
  should.be_true(has_error(issues, "no_such_tool"))
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
  should.be_true(has_warning(issues, "no admins"))
  should.be_true(config_check.is_bootable(issues))
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
