//// The boot turns the memory on only with recall enabled and a key, and
//// wires the ledger the closed group publishes.

import gleam/option.{None, Some}
import gleeunit/should
import supernova/config
import supernova/core/closed_group/global as closed_group_global
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/memory/boot
import supernova/memory/decision
import supernova/memory/runtime

fn cfg(enabled: Bool, key: option.Option(String)) -> config.Config {
  let base = config.default_config()
  config.Config(
    ..base,
    conversation: config.ConversationConfig(
      ..base.conversation,
      recall: config.RecallConfig(
        ..config.default_recall_config(),
        enabled: enabled,
        api_key: key,
      ),
    ),
    instance_budget: config.InstanceBudgetConfig(
      ..base.instance_budget,
      daily_usd: 0.25,
    ),
  )
}

fn transport(_url, _headers, _body) {
  Ok(#(200, "{}"))
}

/// Gemini on request; a cutoff in the yaml wins over the provider's.
pub fn gemini_and_overridden_cutoffs_test() {
  let base = cfg(True, Some("g"))
  let with_gemini =
    config.Config(
      ..base,
      conversation: config.ConversationConfig(
        ..base.conversation,
        recall: config.RecallConfig(
          ..base.conversation.recall,
          provider: "gemini",
          unlikely_below: Some(0.3),
        ),
      ),
    )
  let assert Some(settings) = boot.settings(with_gemini, transport, fn() { 0 })
  settings.endpoint.provider |> should.equal(decision.Gemini)
  settings.thresholds.gate |> should.equal(0.1)
  settings.thresholds.unlikely_below |> should.equal(0.3)
}

/// Without a ledger to ask, no paid call (fail closed).
pub fn no_ledger_means_no_memory_calls_test() {
  closed_group_global.clear_runtime()
  let assert Some(settings) =
    boot.settings(cfg(True, Some("k")), transport, fn() { 0 })
  settings.admit("telegram:42", 100) |> should.be_error()
}

pub fn off_without_recall_or_key_test() {
  boot.settings(cfg(False, Some("k")), transport, fn() { 0 })
  |> should.equal(None)
  boot.settings(cfg(True, None), transport, fn() { 0 }) |> should.equal(None)
  boot.publish(cfg(False, None)) |> should.be_false()
  runtime.get() |> should.equal(None)
}

pub fn on_charges_the_published_ledger_test() {
  let assert Ok(book) = ledger_actor.start()
  closed_group_global.set_ledger(book)
  let now = current_timestamp()
  let assert Some(settings) =
    boot.settings(cfg(True, Some("k")), transport, fn() { now })
  // Perplexity by default, with the cutoffs measured for it.
  settings.endpoint
  |> should.equal(decision.endpoint(decision.Perplexity, "k"))
  settings.thresholds
  |> should.equal(runtime.default_thresholds(decision.Perplexity))
  // Admitted and settled: US$ 0,02 per million each, so 10 million decision
  // tokens and 10 million embedding tokens are US$ 0,40, past the US$ 0,25
  // cap; the next call is refused.
  let assert Ok(settle) = settings.admit("telegram:42", 300)
  settle(10_000_000, 10_000_000)
  let assert Ok(#(_, spent)) = ledger_actor.try_spend_today(book, now)
  { spent >. 0.39 && spent <. 0.41 } |> should.be_true()
  settings.admit("telegram:42", 300) |> should.be_error()
  // Admitted and nothing spent: the reservation is released.
  closed_group_global.set_ledger(book)
  closed_group_global.clear_runtime()
  boot.publish(cfg(True, Some("k"))) |> should.be_true()
  runtime.get() |> should.not_equal(None)
  runtime.clear()
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int
