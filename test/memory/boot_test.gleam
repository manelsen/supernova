//// The boot turns the memory on only with recall enabled and a key, and
//// wires the ledger the closed group publishes.

import gleam/option.{None, Some}
import gleeunit/should
import supernova/config
import supernova/core/closed_group/global as closed_group_global
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/memory/boot
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
  settings.api_key |> should.equal("k")
  settings.gate_threshold |> should.equal(0.1)
  settings.within_budget() |> should.be_true()
  // US$ 0,10 + 0,20: past the US$ 0,25 cap.
  settings.charge("telegram:42", 1_000_000, 1_000_000)
  settings.within_budget() |> should.be_false()
  closed_group_global.clear_runtime()
  boot.publish(cfg(True, Some("k"))) |> should.be_true()
  runtime.get() |> should.not_equal(None)
  runtime.clear()
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int
