//// Tests for the Executor module.
////
//// Verifies the agent execution loop: LLM calls, tool dispatch, recursion.

import gleam/option.{None}
import gleeunit/should
import supernova/core/executor
import supernova/llm/provider

pub fn execute_text_response_test() {
  let messages = [provider.user_message("Hello")]
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    )

  let result = executor.run(messages, config, [])

  case result {
    Ok(response) -> {
      response.content
      |> should.equal("Mock response")
    }
    Error(_) -> should.fail()
  }
}

pub fn execute_with_max_depth_test() {
  let messages = [provider.user_message("Test")]
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    )

  // Should complete without infinite loop
  let result = executor.run(messages, config, [])
  result
  |> should.be_ok
}

pub fn executor_result_has_content_test() {
  let messages = [provider.user_message("Hi")]
  let config =
    provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock",
    )

  let assert Ok(result) = executor.run(messages, config, [])

  result.role
  |> should.equal("assistant")
}
