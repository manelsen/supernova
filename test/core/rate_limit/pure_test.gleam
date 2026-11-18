//// Tests for the Rate Limit pure module
////
//// Pure tests with an injected clock — no actors, no I/O, no FFI.

import gleeunit
import gleeunit/should
import supernova/core/rate_limit/pure

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn limit_is_enforced_test() {
  let state = pure.new_state()

  let #(state, first) = pure.check(state, 2, 1000)
  first |> should.equal(pure.Allowed)

  let #(state, second) = pure.check(state, 2, 2000)
  second |> should.equal(pure.Allowed)

  let #(state, third) = pure.check(state, 2, 3000)
  third |> should.equal(pure.RateLimited(notify: True))

  let #(_state, fourth) = pure.check(state, 2, 4000)
  fourth |> should.equal(pure.RateLimited(notify: False))
}

pub fn rejected_messages_do_not_extend_the_window_test() {
  // One accepted message at t=0. Rejections between 0 and 60 s must not be
  // counted, so the window drains exactly 60 s after the accepted hit.
  let #(state, _) = pure.check(pure.new_state(), 1, 0)

  let #(state, rejected) = pure.check(state, 1, 59_999)
  rejected |> should.equal(pure.RateLimited(notify: True))

  let #(state, allowed) = pure.check(state, 1, 60_000)
  allowed |> should.equal(pure.Allowed)

  // The new hit at 60 000 now blocks the next message.
  let #(_state, next) = pure.check(state, 1, 60_001)
  next |> should.equal(pure.RateLimited(notify: False))
}

pub fn window_slides_test() {
  let #(state, _) = pure.check(pure.new_state(), 2, 1000)
  let #(state, _) = pure.check(state, 2, 2000)

  // Still inside the minute: both hits count.
  let #(state, limited) = pure.check(state, 2, 30_000)
  limited |> should.equal(pure.RateLimited(notify: True))

  // 1 000 ms falls out of the window; one slot is free again.
  let #(state, allowed) = pure.check(state, 2, 61_000)
  allowed |> should.equal(pure.Allowed)

  // 2 000 ms hit is still inside; the 30 000 rejection was not recorded.
  let #(_state, limited_again) = pure.check(state, 2, 61_500)
  limited_again |> should.equal(pure.RateLimited(notify: False))
}

pub fn notice_once_per_minute_test() {
  // limit 0 always rejects, which lets us exercise the warning throttle.
  let #(state, first) = pure.check(pure.new_state(), 0, 10_000)
  first |> should.equal(pure.RateLimited(notify: True))

  let #(state, second) = pure.check(state, 0, 20_000)
  second |> should.equal(pure.RateLimited(notify: False))

  let #(state, third) = pure.check(state, 0, 69_999)
  third |> should.equal(pure.RateLimited(notify: False))

  let #(_state, fourth) = pure.check(state, 0, 70_000)
  fourth |> should.equal(pure.RateLimited(notify: True))
}

pub fn admin_minus_one_is_unlimited_test() {
  let state =
    pure.RateState(hits: [1000, 2000, 3000, 4000, 5000], last_notice: 9999)

  let #(next, decision) = pure.check(state, -1, 6000)

  decision |> should.equal(pure.Allowed)
  next |> should.equal(state)
}

pub fn limit_exactly_at_capacity_is_allowed_test() {
  let #(state, _) = pure.check(pure.new_state(), 1, 1000)

  // A limit of 1 permits one message per minute, not zero.
  state.hits |> should.equal([1000])
}
