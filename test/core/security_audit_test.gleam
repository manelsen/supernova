import gleeunit
import gleeunit/should
import supernova/core/security_audit

pub fn main() {
  gleeunit.main()
}

pub fn log_builds_audit_entry_test() {
  let entry =
    security_audit.log("s-1", "shell", "ls -la", False)

  entry.session_id |> should.equal("s-1")
  entry.operation |> should.equal("shell")
  entry.details |> should.equal("ls -la")
  entry.allowed |> should.equal(False)
}

pub fn format_includes_status_and_details_test() {
  let allowed_entry =
    security_audit.log("s-allowed", "file_read", "/tmp/config.yaml", True)
  let blocked_entry =
    security_audit.log("s-blocked", "network", "http://example.com", False)

  security_audit.format(allowed_entry)
  |> should.equal("[AUDIT] [ALLOWED] [session:s-allowed] file_read: /tmp/config.yaml")

  security_audit.format(blocked_entry)
  |> should.equal("[AUDIT] [BLOCKED] [session:s-blocked] network: http://example.com")
}
