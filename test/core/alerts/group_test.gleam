import gleeunit/should
import supernova/core/alerts/group_pure as pure
import supernova/core/closed_group/pure as cg_pure

pub fn dedup_allows_once_per_hour_test() {
  let state = pure.new_state()
  should.equal(pure.should_send(state.dedup, pure.Budget80, "a", 0), True)
  let state =
    pure.AlertState(
      ..state,
      dedup: pure.record(state.dedup, pure.Budget80, "a", 0),
    )
  should.equal(pure.should_send(state.dedup, pure.Budget80, "a", 1000), False)
  should.equal(
    pure.should_send(state.dedup, pure.Budget80, "a", 3_600_000),
    True,
  )
  should.equal(pure.should_send(state.dedup, pure.Instance80, "a", 1000), True)
}

pub fn abuse_threshold_is_more_than_five_in_ten_minutes_test() {
  let state = pure.new_state()
  let #(state, crossed1) = pure.record_denial(state, "chat", 0)
  let #(state, _) = pure.record_denial(state, "chat", 1000)
  let #(state, _) = pure.record_denial(state, "chat", 2000)
  let #(state, _) = pure.record_denial(state, "chat", 3000)
  let #(state, crossed5) = pure.record_denial(state, "chat", 4000)
  let #(_, crossed6) = pure.record_denial(state, "chat", 5000)
  should.equal(crossed1, False)
  should.equal(crossed5, False)
  should.equal(crossed6, True)
}

pub fn denial_window_slides_test() {
  let state = pure.new_state()
  let #(state, _) = pure.record_denial(state, "chat", 0)
  let #(state, _) = pure.record_denial(state, "chat", 1000)
  let #(state, _) = pure.record_denial(state, "chat", 2000)
  let #(state, _) = pure.record_denial(state, "chat", 3000)
  let #(state, _) = pure.record_denial(state, "chat", 4000)
  // First five are now older than ten minutes.
  let #(_, crossed) = pure.record_denial(state, "chat", 700_001)
  should.equal(crossed, False)
}

pub fn alert_texts_are_portuguese_test() {
  cg_pure.budget_alert_text("telegram:1")
  |> should.equal("⚠️ telegram:1 usou 80% do limite da hora.")
  cg_pure.instance_alert_text(100, 5.0)
  |> should.equal("⚠️ A instância usou 100% do teto diário de US$ 5.0.")
  cg_pure.fail_closed_alert_text("ledger")
  |> should.equal(
    "⚠️ Componente indisponível: ledger. Requisições estão sendo negadas.",
  )
}
