//// Safe Call — actor calls that fail closed instead of crashing.
////
//// `gleam/otp/actor.call` panics when the callee is down or does not answer.
//// For kernel policy actors the safe behavior is a typed failure so the
//// caller can deny access, treat the budget as exhausted, or refuse an LLM
//// call.

import gleam/erlang/process.{type Subject}

pub type CallError {
  Timeout
  Unavailable
}

/// Send a request and wait for a reply, returning an error on timeout or when
/// the callee is not alive.
pub fn call(
  subject: Subject(message),
  timeout_ms: Int,
  make_message: fn(Subject(reply)) -> message,
) -> Result(reply, CallError) {
  case process.subject_owner(subject) {
    Error(_) -> Error(Unavailable)
    Ok(pid) -> {
      let reply_subject = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(subject, make_message(reply_subject))

      let selector =
        process.new_selector()
        |> process.select_map(reply_subject, Ok)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })

      let result = process.selector_receive(selector, timeout_ms)
      process.demonitor_process(monitor)

      case result {
        Ok(Ok(reply)) -> Ok(reply)
        Ok(Error(_)) -> Error(Unavailable)
        Error(_) -> Error(Timeout)
      }
    }
  }
}
