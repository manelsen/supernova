//// Config Check — pure validation of closed-group configuration.
////
//// Runs at boot: errors prevent startup, warnings are logged and startup
//// continues. `bin/supernova check-config` uses the same rules.

import gleam/int
import gleam/list
import gleam/string
import supernova/config
import supernova/core/principal

/// Severity of a configuration issue.
pub type IssueLevel {
  Error
  Warning
}

/// One configuration problem.
pub type ConfigIssue {
  ConfigIssue(level: IssueLevel, message: String)
}

/// Tools known to the built-in registry. Keep in sync with tool_dispatch.
pub fn known_tool_names() -> List(String) {
  [
    "safe_shell",
    "browser",
    "canvas",
    "gateway",
    "process",
    "github",
    "web",
    "web_fetch",
    "git_inspect",
    "file_system",
  ]
}

/// Validate access, budget, capability and instance configuration.
pub fn check(config: config.Config) -> List(ConfigIssue) {
  list.flatten([
    check_principals("access.admins", config.access.admins),
    check_principals("access.members", config.access.members),
    check_chats(config.access.allowed_chats),
    check_capabilities(config.capabilities),
    check_non_negative(
      config.role_budgets.member.tokens_per_hour,
      "budget.member.tokens_per_hour",
    ),
    check_non_negative(
      config.role_budgets.member.tool_calls_per_hour,
      "budget.member.tool_calls_per_hour",
    ),
    check_non_negative(
      config.role_budgets.admin.tokens_per_hour,
      "budget.admin.tokens_per_hour",
    ),
    check_non_negative(
      config.role_budgets.admin.tool_calls_per_hour,
      "budget.admin.tool_calls_per_hour",
    ),
    check_non_negative(
      config.rate_limit.member.messages_per_minute,
      "rate_limit.member.messages_per_minute",
    ),
    check_non_negative(
      config.rate_limit.admin.messages_per_minute,
      "rate_limit.admin.messages_per_minute",
    ),
    check_non_negative_float(
      config.instance_budget.daily_usd,
      "instance_budget.daily_usd",
    ),
    warnings(config),
  ])
}

fn check_principals(field: String, ids: List(String)) -> List(ConfigIssue) {
  ids
  |> list.filter(fn(id) { !principal.is_valid_id(id) })
  |> list.map(fn(id) {
    ConfigIssue(
      level: Error,
      message: field
        <> ": invalid principal id '"
        <> id
        <> "' (expected telegram:<id> or discord:<id>)",
    )
  })
}

fn check_chats(chats: List(String)) -> List(ConfigIssue) {
  chats
  |> list.filter(fn(chat) { !valid_chat_id(chat) })
  |> list.map(fn(chat) {
    ConfigIssue(
      level: Error,
      message: "access.allowed_chats: invalid chat id '"
        <> chat
        <> "' (expected telegram:<id> or discord:guild:<id>)",
    )
  })
}

fn valid_chat_id(chat: String) -> Bool {
  case string.starts_with(chat, "telegram:") {
    True -> string.length(chat) > string.length("telegram:")
    False ->
      case string.starts_with(chat, "discord:guild:") {
        True -> string.length(chat) > string.length("discord:guild:")
        False -> False
      }
  }
}

fn check_capabilities(
  capabilities: config.CapabilitiesConfig,
) -> List(ConfigIssue) {
  let known = known_tool_names()
  [capabilities.member, capabilities.admin]
  |> list.flat_map(fn(role) {
    list.append(role.allowed, role.denied)
    |> list.filter(fn(name) { name != "*" && !list.contains(known, name) })
    |> list.unique
    |> list.map(fn(name) {
      ConfigIssue(
        level: Error,
        message: "capabilities: unknown tool '" <> name <> "'",
      )
    })
  })
}

fn check_non_negative(value: Int, field: String) -> List(ConfigIssue) {
  case value < 0 && value != -1 {
    True -> [
      ConfigIssue(
        level: Error,
        message: field
          <> ": negative value "
          <> int.to_string(value)
          <> " (use -1 for unlimited)",
      ),
    ]
    False -> []
  }
}

fn check_non_negative_float(value: Float, field: String) -> List(ConfigIssue) {
  case value <. 0.0 && value != -1.0 {
    True -> [
      ConfigIssue(
        level: Error,
        message: field <> ": negative value (use -1 for no cap)",
      ),
    ]
    False -> []
  }
}

fn warnings(config: config.Config) -> List(ConfigIssue) {
  let access_warning = case config.access.mode {
    config.Allowlist ->
      case config.access.admins, config.access.members {
        [], [] -> [
          ConfigIssue(
            level: Warning,
            message: "access: allowlist is empty, nobody can use this instance",
          ),
        ]
        [], _ -> [
          ConfigIssue(
            level: Warning,
            message: "access: allowlist has no admins, nobody can administer this instance",
          ),
        ]
        _, _ -> []
      }
    config.Open -> []
  }

  let channel_warnings =
    config.channel_names()
    |> list.filter(fn(channel) {
      config.channel_support(channel) == config.Experimental
      && config.is_channel_enabled(config, channel)
    })
    |> list.map(fn(channel) {
      ConfigIssue(
        level: Warning,
        message: "channel " <> channel <> " is experimental",
      )
    })

  let cap_warning = case config.instance_budget.daily_usd == -1.0 {
    True -> [
      ConfigIssue(
        level: Warning,
        message: "instance_budget.daily_usd = -1: the instance has no daily spend cap",
      ),
    ]
    False -> []
  }

  list.flatten([access_warning, channel_warnings, cap_warning])
}

/// True when no issue has Error level.
pub fn is_bootable(issues: List(ConfigIssue)) -> Bool {
  !list.any(issues, fn(issue) { issue.level == Error })
}

/// Process exit code for a configuration report.
pub fn exit_code(issues: List(ConfigIssue)) -> Int {
  case is_bootable(issues) {
    True -> 0
    False -> 1
  }
}

/// Human-readable rendering, one issue per line.
pub fn format_issues(issues: List(ConfigIssue)) -> String {
  issues
  |> list.map(fn(issue) {
    let level = case issue.level {
      Error -> "ERROR"
      Warning -> "WARN"
    }
    level <> ": " <> issue.message
  })
  |> string.join("\n")
}
