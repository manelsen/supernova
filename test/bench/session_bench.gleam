//// Session Benchmark Tests.
////
//// Measures session creation throughput and context handling.
////
//// Run with: gleam test

import gleam/int
import gleam/list
import supernova/core/session/supervisor

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn timestamp() -> Int

fn ms_since(ts: Int) -> Int {
  timestamp() - ts
}

pub fn session_creation_throughput_bench() {
  let assert Ok(sup) = supervisor.start()

  let iterations = 100
  let start = timestamp()

  let _ =
    list.range(0, iterations)
    |> list.map(fn(i) {
      supervisor.start_session(sup, "bench-agent-" <> int.to_string(i))
    })

  let elapsed = ms_since(start)
  let throughput = { iterations + 1 } * 1000 / elapsed

  supervisor.stop(sup)

  throughput > 10
}

pub fn session_get_throughput_bench() {
  let assert Ok(sup) = supervisor.start()
  let assert Ok(_) = supervisor.start_session(sup, "bench-agent")

  let iterations = 1000
  let start = timestamp()

  let _ =
    list.range(0, iterations)
    |> list.map(fn(_) { supervisor.get_session(sup, "bench-agent") })

  let elapsed = ms_since(start)
  let ops_per_sec = iterations * 1000 / elapsed

  supervisor.stop(sup)

  ops_per_sec > 500
}
