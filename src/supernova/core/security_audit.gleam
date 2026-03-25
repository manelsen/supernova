//// Security Audit — logging of sensitive operations.
////
//// Provides structured audit logging for security-relevant events:
//// shell execution, file operations, network access.

/// An audit log entry.
pub type AuditEntry {
  AuditEntry(
    /// Session that triggered the event
    session_id: String,
    /// Operation type: "shell", "file_read", "file_write", "network"
    operation: String,
    /// Operation details
    details: String,
    /// Whether the operation was allowed
    allowed: Bool,
  )
}

/// Log a security-relevant operation.
pub fn log(
  session_id: String,
  operation: String,
  details: String,
  allowed: Bool,
) -> AuditEntry {
  AuditEntry(
    session_id: session_id,
    operation: operation,
    details: details,
    allowed: allowed,
  )
}

/// Format an audit entry as a string.
pub fn format(entry: AuditEntry) -> String {
  let status = case entry.allowed {
    True -> "ALLOWED"
    False -> "BLOCKED"
  }
  "[AUDIT] ["
  <> status
  <> "] [session:"
  <> entry.session_id
  <> "] "
  <> entry.operation
  <> ": "
  <> entry.details
}
