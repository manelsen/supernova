//// Failed polls back off and never expose the request URL.

import gleam/string
import gleeunit/should
import supernova/adapters/telegram

pub fn backoff_doubles_up_to_thirty_seconds_test() {
  let error = telegram.NetworkError("econnrefused")
  telegram.poll_backoff_ms(error, 0) |> should.equal(1000)
  telegram.poll_backoff_ms(error, 1) |> should.equal(2000)
  telegram.poll_backoff_ms(error, 4) |> should.equal(16_000)
  telegram.poll_backoff_ms(error, 5) |> should.equal(30_000)
  telegram.poll_backoff_ms(error, 50) |> should.equal(30_000)
}

pub fn rate_limit_waits_what_telegram_asks_test() {
  telegram.poll_backoff_ms(telegram.RateLimitError(7), 0)
  |> should.equal(7000)
}

pub fn error_description_hides_details_test() {
  telegram.describe_poll_error(telegram.HttpError(
    "https://api.telegram.org/bot123:secret/getUpdates",
  ))
  |> string.contains("secret")
  |> should.be_false()
  telegram.describe_poll_error(telegram.ApiError(401, "Unauthorized"))
  |> should.equal("telegram api error 401: Unauthorized")
}
