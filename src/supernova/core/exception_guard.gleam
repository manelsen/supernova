//// Exception boundary for work that must always report a terminal event.
////
//// Gleam has no try/catch; this tiny FFI wrapper keeps a crashing executor
//// from silently killing the process that owns a channel stream.

@external(erlang, "supernova_exception_guard_ffi", "run")
fn ffi_run(body: fn() -> Nil) -> Result(Nil, String)

/// Run `body`, returning a typed error instead of crashing on an exception.
pub fn run(body: fn() -> Nil) -> Result(Nil, String) {
  ffi_run(body)
}
