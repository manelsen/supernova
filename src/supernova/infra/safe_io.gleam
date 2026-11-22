//// Logging that cannot crash the caller. A long-lived process (a chat lane,
//// the tracer) may outlive the process that owned its group leader; a plain
//// `io.println` then raises and kills the turn it was reporting on.

@external(erlang, "supernova_global_ffi", "safe_println")
pub fn println(line: String) -> Nil
