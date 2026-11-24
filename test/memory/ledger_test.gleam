//// The memory's calls go into the ledger as "gemini" usage and count in the
//// day's spend; past the cap, the memory stands aside.

import gleeunit/should
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/memory/decision
import supernova/memory/ledger

pub fn charges_count_in_the_days_spend_test() {
  let assert Ok(book) = ledger_actor.start()
  let gemini = decision.endpoint(decision.Gemini, "k")
  // The ledger stamps usage with its own clock: ask about the same day.
  let now = current_timestamp()
  // 1 million Decision tokens (US$ 0,10) and 1 million embedding tokens
  // (US$ 0,20); nothing recorded for zero.
  ledger.charge(book, gemini, "telegram:42", 1_000_000, 1_000_000)
  ledger.charge(book, gemini, "telegram:42", 0, 0)
  let assert Ok(#(_, spent)) = ledger_actor.try_spend_today(book, now)
  { spent >. 0.29 && spent <. 0.31 } |> should.be_true()
}

/// A call is admitted against the cap before it is made: past the cap it is
/// refused; settled with nothing spent, its reservation goes away.
pub fn calls_are_admitted_against_the_cap_test() {
  let assert Ok(book) = ledger_actor.start()
  let gemini = decision.endpoint(decision.Gemini, "k")
  let now = current_timestamp()
  let assert Ok(settle) = ledger.admit(book, gemini, "telegram:42", 0.25, 1000)
  // Settled at US$ 0,10 + 0,20 = 0,30: past the cap.
  settle(1_000_000, 1_000_000)
  let assert Ok(#(_, spent)) = ledger_actor.try_spend_today(book, now)
  { spent >. 0.29 && spent <. 0.31 } |> should.be_true()
  ledger.admit(book, gemini, "telegram:42", 0.25, 1000) |> should.be_error()
  // Under a higher cap, admitted; nothing spent releases the reservation.
  let assert Ok(release) = ledger.admit(book, gemini, "telegram:42", 1.0, 1000)
  release(0, 0)
  let assert Ok(#(_, same)) = ledger_actor.try_spend_today(book, now)
  same |> should.equal(spent)
}

/// Perplexity's prices: US$ 0,02 per million for each.
pub fn perplexity_is_charged_at_its_price_test() {
  let assert Ok(book) = ledger_actor.start()
  let now = current_timestamp()
  ledger.charge(
    book,
    decision.endpoint(decision.Perplexity, "k"),
    "telegram:42",
    1_000_000,
    1_000_000,
  )
  let assert Ok(#(_, spent)) = ledger_actor.try_spend_today(book, now)
  { spent >. 0.039 && spent <. 0.041 } |> should.be_true()
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int
