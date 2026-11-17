import gleam/dict
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import supernova
import supernova/channel/port
import supernova/config
import supernova/core/session/supervisor
import test_workspace

pub fn main() -> Nil {
  gleeunit.main()
}

// gleeunit test functions end in `_test`
pub fn hello_world_test() {
  let name = "Joe"
  let greeting = "Hello, " <> name <> "!"

  assert greeting == "Hello, Joe!"
}

pub fn main_handles_missing_runtime_config_without_crashing_test() {
  supernova.main()
}

pub fn build_channel_handler_dispatches_slack_matrix_and_ignores_unknown_test() {
  use _ <- test_workspace.with_isolated_workspace("supernova-handler")
  let base = config.default_config()
  let provider_cfg = config.default_provider_config(config.Ollama)
  let cfg =
    config.Config(
      ..base,
      providers: dict.from_list([#("ollama", provider_cfg)]),
    )
  let assert Ok(session_sup) = supervisor.start()
  let assert Ok(handler) = supernova.build_channel_handler(cfg, session_sup)
  let events = process.new_subject()

  let slack_msg =
    port.ChannelMessage(
      id: "sl-1",
      channel: "slack",
      channel_id: "C1",
      user_id: "U1",
      username: "alice",
      content: "/help",
      is_bot: False,
      reply_to_id: None,
    )
  let assert Ok(port.ImmediateReply(slack_reply)) =
    handler(port.inbound_message(slack_msg), events)
  string.contains(slack_reply.content, "Supernova AI Agent Framework")
  |> should.equal(True)

  let matrix_msg =
    port.ChannelMessage(
      id: "mx-1",
      channel: "matrix",
      channel_id: "!r:example.org",
      user_id: "@alice:example.org",
      username: "alice",
      content: "/help",
      is_bot: False,
      reply_to_id: None,
    )
  let assert Ok(port.ImmediateReply(matrix_reply)) =
    handler(port.inbound_message(matrix_msg), events)
  string.contains(matrix_reply.content, "Supernova AI Agent Framework")
  |> should.equal(True)

  let unknown_msg =
    port.ChannelMessage(
      id: "irc-1",
      channel: "irc",
      channel_id: "#chan",
      user_id: "nick",
      username: "nick",
      content: "/help",
      is_bot: False,
      reply_to_id: None,
    )
  handler(port.inbound_message(unknown_msg), events)
  |> should.equal(Error(port.Ignored("channel not configured: irc")))

  supervisor.stop(session_sup)
}

@external(erlang, "test_signal_ffi", "send_shutdown_exit")
fn send_shutdown_exit(pid: process.Pid) -> Nil

pub fn wait_for_shutdown_blocks_until_exit_signal_test() {
  let ready = process.new_subject()
  let done = process.new_subject()

  let pid =
    process.spawn_unlinked(fn() {
      process.send(ready, Nil)
      supernova.wait_for_shutdown()
      process.send(done, Nil)
    })

  let assert Ok(Nil) = process.receive(ready, within: 500)
  process.sleep(20)
  process.receive(done, within: 20) |> should.equal(Error(Nil))

  send_shutdown_exit(pid)
  process.receive(done, within: 500) |> should.equal(Ok(Nil))
}
