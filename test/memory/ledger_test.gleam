//// The memory's calls go into the ledger as "gemini" usage and count in the
//// day's spend; past the cap, the memory stands aside.

import gleeunit/should
import supernova/core/resource_ledger/actor as ledger_actor
import supernova/memory/ledger

pub fn charges_count_in_the_days_spend_test() {
  let assert Ok(book) = ledger_actor.start()
  // The ledger stamps usage with its own clock: ask about the same day.
  let now = current_timestamp()
  ledger.within_budget(book, 1.0, now) |> should.be_true()
  // 1 million Decision tokens (US$ 0,10) and 1 million embedding tokens
  // (US$ 0,20); nothing recorded for zero.
  ledger.charge(book, "telegram:42", 1_000_000, 1_000_000)
  ledger.charge(book, "telegram:42", 0, 0)
  let assert Ok(#(_, spent)) = ledger_actor.try_spend_today(book, now)
  { spent >. 0.29 && spent <. 0.31 } |> should.be_true()
  ledger.within_budget(book, 0.3, now) |> should.be_false()
  ledger.within_budget(book, 1.0, now) |> should.be_true()
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int
