//// SafeShell — secure shell command execution.
////
//// Executes shell commands with security constraints:
//// - Whitelist of allowed commands
//// - Blocks shell operators (;, |, &&, $(), etc.)
//// - Timeout protection
////
//// ## Usage
////
//// ```gleam
//// let result = safe_shell.execute("ls -la")
//// // With workspace policy:
//// let result = safe_shell.execute_authorized(policy, "agent_1", "ls -la")
//// ```

import gleam/list
import gleam/string
import supernova/core/workspace_guard
import supernova/core/workspace_policy/actor as policy_actor
import supernova/core/workspace_policy/types.{OpShell}
import supernova/llm/provider

/// Execute a shell command safely.
///
/// Validates the command against security rules before execution.
/// Returns the command output on success or an error message.
pub fn execute(command: String) -> Result(String, String) {
  case validate_command(command) {
    Ok(validated) -> run_command(validated)
    Error(reason) -> Error(reason)
  }
}

/// Execute a shell command with workspace policy authorization.
///
/// The command is authorized through the workspace policy before execution.
/// The command string is used as the path for authorization purposes.
pub fn execute_authorized(
  policy: policy_actor.WorkspacePolicy,
  agent_id: String,
  command: String,
) -> Result(String, String) {
  case policy_actor.authorize(policy, agent_id, OpShell, command) {
    Ok(_validated) -> {
      case validate_command(command) {
        Ok(validated) -> run_command(validated)
        Error(reason) -> Error(reason)
      }
    }
    Error(reason) -> Error(reason)
  }
}

/// Get the tool definition for SafeShell.
pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "safe_shell",
    description: "Execute shell commands with security constraints",
    parameters: [
      provider.string_param("command", "Shell command to execute", True),
    ],
  )
}

// ============================================================================
// Security
// ============================================================================

/// Validate a command against security rules.
fn validate_command(command: String) -> Result(String, String) {
  let trimmed = string.trim(command)

  // Block empty commands
  case trimmed {
    "" -> Error("Empty command")
    _ -> {
      // Block shell operators
      case contains_dangerous_chars(trimmed) {
        True -> Error("Command contains blocked operators: " <> trimmed)
        False -> {
          // Check command whitelist
          case is_allowed_command(trimmed) {
            True -> {
              // Validate path arguments for file-reading commands
              case validate_path_arguments(trimmed) {
                Ok(_) -> Ok(trimmed)
                Error(reason) -> Error(reason)
              }
            }
            False -> Error("Command not in whitelist: " <> trimmed)
          }
        }
      }
    }
  }
}

/// Check if command contains dangerous shell operators.
fn contains_dangerous_chars(command: String) -> Bool {
  [";", "|", "&&", "||", "$", "`", ">", "<", "..", "~", "*", "?", "{", "\\"]
  |> list.any(fn(token) { string.contains(command, token) })
}

/// Check if the base command is in the whitelist.
fn is_allowed_command(command: String) -> Bool {
  let base = get_base_command(command)
  list_contains(allowed_commands(), base)
}

/// Extract the base command (first word).
fn get_base_command(command: String) -> String {
  case split_whitespace_tokens(command) {
    [first, ..] -> first
    [] -> ""
  }
}

fn split_whitespace_tokens(command: String) -> List(String) {
  command
  |> string.replace("\t", " ")
  |> string.replace("\n", " ")
  |> string.replace("\r", " ")
  |> string.split(" ")
  |> list.filter(fn(part) { string.trim(part) != "" })
}

/// Whitelisted commands.
fn allowed_commands() -> List(String) {
  [
    "ls",
    "pwd",
    "cat",
    "head",
    "tail",
    "find",
    "echo",
    "date",
    "whoami",
    "uname",
  ]
}

/// Check if list contains a value.
fn list_contains(list: List(String), value: String) -> Bool {
  case list {
    [] -> False
    [first, ..rest] -> first == value || list_contains(rest, value)
  }
}

// ============================================================================
// Path Argument Validation
// ============================================================================

/// Commands whose arguments may reference file or directory paths.
fn file_reading_commands() -> List(String) {
  ["cat", "head", "tail", "find", "ls"]
}

/// Validate that path arguments in file-reading commands stay confined to the workspace.
fn validate_path_arguments(command: String) -> Result(Nil, String) {
  case split_whitespace_tokens(command) {
    [base, ..args] -> {
      case list_contains(file_reading_commands(), base) {
        True -> check_args_with_workspace_guard(args)
        False -> Ok(Nil)
      }
    }
    [] -> Ok(Nil)
  }
}

/// Reject any non-flag argument that escapes the workspace according to workspace_guard.
fn check_args_with_workspace_guard(args: List(String)) -> Result(Nil, String) {
  case args {
    [] -> Ok(Nil)
    [arg, ..rest] -> {
      let cleaned = strip_matching_quotes(string.trim(arg))
      case string.starts_with(cleaned, "-") || cleaned == "" {
        True -> check_args_with_workspace_guard(rest)
        False ->
          case workspace_guard.validate_path(".", cleaned) {
            Ok(_) -> check_args_with_workspace_guard(rest)
            Error(reason) -> Error("Blocked: " <> reason)
          }
      }
    }
  }
}

fn strip_matching_quotes(value: String) -> String {
  let unquoted_double = case
    string.starts_with(value, "\"") && string.ends_with(value, "\"")
  {
    True -> value |> string.drop_start(1) |> string.drop_end(1)
    False -> value
  }
  case
    string.starts_with(unquoted_double, "'")
    && string.ends_with(unquoted_double, "'")
  {
    True -> unquoted_double |> string.drop_start(1) |> string.drop_end(1)
    False -> unquoted_double
  }
}

// ============================================================================
// Execution
// ============================================================================

/// Run the validated command via Erlang port.
fn run_command(command: String) -> Result(String, String) {
  // Use Erlang's :os.cmd for execution
  do_run_command(command)
}

/// FFI to run a shell command.
@external(erlang, "supernova_safe_shell_ffi", "run_command")
fn do_run_command(command: String) -> Result(String, String)
