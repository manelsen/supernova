//// Git Inspect — git repository operations.
////
//// Provides read-only git operations for repository analysis.

import supernova/llm/provider
import supernova/tools/safe_shell

/// Get git status.
pub fn status() -> Result(String, String) {
  safe_shell.execute("git status --short")
}

/// Get git log (last 10 commits).
pub fn log() -> Result(String, String) {
  safe_shell.execute("git log --oneline -10")
}

/// Get current branch.
pub fn branch() -> Result(String, String) {
  safe_shell.execute("git branch --show-current")
}

/// Get the tool definition for Git Inspect.
pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "git_inspect",
    description: "Read-only git operations: status, log, branch",
    parameters: [
      provider.string_param("action", "Action: status, log, branch", True),
    ],
  )
}
