//// Concurrency guarantees of the inbound path: chat lanes, the channel
//// polling loop, the syscall gateway and the ledger spend query.

import e2e/e2e_support as support
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/channel/chat_lanes
import supernova/channel/port
import supernova/channel/registry
import supernova/config
import supernova/core/access/types as access_types
import supernova/core/closed_group/pure as cg_pure
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/core/syscall/actor as syscall_actor

@external(erlang, "erlang", "monotonic_time")
fn monotonic_native() -> Int

@external(erlang, "erlang", "convert_time_unit")
fn convert_time_unit(value: Int, from: Atom, to: Atom) -> Int

type Atom

@external(erlang, "erlang", "binary_to_atom")
fn atom(name: String) -> Atom

fn now_ms() -> Int {
  convert_time_unit(monotonic_native(), atom("native"), atom("millisecond"))
}

// ----------------------------------------------------------------------------
// Chat lanes
// ----------------------------------------------------------------------------

pub fn lanes_run_different_chats_in_parallel_test() {
  // A subject can only be received by its owner, so the blocked job creates
  // its own gate and hands it to the test.
  let ready = process.new_subject()
  let finished = process.new_subject()

  chat_lanes.submit("test:lane-a", fn() {
    let gate = process.new_subject()
    process.send(ready, gate)
    let _ = process.receive(gate, within: 5000)
    process.send(finished, "a")
  })
  let assert Ok(gate) = process.receive(ready, within: 1000)
  chat_lanes.submit("test:lane-b", fn() { process.send(finished, "b") })

  // B completes while A is still blocked on its own lane.
  process.receive(finished, within: 1000) |> should.equal(Ok("b"))
  process.send(gate, Nil)
  process.receive(finished, within: 1000) |> should.equal(Ok("a"))
}

pub fn lanes_reject_pending_turns_above_limit_test() {
  let ready = process.new_subject()
  let log = process.new_subject()

  chat_lanes.submit_with_limits(
    "test:bounded",
    fn() {
      let gate = process.new_subject()
      process.send(ready, gate)
      let _ = process.receive(gate, within: 5000)
      process.send(log, 1)
    },
    2,
    2000,
  )
  |> should.equal(True)

  let assert Ok(gate) = process.receive(ready, within: 1000)
  chat_lanes.submit_with_limits(
    "test:bounded",
    fn() { process.send(log, 2) },
    2,
    2000,
  )
  |> should.equal(True)
  chat_lanes.submit_with_limits(
    "test:bounded",
    fn() { process.send(log, 3) },
    2,
    2000,
  )
  |> should.equal(False)
  chat_lanes.submit_with_limits(
    "test:bounded",
    fn() { process.send(log, 4) },
    2,
    2000,
  )
  |> should.equal(False)

  process.send(gate, Nil)
  process.receive(log, within: 2000) |> should.equal(Ok(1))
  process.receive(log, within: 2000) |> should.equal(Ok(2))

  chat_lanes.submit_with_limits(
    "test:bounded",
    fn() { process.send(log, 3) },
    2,
    2000,
  )
  |> should.equal(True)
  process.receive(log, within: 2000) |> should.equal(Ok(3))
}

pub fn lanes_reject_new_chats_above_lane_limit_test() {
  let ready = process.new_subject()

  chat_lanes.submit_with_limits(
    "test:lane-limit-a",
    fn() {
      let gate = process.new_subject()
      process.send(ready, gate)
      let _ = process.receive(gate, within: 5000)
      Nil
    },
    50,
    1,
  )
  |> should.equal(True)
  let assert Ok(gate) = process.receive(ready, within: 1000)

  chat_lanes.submit_with_limits("test:lane-limit-b", fn() { Nil }, 50, 1)
  |> should.equal(False)

  process.send(gate, Nil)
  wait_lane_count(0, 2000)
  chat_lanes.submit_with_limits("test:lane-limit-b", fn() { Nil }, 50, 1)
  |> should.equal(True)
}

fn wait_lane_count(expected: Int, deadline_ms: Int) -> Nil {
  let deadline = now_ms() + deadline_ms
  wait_lane_count_loop(expected, deadline)
}

fn wait_lane_count_loop(expected: Int, deadline: Int) -> Nil {
  case chat_lanes.lane_count() == expected {
    True -> Nil
    False ->
      case now_ms() < deadline {
        True -> {
          process.sleep(10)
          wait_lane_count_loop(expected, deadline)
        }
        False -> should.fail()
      }
  }
}

pub fn lanes_keep_order_within_a_chat_test() {
  let log = process.new_subject()

  chat_lanes.submit("test:lane-ordered", fn() {
    process.sleep(150)
    process.send(log, 1)
  })
  chat_lanes.submit("test:lane-ordered", fn() { process.send(log, 2) })
  chat_lanes.submit("test:lane-ordered", fn() { process.send(log, 3) })

  let received =
    list.map([1, 2, 3], fn(_) {
      let assert Ok(n) = process.receive(log, within: 2000)
      n
    })
  received |> should.equal([1, 2, 3])
}

pub fn lane_survives_a_failing_job_test() {
  let log = process.new_subject()
  chat_lanes.submit("test:lane-crash", fn() { panic as "job failure" })
  chat_lanes.submit("test:lane-crash", fn() { process.send(log, "after") })
  process.receive(log, within: 2000) |> should.equal(Ok("after"))
}

// ----------------------------------------------------------------------------
// Channel polling loop
// ----------------------------------------------------------------------------

fn slow_for_chat(
  slow_chat: String,
  ready: process.Subject(process.Subject(Nil)),
) -> port.ChannelHandler {
  fn(inbound, _events) {
    case inbound {
      port.InboundMessage(msg) -> {
        case msg.channel_id == slow_chat {
          True -> {
            let gate = process.new_subject()
            process.send(ready, gate)
            let _ = process.receive(gate, within: 5000)
            Nil
          }
          False -> Nil
        }
        Ok(
          port.ImmediateReply(port.reply(
            to: msg,
            content: "reply:" <> msg.channel_id,
          )),
        )
      }
      port.InboundInteraction(_) -> Error(port.Ignored("no interactions"))
    }
  }
}

// A slow turn in one chat must not hold the polling loop: another chat's
// update, received after it, is answered while the first is still running.
pub fn slow_chat_does_not_block_other_chats_test() {
  let recorder = process.new_subject()
  let ready = process.new_subject()
  let channel_registry =
    support.telegram_start_registry(
      support.channel_config(),
      slow_for_chat("111", ready),
      [
        support.telegram_update("111", "111", "lento"),
        support.telegram_update("222", "222", "rápido"),
      ],
      recorder,
    )

  let assert Ok(gate) = process.receive(ready, within: 2000)
  let assert Ok(first) = process.receive(recorder, within: 2000)
  first.content |> should.equal("reply:222")

  process.send(gate, Nil)
  let assert Ok(second) = process.receive(recorder, within: 2000)
  second.content |> should.equal("reply:111")
  registry.stop_channels(channel_registry)
}

// ----------------------------------------------------------------------------
// Syscall gateway
// ----------------------------------------------------------------------------

fn admin_gateway(
  slow_ready: process.Subject(process.Subject(Nil)),
) -> syscall_actor.SyscallGateway {
  let capabilities = config.default_config().capabilities
  let manifests =
    dict.from_list([
      #("admin", cg_pure.manifest_for(capabilities, access_types.Admin)),
    ])
  let assert Ok(gateway) =
    syscall_actor.start_with_capabilities(
      None,
      None,
      None,
      manifests,
      fn(name, _args) {
        case name {
          "web" -> {
            let gate = process.new_subject()
            process.send(slow_ready, gate)
            let _ = process.receive(gate, within: 10_000)
            Ok("slow-ok")
          }
          _ -> Ok("fast-ok")
        }
      },
    )
  gateway
}

// A tool slower than the gateway call timeout must not be reported as
// refused, and must not hold another principal's tool call.
pub fn slow_tool_neither_refused_nor_blocking_test() {
  let slow_ready = process.new_subject()
  let gateway = admin_gateway(slow_ready)
  let slow_result = process.new_subject()

  process.spawn(fn() {
    process.send(
      slow_result,
      syscall_actor.invoke_tool(gateway, "telegram:1", "admin", "web", "{}"),
    )
  })
  let assert Ok(gate) = process.receive(slow_ready, within: 2000)

  let started = now_ms()
  syscall_actor.invoke_tool(gateway, "telegram:2", "admin", "canvas", "{}")
  |> should.equal(Ok("fast-ok"))
  { now_ms() - started < 1000 } |> should.equal(True)

  // Keep the slow tool blocked past the gateway's 2 s call timeout.
  process.sleep(2500)
  process.send(gate, Nil)

  process.receive(slow_result, within: 5000)
  |> should.equal(Ok(Ok("slow-ok")))
}

fn late_terminal_handler(
  stream_seen: process.Subject(process.Subject(port.ChannelStreamEvent)),
  second_started: process.Subject(String),
) -> port.ChannelHandler {
  fn(inbound, events) {
    case inbound {
      port.InboundMessage(msg) ->
        case msg.content {
          "first" -> {
            process.send(stream_seen, events)
            Ok(port.StreamReply(port.reply(to: msg, content: "")))
          }
          _ -> {
            process.send(second_started, msg.content)
            process.send(
              events,
              port.StreamComplete(port.reply(to: msg, content: "second")),
            )
            Ok(port.StreamReply(port.reply(to: msg, content: "")))
          }
        }
      port.InboundInteraction(_) -> Error(port.Ignored("no interactions"))
    }
  }
}

pub fn late_terminal_keeps_lane_until_content_is_delivered_test() {
  let recorder = process.new_subject()
  let stream_seen = process.new_subject()
  let second_started = process.new_subject()
  let hooks =
    registry.StartHooks(
      discord_events: [],
      telegram_updates: [
        support.telegram_update("777", "777", "first"),
        support.telegram_update("777", "777", "second"),
      ],
      slack_inbound_events: [],
      matrix_inbound_events: [],
      disable_telegram_polling: True,
      typing_keepalive_ms: 4000,
      stream_timeout_ms: 120,
      turn_hard_timeout_ms: 300_000,
      outbound_records: Some(recorder),
      leave_group: None,
    )
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      support.channel_config(),
      late_terminal_handler(stream_seen, second_started),
      hooks,
    )

  let assert Ok(stream_events) = process.receive(stream_seen, within: 1000)
  let timeout_record =
    receive_record_until(recorder, fn(record) {
      record.content == "Streaming timed out"
    })
  timeout_record.content |> should.equal("Streaming timed out")

  process.send(
    stream_events,
    port.StreamComplete(
      port.ChannelReply(
        channel_id: "777",
        content: "late content",
        reply_to_id: None,
        thread_id: None,
        typing: False,
        edit_message_id: None,
        interactive: None,
        media: [],
      ),
    ),
  )

  let late_record =
    receive_record_until(recorder, fn(record) {
      record.action == "send" && record.content == "late content"
    })
  late_record.action |> should.equal("send")
  process.receive(second_started, within: 1000)
  |> should.equal(Ok("second"))

  registry.stop_channels(channel_registry)
}

fn receive_record_until(
  recorder: process.Subject(registry.OutboundRecord),
  predicate: fn(registry.OutboundRecord) -> Bool,
) -> registry.OutboundRecord {
  let assert Ok(record) = process.receive(recorder, within: 3000)
  case predicate(record) {
    True -> record
    False -> receive_record_until(recorder, predicate)
  }
}

// ----------------------------------------------------------------------------
// Ledger
// ----------------------------------------------------------------------------

pub fn ledger_sums_cost_inside_the_actor_test() {
  let assert Ok(ledger) = ledger_actor.start()
  let assert Ok(Nil) =
    ledger_actor.try_record_llm_usage(
      ledger,
      "telegram:1",
      "p",
      "m",
      10,
      5,
      0.25,
    )
  let assert Ok(Nil) =
    ledger_actor.try_record_llm_usage(
      ledger,
      "telegram:2",
      "p",
      "m",
      10,
      5,
      0.5,
    )

  ledger_actor.try_llm_cost_where(ledger, fn(_) { True })
  |> should.equal(Ok(0.75))
  ledger_actor.try_llm_cost_where(ledger, fn(_) { False })
  |> should.equal(Ok(0.0))
}
