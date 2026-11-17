import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleam/string
import gleeunit
import gleeunit/should
import supernova/llm/failover
import supernova/llm/failover_cooldown/actor as cooldown_actor
import supernova/llm/failover_cooldown/types as cooldown_types
import supernova/llm/provider

pub fn main() {
  gleeunit.main()
}

fn unknown_provider(name: String) -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: name,
    api_key: None,
    base_url: None,
    default_model: "unused",
  )
}

pub fn chat_all_unknown_providers_returns_aggregated_error_test() {
  let providers = [unknown_provider("unknown-a"), unknown_provider("unknown-b")]
  let messages = [provider.user_message("hello")]

  case failover.chat(messages, providers, []) {
    Ok(_) -> panic as "expected aggregated APIError"
    Error(provider.APIError(status: 0, message: message)) -> {
      string.contains(message, "Provider not found: unknown-a")
      |> should.equal(True)
      string.contains(message, "Provider not found: unknown-b")
      |> should.equal(True)
    }
    Error(_) -> panic as "expected provider.APIError"
  }
}

pub fn chat_with_cooldown_skips_provider_after_first_failure_test() {
  let assert Ok(cooldown_ref) = cooldown_actor.start(cooldown_types.default_config())
  let provider = unknown_provider("unknown-provider")
  let messages = [provider.user_message("hello")]

  let first =
    failover.chat_with_cooldown(
      messages,
      [provider],
      [],
      cooldown_ref,
    )
  let second =
    failover.chat_with_cooldown(
      messages,
      [provider],
      [],
      cooldown_ref,
    )

  case first {
    Error(provider.APIError(status: 0, message: message)) -> {
      string.contains(message, "Provider not found: unknown-provider")
      |> should.equal(True)
    }
    _ -> panic as "expected provider not found on first attempt"
  }

  case second {
    Error(provider.APIError(status: 0, message: message)) -> {
      string.contains(message, "in cooldown, skipping")
      |> should.equal(True)
    }
    _ -> panic as "expected cooldown skip on second attempt"
  }
}

pub fn cooldown_actor_records_failure_and_success_test() {
  let assert Ok(cooldown_ref) = cooldown_actor.start(cooldown_types.default_config())

  let reply_1 =
    actor.call(
      cooldown_ref,
      waiting: 1_000,
      sending: cooldown_actor.CheckCooldown("provider-a", _),
    )
  reply_1 |> should.equal(cooldown_types.NotInCooldown)

  let cooldown_actor.FailureRecorded(_) =
    actor.call(
      cooldown_ref,
      waiting: 1_000,
      sending: cooldown_actor.RecordFailure("provider-a", _),
    )

  let reply_2 =
    actor.call(
      cooldown_ref,
      waiting: 1_000,
      sending: cooldown_actor.CheckCooldown("provider-a", _),
    )
  case reply_2 {
    cooldown_types.InCooldown(provider_name: "provider-a", remaining_ms: remaining) -> {
      { remaining > 0 } |> should.equal(True)
    }
    _ -> panic as "expected provider-a in cooldown after failure"
  }

  let cooldown_actor.SuccessRecorded(_) =
    actor.call(
      cooldown_ref,
      waiting: 1_000,
      sending: cooldown_actor.RecordSuccess("provider-a", _),
    )

  let reply_3 =
    actor.call(
      cooldown_ref,
      waiting: 1_000,
      sending: cooldown_actor.CheckCooldown("provider-a", _),
    )
  reply_3 |> should.equal(cooldown_types.NotInCooldown)

  list.length([reply_1, reply_2, reply_3]) |> should.equal(3)
}
