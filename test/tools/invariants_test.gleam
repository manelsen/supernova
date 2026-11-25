//// The invariants of the tool runner (PRD-F, section 7), with the test
//// tools of F-01 (`lenta`, `trava`, `explode`).
////
//// I2 fails on the code before the F-02: a tool call is started unlinked,
//// and it outlives the turn that asked for it. Its test is
//// `pending_i2_turn_death_kills_its_calls`, without the `_test` suffix, so
//// the suite does not run it yet; the F-02 renames it. The failure, as
//// recorded in the F-01 commit: the `trava` call is still alive 1 s after
//// the turn was killed.

import exception
import gleam/dict
import gleam/erlang/process.{type Pid}
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import supernova/core/executor
import supernova/core/tool_dispatch
import supernova/core/tool_limits
import supernova/llm/provider
import supernova/stress/fake_tools

fn with_fake_tools(body: fn() -> a) -> a {
  fake_tools.enable()
  use <- exception.defer(fn() {
    fake_tools.disable()
    tool_limits.configure(tool_limits.default_timeouts())
  })
  body()
}

fn call(id: String, name: String, ms: Int) -> provider.ToolCall {
  provider.ToolCall(
    id: id,
    name: name,
    arguments: json.to_string(json.object([#("ms", json.int(ms))])),
  )
}

fn run(calls: List(provider.ToolCall)) -> List(provider.ChatMessage) {
  executor.execute_tool_calls_for_test(calls, fake_tools.tools())
}

fn with_trava_limit(ms: Int) -> Nil {
  tool_limits.configure(
    tool_limits.Timeouts(
      ..tool_limits.default_timeouts(),
      per_tool: tool_limits.default_timeouts().per_tool
        |> dict.insert("trava", ms),
    ),
  )
}

/// I1: a call that never answers becomes an error within its limit plus 1 s,
/// and the round goes on.
pub fn i1_a_stuck_call_ends_at_its_limit_test() {
  use <- with_fake_tools
  with_trava_limit(300)
  let start = now()
  let assert [stuck, slow] =
    run([call("c1", "trava", 0), call("c2", "lenta", 50)])
  let elapsed = now() - start
  should.be_true(elapsed < 1300)
  string.starts_with(stuck.content, "ERROR:") |> should.be_true
  slow.content |> should.equal("lenta: 50 ms")
}

/// I2: when the turn dies, its calls die.
pub fn pending_i2_turn_death_kills_its_calls() {
  use <- with_fake_tools
  let started = process.new_subject()
  fake_tools.observe(started)
  let turn = process.spawn_unlinked(fn() { run([call("c1", "trava", 0)]) })
  let assert Ok(tool) = process.receive(started, 2000)
  process.kill(turn)
  wait_dead(tool, 1000) |> should.be_true
}

/// I3: every call is reported once, whatever its outcome.
pub fn i3_one_report_per_call_test() {
  use <- with_fake_tools
  with_trava_limit(300)
  let invoked = process.new_subject()
  let reported = process.new_subject()
  let context =
    executor.RunContext(
      ..executor.empty_run_context(),
      invoke_tool: Some(fn(name, args) {
        process.send(invoked, name)
        tool_dispatch.execute(name, args)
      }),
      on_tool_result: Some(fn(name, ok) { process.send(reported, #(name, ok)) }),
    )
  let _ =
    executor.execute_tool_calls_with_context_for_test(
      [
        call("c1", "lenta", 10),
        call("c2", "explode", 0),
        call("c3", "trava", 0),
      ],
      fake_tools.tools(),
      context,
    )
  drain(invoked, [])
  |> list.sort(string.compare)
  |> should.equal(["explode", "lenta", "trava"])
  drain(reported, [])
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> should.equal([#("explode", False), #("lenta", True), #("trava", False)])
}

/// I4: the results of one round come back in the order of the calls, even
/// when the first call is the slowest.
pub fn i4_results_keep_the_calls_order_test() {
  use <- with_fake_tools
  let results =
    run([
      call("c1", "lenta", 120),
      call("c2", "lenta", 60),
      call("c3", "lenta", 10),
    ])
  results
  |> list.map(fn(message) { message.tool_call_id })
  |> should.equal([Some("c1"), Some("c2"), Some("c3")])
  results
  |> list.map(fn(message) { message.content })
  |> should.equal(["lenta: 120 ms", "lenta: 60 ms", "lenta: 10 ms"])
}

/// I5: a stuck tool in one turn does not delay another tool in another turn.
pub fn i5_a_stuck_tool_does_not_hold_others_test() {
  use <- with_fake_tools
  let _stuck = process.spawn_unlinked(fn() { run([call("c1", "trava", 0)]) })
  let start = now()
  let assert [slow] = run([call("c2", "lenta", 50)])
  slow.content |> should.equal("lenta: 50 ms")
  should.be_true(now() - start < 1000)
}

/// The test tools are off unless turned on: production never offers them.
pub fn fake_tools_are_off_by_default_test() {
  fake_tools.disable()
  fake_tools.tools() |> should.equal([])
  tool_dispatch.builtin_tools()
  |> list.any(fn(tool) { fake_tools.is_fake(tool.name) })
  |> should.be_false
  tool_dispatch.execute("lenta", "{\"ms\":1}") |> should.be_error
}

fn drain(subject: process.Subject(a), acc: List(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(item) -> drain(subject, [item, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

/// Polls until `pid` is dead, up to `within` ms (no fixed sleep).
fn wait_dead(pid: Pid, within: Int) -> Bool {
  case process.is_alive(pid), within <= 0 {
    False, _ -> True
    True, True -> False
    True, False -> {
      process.sleep(10)
      wait_dead(pid, within - 10)
    }
  }
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now() -> Int
