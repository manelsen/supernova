//// Tests for Executor with checkpoint/yield integration

import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import supernova/core/budget_policy/actor as budget_actor
import supernova/core/budget_policy/types as budget_types
import supernova/core/checkpoint/actor as checkpoint_actor
import supernova/core/checkpoint/types.{Abort}
import supernova/core/executor
import supernova/llm/provider
import supernova/tools/safe_shell

pub fn main() -> Nil {
  gleeunit.main()
}

fn mock_config() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

fn base_yield_config(
  store: checkpoint_actor.CheckpointHandle,
  session_id: String,
) -> executor.YieldConfig {
  executor.YieldConfig(
    session_id: session_id,
    checkpoint_store: store,
    yield_interval: 1,
    timeout_ms: None,
    started_at_ms: 0,
    budget_policy: None,
    budget_agent_id: None,
  )
}

// ============================================================================
// run_with_checkpoint Tests
// ============================================================================

pub fn run_with_checkpoint_no_yield_test() {
  let assert Ok(store) = checkpoint_actor.start()

  let messages = [provider.user_message("Hello")]
  let yield_config = base_yield_config(store, "session_1")

  // No yield forced — should complete normally
  let result =
    executor.run_with_checkpoint(messages, mock_config(), [], yield_config)
  result
  |> should.be_ok()

  checkpoint_actor.stop(store)
  process.sleep(100)
}

pub fn run_with_checkpoint_abort_test() {
  let assert Ok(store) = checkpoint_actor.start()

  checkpoint_actor.force_yield(store, "session_abort", Abort("test abort"))

  let messages = [provider.user_message("Hello")]
  let yield_config = base_yield_config(store, "session_abort")

  let result =
    executor.run_with_checkpoint(messages, mock_config(), [], yield_config)

  case result {
    Error(executor.YieldAborted(reason)) -> reason |> should.equal("test abort")
    _ -> should.fail()
  }

  checkpoint_actor.stop(store)
  process.sleep(100)
}

pub fn run_with_checkpoint_manual_pause_saves_checkpoint_test() {
  let assert Ok(store) = checkpoint_actor.start()

  let messages = [provider.user_message("Hello")]
  let yield_config = base_yield_config(store, "session_pause")

  executor.request_manual_pause(yield_config, "manual test")

  let result =
    executor.run_with_checkpoint(messages, mock_config(), [], yield_config)

  case result {
    Error(executor.YieldPaused(checkpoint_id)) -> {
      let assert Ok(checkpoint) = checkpoint_actor.restore(store, checkpoint_id)

      dict.get(checkpoint.context_metadata, "yield_reason")
      |> should.equal(Ok("manual"))
      dict.get(checkpoint.context_metadata, "yield_detail")
      |> should.equal(Ok("manual test"))
      checkpoint.history
      |> should.equal(messages)
    }
    _ -> should.fail()
  }

  checkpoint_actor.stop(store)
  process.sleep(100)
}

pub fn run_with_checkpoint_timeout_saves_checkpoint_test() {
  let assert Ok(store) = checkpoint_actor.start()

  let messages = [provider.user_message("Hello")]
  let yield_config =
    executor.YieldConfig(
      ..base_yield_config(store, "session_timeout"),
      timeout_ms: Some(0),
    )

  let result =
    executor.run_with_checkpoint(messages, mock_config(), [], yield_config)

  case result {
    Error(executor.YieldPaused(checkpoint_id)) -> {
      let assert Ok(checkpoint) = checkpoint_actor.restore(store, checkpoint_id)

      dict.get(checkpoint.context_metadata, "yield_reason")
      |> should.equal(Ok("timeout"))
      dict.get(checkpoint.context_metadata, "yield_detail")
      |> should.equal(Ok("timeout exceeded"))
      checkpoint.history
      |> should.equal(messages)
    }
    _ -> should.fail()
  }

  checkpoint_actor.stop(store)
  process.sleep(100)
}

pub fn run_with_checkpoint_budget_exhaustion_saves_pending_tool_test() {
  let assert Ok(store) = checkpoint_actor.start()
  let assert Ok(policy) =
    budget_actor.start_with_config(
      budget_types.BudgetConfig(
        tokens_per_hour: 100_000,
        tool_calls_per_minute: 0,
        tool_calls_per_hour: -1,
        max_recursion_depth: 5,
        max_sub_agents: 10,
      ),
      20,
    )

  let messages = [provider.user_message("Run a safe command")]
  let yield_config =
    executor.YieldConfig(
      ..base_yield_config(store, "session_budget"),
      budget_policy: Some(policy),
      budget_agent_id: Some("session_budget"),
    )

  let result =
    executor.run_with_checkpoint(
      messages,
      mock_config(),
      [safe_shell.tool()],
      yield_config,
    )

  case result {
    Error(executor.YieldPaused(checkpoint_id)) -> {
      let assert Ok(checkpoint) = checkpoint_actor.restore(store, checkpoint_id)

      dict.get(checkpoint.context_metadata, "yield_reason")
      |> should.equal(Ok("budget_exhausted"))
      case checkpoint.pending_tool {
        Some(provider.ToolCall(_id, name, arguments)) -> {
          name |> should.equal("safe_shell")
          arguments |> should.equal("{\"command\":\"pwd\"}")
        }
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }

  budget_actor.stop(policy)
  checkpoint_actor.stop(store)
  process.sleep(100)
}
