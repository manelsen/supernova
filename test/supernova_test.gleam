import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova
import supernova/channel/port
import supernova/config
import supernova/core/session/supervisor
import supernova/llm/circuit_breaker/actor as cb_actor
import supernova/llm/failover_cooldown/types as cd_types
import supernova/metrics/actor as metrics_actor
import supernova/metrics/global as metrics_global
import supernova/tracing/types as tracing_types
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

@external(erlang, "test_signal_ffi", "kill_pid")
fn kill_pid(pid: process.Pid) -> Nil

pub fn infrastructure_supervisor_restarts_killed_metrics_actor_test() {
  let tracer_config =
    tracing_types.TracerConfig(
      service_name: "supernova-test",
      otlp_endpoint: "",
      sampling_rate: 1.0,
    )
  let cb_config =
    cb_actor.CircuitBreakerConfig(
      failure_threshold: 5,
      recovery_timeout_ms: 30_000,
      half_open_max_calls: 3,
    )
  let cd_config =
    cd_types.FailoverCooldownConfig(
      initial_cooldown_ms: 30_000,
      max_cooldown_ms: 300_000,
    )

  let assert Ok(_sup) =
    supernova.start_infrastructure_supervisor(
      tracer_config,
      cb_config,
      cd_config,
    )

  let original_metrics = wait_for_restarted_metrics(None, 20)
  let assert Ok(original_pid) = process.subject_owner(original_metrics)

  kill_pid(original_pid)

  let restarted_metrics = wait_for_restarted_metrics(Some(original_pid), 40)
  let assert Ok(restarted_pid) = process.subject_owner(restarted_metrics)
  restarted_pid |> should.not_equal(original_pid)

  metrics_actor.inc_counter(restarted_metrics, "supervisor_restarts_total", [])
  let rendered = metrics_actor.get_metrics(restarted_metrics)
  string.contains(rendered, "supervisor_restarts_total 1")
  |> should.equal(True)
}

fn wait_for_restarted_metrics(
  previous_pid: option.Option(process.Pid),
  attempts: Int,
) -> metrics_global.Metrics {
  case attempts <= 0 {
    True -> panic as "Timed out waiting for restarted metrics actor"
    False ->
      case metrics_global.get_metrics() {
        Some(subject) ->
          case process.subject_owner(subject), previous_pid {
            Ok(pid), Some(old_pid) if pid != old_pid -> subject
            Ok(_), None -> subject
            _, _ -> {
              process.sleep(25)
              wait_for_restarted_metrics(previous_pid, attempts - 1)
            }
          }
        None -> {
          process.sleep(25)
          wait_for_restarted_metrics(previous_pid, attempts - 1)
        }
      }
  }
}
