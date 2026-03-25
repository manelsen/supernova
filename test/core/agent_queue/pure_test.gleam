//// Tests for the Agent Queue Pure module
////
//// Pure tests — no I/O, no actors, no FFI.

import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/agent_queue/pure
import supernova/core/agent_queue/types.{type AgentQueueState, High, Low, Normal}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Helpers
// ============================================================================

fn empty_state() -> AgentQueueState {
  types.initial_state()
}

// ============================================================================
// enqueue Tests
// ============================================================================

pub fn enqueue_returns_job_id_test() {
  let state = empty_state()

  let #(_state, result) = pure.enqueue(state, "agent_1", "task", High, 0, 1000)

  case result {
    Ok(job_id) -> {
      job_id |> should.equal("job_0")
    }
    _ -> should.fail()
  }
}

pub fn enqueue_increments_id_test() {
  let state = empty_state()

  let #(state, r1) = pure.enqueue(state, "agent_1", "task1", High, 0, 1000)
  let #(_state, r2) = pure.enqueue(state, "agent_1", "task2", Normal, 0, 1001)

  let assert Ok(id1) = r1
  let assert Ok(id2) = r2
  id1 |> should.equal("job_0")
  id2 |> should.equal("job_1")
}

pub fn enqueue_rejects_expired_deadline_test() {
  let state = empty_state()

  // deadline=500, now=1000 → expired
  let #(_state, result) =
    pure.enqueue(state, "agent_1", "task", High, 500, 1000)

  case result {
    Error(_) -> Nil
    _ -> should.fail()
  }
}

pub fn enqueue_accepts_future_deadline_test() {
  let state = empty_state()

  // deadline=2000, now=1000 → valid
  let #(_state, result) =
    pure.enqueue(state, "agent_1", "task", High, 2000, 1000)

  case result {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

pub fn enqueue_accepts_zero_deadline_test() {
  let state = empty_state()

  // deadline=0 means no deadline
  let #(_state, result) = pure.enqueue(state, "agent_1", "task", High, 0, 1000)

  case result {
    Ok(_) -> Nil
    _ -> should.fail()
  }
}

// ============================================================================
// Priority Ordering Tests
// ============================================================================

pub fn next_returns_high_priority_first_test() {
  let state = empty_state()

  // Enqueue in order: Low, Normal, High
  let #(state, _) = pure.enqueue(state, "agent_1", "low_task", Low, 0, 1000)
  let #(state, _) =
    pure.enqueue(state, "agent_1", "normal_task", Normal, 0, 1001)
  let #(state, _) = pure.enqueue(state, "agent_1", "high_task", High, 0, 1002)

  let #(_state, result) = pure.next(state, "agent_1", 1003)

  case result {
    Ok(job) -> {
      job.prompt |> should.equal("high_task")
      job.priority |> should.equal(High)
    }
    _ -> should.fail()
  }
}

pub fn next_returns_normal_before_low_test() {
  let state = empty_state()

  let #(state, _) = pure.enqueue(state, "agent_1", "low_task", Low, 0, 1000)
  let #(state, _) =
    pure.enqueue(state, "agent_1", "normal_task", Normal, 0, 1001)

  // First should be Normal
  let #(state, result) = pure.next(state, "agent_1", 1002)
  let assert Ok(job) = result
  job.priority |> should.equal(Normal)

  // Second should be Low
  let #(_state, result) = pure.next(state, "agent_1", 1002)
  let assert Ok(job) = result
  job.priority |> should.equal(Low)
}

pub fn next_fifo_within_same_priority_test() {
  let state = empty_state()

  let #(state, _) = pure.enqueue(state, "agent_1", "first", Normal, 0, 1000)
  let #(state, _) = pure.enqueue(state, "agent_1", "second", Normal, 0, 1001)

  let #(state, result) = pure.next(state, "agent_1", 1002)
  let assert Ok(job) = result
  job.prompt |> should.equal("first")

  let #(_state, result) = pure.next(state, "agent_1", 1002)
  let assert Ok(job) = result
  job.prompt |> should.equal("second")
}

pub fn next_returns_error_when_empty_test() {
  let state = empty_state()

  let #(_state, result) = pure.next(state, "agent_1", 1000)

  case result {
    Error(_) -> Nil
    _ -> should.fail()
  }
}

// ============================================================================
// Deadline Tests
// ============================================================================

pub fn next_skips_expired_job_test() {
  let state = empty_state()

  // Enqueue a job with deadline=1500
  let #(state, _) = pure.enqueue(state, "agent_1", "expired", High, 1500, 1000)
  // Enqueue a valid job
  let #(state, _) = pure.enqueue(state, "agent_1", "valid", Normal, 0, 1001)

  // At time 2000, the High job is expired
  let #(_state, result) = pure.next(state, "agent_1", 2000)

  case result {
    Ok(job) -> {
      job.prompt |> should.equal("valid")
    }
    _ -> should.fail()
  }
}

pub fn next_returns_valid_job_before_expired_test() {
  let state = empty_state()

  // Enqueue a valid High job
  let #(state, _) = pure.enqueue(state, "agent_1", "valid_high", High, 0, 1000)
  // Enqueue an expired High job
  let #(state, _) =
    pure.enqueue(state, "agent_1", "expired_high", High, 1200, 1001)

  // At time 1500, the second High job is expired
  let #(_state, result) = pure.next(state, "agent_1", 1500)

  case result {
    Ok(job) -> {
      job.prompt |> should.equal("valid_high")
    }
    _ -> should.fail()
  }
}

// ============================================================================
// cancel Tests
// ============================================================================

pub fn cancel_removes_job_test() {
  let state = empty_state()

  let #(state, r1) = pure.enqueue(state, "agent_1", "task1", High, 0, 1000)
  let #(state, _) = pure.enqueue(state, "agent_1", "task2", Normal, 0, 1001)
  let assert Ok(job_id) = r1

  let #(state, result) = pure.cancel(state, job_id)
  case result {
    Ok(_) -> Nil
    _ -> should.fail()
  }

  // Queue should now have only task2
  pure.count(state, "agent_1") |> should.equal(1)
}

pub fn cancel_returns_error_for_unknown_job_test() {
  let state = empty_state()

  let #(_state, result) = pure.cancel(state, "nonexistent")

  case result {
    Error(_) -> Nil
    _ -> should.fail()
  }
}

pub fn cancel_across_agents_test() {
  let state = empty_state()

  let #(state, r1) = pure.enqueue(state, "agent_1", "task1", High, 0, 1000)
  let #(state, _) = pure.enqueue(state, "agent_2", "task2", Normal, 0, 1001)
  let assert Ok(job_id) = r1

  let #(state, result) = pure.cancel(state, job_id)
  case result {
    Ok(_) -> Nil
    _ -> should.fail()
  }

  // agent_1 should be empty, agent_2 should still have 1 job
  pure.count(state, "agent_1") |> should.equal(0)
  pure.count(state, "agent_2") |> should.equal(1)
}

// ============================================================================
// drain Tests
// ============================================================================

pub fn drain_returns_all_jobs_sorted_test() {
  let state = empty_state()

  let #(state, _) = pure.enqueue(state, "agent_1", "low", Low, 0, 1000)
  let #(state, _) = pure.enqueue(state, "agent_1", "high", High, 0, 1001)
  let #(state, _) = pure.enqueue(state, "agent_1", "normal", Normal, 0, 1002)

  let #(state, jobs) = pure.drain(state, "agent_1")

  list.length(jobs) |> should.equal(3)

  // Should be sorted by priority
  let assert [first, second, third] = jobs
  first.priority |> should.equal(High)
  second.priority |> should.equal(Normal)
  third.priority |> should.equal(Low)

  // Queue should be empty after drain
  pure.count(state, "agent_1") |> should.equal(0)
}

pub fn drain_empty_queue_test() {
  let state = empty_state()

  let #(_state, jobs) = pure.drain(state, "agent_1")

  list.is_empty(jobs) |> should.be_true()
}

pub fn drain_only_affects_target_agent_test() {
  let state = empty_state()

  let #(state, _) = pure.enqueue(state, "agent_1", "task1", High, 0, 1000)
  let #(state, _) = pure.enqueue(state, "agent_2", "task2", Normal, 0, 1001)

  let #(state, jobs) = pure.drain(state, "agent_1")

  list.length(jobs) |> should.equal(1)
  pure.count(state, "agent_1") |> should.equal(0)
  pure.count(state, "agent_2") |> should.equal(1)
}

// ============================================================================
// list_jobs Tests
// ============================================================================

pub fn list_jobs_returns_sorted_without_removing_test() {
  let state = empty_state()

  let #(state, _) = pure.enqueue(state, "agent_1", "low", Low, 0, 1000)
  let #(state, _) = pure.enqueue(state, "agent_1", "high", High, 0, 1001)

  let jobs = pure.list_jobs(state, "agent_1")

  list.length(jobs) |> should.equal(2)
  let assert [first, _] = jobs
  first.priority |> should.equal(High)

  // Count should still be 2 (not removed)
  pure.count(state, "agent_1") |> should.equal(2)
}

// ============================================================================
// count Tests
// ============================================================================

pub fn count_empty_queue_test() {
  let state = empty_state()

  pure.count(state, "agent_1") |> should.equal(0)
}

pub fn count_after_enqueue_test() {
  let state = empty_state()

  let #(state, _) = pure.enqueue(state, "agent_1", "task", High, 0, 1000)

  pure.count(state, "agent_1") |> should.equal(1)
}

// ============================================================================
// Multi-Agent Tests
// ============================================================================

pub fn agents_have_independent_queues_test() {
  let state = empty_state()

  let #(state, _) = pure.enqueue(state, "agent_1", "task1", High, 0, 1000)
  let #(state, _) = pure.enqueue(state, "agent_2", "task2", Low, 0, 1001)

  pure.count(state, "agent_1") |> should.equal(1)
  pure.count(state, "agent_2") |> should.equal(1)

  let #(_state, result) = pure.next(state, "agent_1", 1002)
  let assert Ok(job) = result
  job.agent_id |> should.equal("agent_1")
}
