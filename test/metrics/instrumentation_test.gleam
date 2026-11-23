//// What Supernova now measures, through the real paths: a member's turn on
//// Telegram, gate refusals, replies that fail, poll errors and the agenda.

import e2e/e2e_support as support
import exception
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import supernova
import supernova/agenda/store
import supernova/agenda/sweeper
import supernova/channel/channel_kit
import supernova/channel/health as channel_health
import supernova/channel/port
import supernova/channel/registry
import supernova/config
import supernova/core/closed_group/pure as cg_pure
import supernova/core/closed_group/types as cg_types
import supernova/metrics/actor as metrics_actor
import supernova/metrics/global as metrics_global
import telegram_fake
import test_workspace

/// Register a fresh metrics actor for the test, and restore the previous
/// registration when it ends.
fn with_metrics(body: fn(metrics_actor.Metrics) -> a) -> a {
  let previous = metrics_global.get_metrics()
  let assert Ok(metrics) = metrics_actor.start()
  use <- exception.defer(fn() {
    case previous {
      Some(previous) -> metrics_global.set_metrics(previous)
      option.None -> metrics_global.clear_metrics()
    }
  })
  metrics_global.set_metrics(metrics)
  body(metrics)
}

fn has(body: String, fragment: String) -> Nil {
  case string.contains(body, fragment) {
    True -> Nil
    False -> panic as { "missing " <> fragment <> " in:\n" <> body }
  }
}

/// Wait until the metrics body contains `fragment` (turns finish in their
/// own lane process).
fn await_metric(
  metrics: metrics_actor.Metrics,
  fragment: String,
  attempts: Int,
) -> String {
  let body = metrics_actor.get_metrics(metrics)
  case string.contains(body, fragment), attempts {
    True, _ -> body
    False, 0 -> body
    False, _ -> {
      process.sleep(20)
      await_metric(metrics, fragment, attempts - 1)
    }
  }
}

pub fn a_member_turn_is_measured_end_to_end_test() {
  use metrics <- with_metrics
  let base = support.channel_config()
  let cfg =
    config.Config(..base, access: support.access_config([], ["telegram:123"]))
  support.with_runtime_root(cfg, fn(root) {
    support.seed_core(root, "telegram:123", "Núcleo de teste.")
    let recorder = process.new_subject()
    let channels =
      support.telegram_start_registry(
        support.channel_config(),
        support.telegram_handler(support.mock_config()),
        [support.telegram_update("123", "123", "oi")],
        recorder,
      )
    support.await_content(recorder, "Mock response") |> should.equal(True)
    let body =
      await_metric(
        metrics,
        "turn_duration_seconds_count{channel=\"telegram\"",
        100,
      )
    has(body, "channel_messages_total{channel=\"telegram\",kind=\"message\"} 1")
    has(
      body,
      "gate_decisions_total{channel=\"telegram\",decision=\"allowed\"} 1",
    )
    has(body, "turn_duration_seconds_count{channel=\"telegram\",outcome=")
    has(body, "llm_tokens_total{kind=\"prompt\",provider=\"mock\"")
    has(body, "llm_tokens_total{kind=\"completion\",provider=\"mock\"")
    has(body, "llm_cost_usd_micros_total{provider=\"mock\"")
    registry.stop_channels(channels)
  })
}

/// Series declared at boot start at zero, and the real recording sites add
/// to those same series (same label order) instead of creating new ones:
/// otherwise Prometheus's `increase` loses the first event after a restart.
pub fn boot_declares_series_at_zero_and_turns_add_to_them_test() {
  use metrics <- with_metrics
  supernova.declare_boot_metrics(["telegram"], Ok(support.mock_config()))
  let declared = metrics_actor.get_metrics(metrics)
  has(
    declared,
    "channel_messages_total{channel=\"telegram\",kind=\"message\"} 0",
  )
  has(
    declared,
    "gate_decisions_total{channel=\"telegram\",decision=\"allowed\"} 0",
  )
  has(
    declared,
    "channel_send_errors_total{channel=\"telegram\",error=\"rate_limited\"} 0",
  )
  has(
    declared,
    "turn_duration_seconds_count{channel=\"telegram\",outcome=\"replied\"} 0",
  )
  has(
    declared,
    "turn_duration_seconds_bucket{channel=\"telegram\",outcome=\"replied\",le=\"+Inf\"} 0",
  )
  has(
    declared,
    "llm_requests_total{provider=\"mock\",model=\"mock-model\",status=\"success\"} 0",
  )
  has(
    declared,
    "llm_tokens_total{kind=\"prompt\",provider=\"mock\",model=\"mock-model\"} 0",
  )
  has(
    declared,
    "llm_cost_usd_micros_total{provider=\"mock\",model=\"mock-model\"} 0",
  )
  has(declared, "agenda_runs_total{outcome=\"ran\"} 0")
  has(declared, "channel_poll_errors_total{channel=\"telegram\"} 0")
  has(declared, "chat_lane_rejected_total{channel=\"telegram\"} 0")

  let base = support.channel_config()
  let cfg =
    config.Config(..base, access: support.access_config([], ["telegram:123"]))
  support.with_runtime_root(cfg, fn(root) {
    support.seed_core(root, "telegram:123", "Núcleo de teste.")
    let recorder = process.new_subject()
    let channels =
      support.telegram_start_registry(
        support.channel_config(),
        support.telegram_handler(support.mock_config()),
        [support.telegram_update("123", "123", "oi")],
        recorder,
      )
    support.await_content(recorder, "Mock response") |> should.equal(True)
    let body = await_metric(metrics, "decision=\"allowed\"} 1", 100)
    has(body, "channel_messages_total{channel=\"telegram\",kind=\"message\"} 1")
    has(
      body,
      "gate_decisions_total{channel=\"telegram\",decision=\"allowed\"} 1",
    )
    // One series per label set: the declared one, now at 1.
    series_count(body, "channel_messages_total{") |> should.equal(2)
    series_count(body, "gate_decisions_total{") |> should.equal(11)
    series_count(body, "llm_tokens_total{")
    |> should.equal(2)
    series_count(body, "llm_cost_usd_micros_total{") |> should.equal(1)
    // The turn (streamed or replied) lands in one of the six declared series.
    let turns =
      await_metric(metrics, "outcome=\"streamed\"} 1", 100)
      |> string.split("\n")
      |> list.filter(string.starts_with(_, "turn_duration_seconds_count{"))
    list.length(turns) |> should.equal(6)
    list.any(turns, string.ends_with(_, "} 1")) |> should.equal(True)
    registry.stop_channels(channels)
  })
}

fn series_count(body: String, prefix: String) -> Int {
  string.split(body, "\n")
  |> list.filter(fn(line) { string.starts_with(line, prefix) })
  |> list.length
}

pub fn a_stranger_is_counted_as_denied_test() {
  use metrics <- with_metrics
  let base = support.channel_config()
  let cfg =
    config.Config(..base, access: support.access_config([], ["telegram:123"]))
  support.with_runtime(cfg, fn() {
    let recorder = process.new_subject()
    let channels =
      support.telegram_start_registry(
        support.channel_config(),
        support.telegram_handler(support.mock_config()),
        [support.telegram_update("999", "999", "oi")],
        recorder,
      )
    let body = await_metric(metrics, "decision=\"denied\"", 100)
    has(
      body,
      "gate_decisions_total{channel=\"telegram\",decision=\"denied\"} 1",
    )
    registry.stop_channels(channels)
  })
}

pub fn decision_labels_test() {
  let denied = "Esta instância é privada."
  let ctx =
    cg_types.PrincipalContext(principal_id: "telegram:1", role: "member")
  cg_pure.decision_label(cg_types.Allowed(ctx), "oi", denied)
  |> should.equal("allowed")
  cg_pure.decision_label(cg_types.Ignored("rate limited"), "oi", denied)
  |> should.equal("rate_limited")
  cg_pure.decision_label(
    cg_types.Reply(cg_pure.instance_cap_reply),
    "oi",
    denied,
  )
  |> should.equal("instance_cap")
  cg_pure.decision_label(
    cg_types.Reply(cg_pure.budget_exhausted_reply(0)),
    "oi",
    denied,
  )
  |> should.equal("budget")
  cg_pure.decision_label(
    cg_types.Reply(cg_pure.fail_closed_reply),
    "oi",
    denied,
  )
  |> should.equal("fail_closed")
  cg_pure.decision_label(cg_types.Reply("seu id"), "/eu", denied)
  |> should.equal("eu")
  cg_pure.decision_label(cg_types.Reply(denied), "oi", denied)
  |> should.equal("denied")
  cg_pure.decision_label(cg_types.Reply("Uso: ..."), "/uso", denied)
  |> should.equal("command")
}

pub fn a_reply_that_fails_is_counted_test() {
  use metrics <- with_metrics
  let requests = process.new_subject()
  let fake = telegram_fake.start(requests)
  telegram_fake.queue(
    fake,
    "sendMessage",
    403,
    telegram_fake.error_body(403, "Forbidden: bot was blocked by the user"),
  )
  let base = config.default_config()
  let cfg =
    config.Config(
      ..base,
      telegram: config.TelegramConfig(
        token: Some("123:abc"),
        enabled: True,
        base_url: Some(fake.base_url),
      ),
    )
  let assert Ok(channels) =
    registry.start_channels_with_handler_and_hooks(
      cfg,
      fn(inbound, _) {
        let assert port.InboundMessage(message) = inbound
        Ok(port.ImmediateReply(port.reply(to: message, content: "olá")))
      },
      channel_kit.StartHooks(
        ..channel_kit.no_start_hooks(),
        disable_telegram_polling: True,
      ),
    )
  let assert Ok(Nil) =
    registry.inject(
      channels,
      fn(inbound, _) {
        let assert port.InboundMessage(message) = inbound
        Ok(port.ImmediateReply(port.reply(to: message, content: "olá")))
      },
      port.inbound_message(port.ChannelMessage(
        id: "1",
        channel: "telegram",
        channel_id: "42",
        user_id: "42",
        username: "",
        content: "oi",
        is_bot: False,
        reply_to_id: option.None,
      )),
    )
  let body = await_metric(metrics, "outcome=\"send_error\"", 100)
  has(
    body,
    "channel_send_errors_total{channel=\"telegram\",error=\"send_failed\"} 1",
  )
  has(
    body,
    "turn_duration_seconds_count{channel=\"telegram\",outcome=\"send_error\"} 1",
  )
  registry.stop_channels(channels)
}

pub fn poll_errors_are_counted_test() {
  use metrics <- with_metrics
  let health = channel_health.start()
  channel_health.started(health, "telegram", option.None, 0)
  channel_health.report(health, "telegram", Error("telegram unreachable"), 1)
  channel_health.report(health, "telegram", Ok(Nil), 2)
  channel_health.report(health, "telegram", Error("telegram unreachable"), 3)
  has(
    metrics_actor.get_metrics(metrics),
    "channel_poll_errors_total{channel=\"telegram\"} 2",
  )
}

pub fn agenda_runs_are_counted_test() {
  use metrics <- with_metrics
  let dir = test_workspace.create_temp_dir("agenda-metrics")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  let now = 1_795_273_200_000
  let assert Ok(entry) =
    store.add(dir, "telegram:1", "0 5 * * *", "Beber água", now, -180)
  let inbox = process.new_subject()
  sweeper.sweep(dir, -180, entry.next_run_at, process.send(inbox, _))
  has(
    metrics_actor.get_metrics(metrics),
    "agenda_runs_total{outcome=\"ran\"} 1",
  )
}
