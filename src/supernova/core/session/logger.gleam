//// Session Logger — structured logging for session events.
////
//// Provides a simple logging interface for session-level events.
//// Each log entry is a pure data structure that can be formatted or stored.
////
//// ## Usage
////
//// ```gleam
//// let entry = logger.log("session_001", "info", "User sent message")
//// logger.format(entry) |> io.println
//// ```

// ============================================================================
// Types
// ============================================================================

/// A log entry for a session event.
pub type LogEntry {
  LogEntry(
    /// Session this log belongs to
    session_id: String,
    /// Log level: debug, info, warn, error
    level: String,
    /// Log message
    message: String,
  )
}

// ============================================================================
// Public API
// ============================================================================

/// Create a new log entry.
///
/// Returns a LogEntry with the given session ID, level, and message.
pub fn log(session_id: String, level: String, message: String) -> LogEntry {
  LogEntry(session_id: session_id, level: level, message: message)
}

/// Format a log entry as a human-readable string.
///
/// Format: `[level] [session:session_id] message`
pub fn format(entry: LogEntry) -> String {
  "["
  <> entry.level
  <> "] [session:"
  <> entry.session_id
  <> "] "
  <> entry.message
}
