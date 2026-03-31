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

import gleam/string
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
  string.contains(command, ";")
  || string.contains(command, "|")
  || string.contains(command, "&&")
  || string.contains(command, "||")
  || string.contains(command, "$(")
  || string.contains(command, "`")
  || string.contains(command, ">")
  || string.contains(command, "<")
  || string.contains(command, "..")
}

/// Check if the base command is in the whitelist.
fn is_allowed_command(command: String) -> Bool {
  let base = get_base_command(command)
  list_contains(allowed_commands(), base)
}

/// Extract the base command (first word).
fn get_base_command(command: String) -> String {
  case string.split(command, " ") {
    [first, ..] -> first
    [] -> ""
  }
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

/// Commands whose arguments may reference file paths.
fn file_reading_commands() -> List(String) {
  ["cat", "head", "tail", "find"]
}

/// Validate that path arguments in file-reading commands don't
/// reference absolute paths outside the workspace.
fn validate_path_arguments(command: String) -> Result(Nil, String) {
  let parts = string.split(command, " ")
  case parts {
    [base, ..args] -> {
      case list_contains(file_reading_commands(), base) {
        True -> check_args_for_absolute_paths(args)
        False -> Ok(Nil)
      }
    }
    [] -> Ok(Nil)
  }
}

/// Reject any argument that looks like an absolute path to a sensitive location.
fn check_args_for_absolute_paths(args: List(String)) -> Result(Nil, String) {
  case args {
    [] -> Ok(Nil)
    [arg, ..rest] -> {
      let trimmed = string.trim(arg)
      case is_blocked_path(trimmed) {
        True ->
          Error("Blocked: absolute path argument not allowed: " <> trimmed)
        False -> check_args_for_absolute_paths(rest)
      }
    }
  }
}

/// Check if a path argument targets sensitive locations.
fn is_blocked_path(arg: String) -> Bool {
  // Skip flags (e.g., -la, --name)
  case string.starts_with(arg, "-") {
    True -> False
    False -> {
      // Block absolute paths to sensitive system directories
      string.starts_with(arg, "/etc")
      || string.starts_with(arg, "/proc")
      || string.starts_with(arg, "/sys")
      || string.starts_with(arg, "/dev")
      || string.starts_with(arg, "/var")
      || string.starts_with(arg, "/tmp")
      || string.starts_with(arg, "/root")
      || string.starts_with(arg, "/home")
      || string.starts_with(arg, "/usr")
      || string.starts_with(arg, "/bin")
      || string.starts_with(arg, "/sbin")
      || string.starts_with(arg, "/opt")
      || string.starts_with(arg, "/mnt")
      || string.starts_with(arg, "/run")
      || arg == "/"
    }
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
