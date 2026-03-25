//// Tests for the Agent Queue Actor module
////
//// Integration tests — with actors, with I/O.

import gleam/erlang/process
import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/agent_queue/actor
import supernova/core/agent_queue/types.{High, Low, Normal}

pub fn main() -> Nil {
  gleeunit.main()
}

// ============================================================================
// Actor Lifecycle Tests
// ============================================================================

pub fn start_and_stop_test() {
  let assert Ok(queue) = actor.start()
  actor.stop(queue)

  // Give actor time to terminate
  process.sleep(100)
}

// ============================================================================
// enqueue Tests
// ============================================================================

pub fn enqueue_returns_job_id_test() {
  let assert Ok(queue) = actor.start()

  let result = actor.enqueue(queue, "agent_1", "task", High, 0)
  case result {
    Ok(job_id) -> {
      job_id |> should.equal("job_0")
    }
    _ -> should.fail()
  }

  actor.stop(queue)
  process.sleep(100)
}

pub fn enqueue_multiple_jobs_test() {
  let assert Ok(queue) = actor.start()

  let assert Ok(id1) = actor.enqueue(queue, "agent_1", "task1", High, 0)
  let assert Ok(id2) = actor.enqueue(queue, "agent_1", "task2", Normal, 0)

  id1 |> should.equal("job_0")
  id2 |> should.equal("job_1")

  actor.stop(queue)
  process.sleep(100)
}

pub fn enqueue_rejects_expired_deadline_test() {
  let assert Ok(queue) = actor.start()

  // Use a very old timestamp as deadline (should be expired)
  let result = actor.enqueue(queue, "agent_1", "task", High, 1)
  case result {
    Error(msg) -> {
      msg |> should.equal("Deadline expired for job  at 1")
    }
    _ -> should.fail()
  }

  actor.stop(queue)
  process.sleep(100)
}

// ============================================================================
// next Tests — Priority Ordering
// ============================================================================

pub fn next_returns_high_priority_first_test() {
  let assert Ok(queue) = actor.start()

  let assert Ok(_) = actor.enqueue(queue, "agent_1", "low_task", Low, 0)
  let assert Ok(_) = actor.enqueue(queue, "agent_1", "normal_task", Normal, 0)
  let assert Ok(_) = actor.enqueue(queue, "agent_1", "high_task", High, 0)

  let assert Ok(job) = actor.next(queue, "agent_1")
  job.prompt |> should.equal("high_task")

  actor.stop(queue)
  process.sleep(100)
}

pub fn next_returns_normal_before_low_test() {
  let assert Ok(queue) = actor.start()

  let assert Ok(_) = actor.enqueue(queue, "agent_1", "low_task", Low, 0)
  let assert Ok(_) = actor.enqueue(queue, "agent_1", "normal_task", Normal, 0)

  let assert Ok(job) = actor.next(queue, "agent_1")
  job.priority |> should.equal(Normal)

  let assert Ok(job) = actor.next(queue, "agent_1")
  job.priority |> should.equal(Low)

  actor.stop(queue)
  process.sleep(100)
}

pub fn next_returns_error_when_empty_test() {
  let assert Ok(queue) = actor.start()

  let result = actor.next(queue, "agent_1")
  case result {
    Error(_) -> Nil
    _ -> should.fail()
  }

  actor.stop(queue)
  process.sleep(100)
}

pub fn next_fifo_within_same_priority_test() {
  let assert Ok(queue) = actor.start()

  let assert Ok(_) = actor.enqueue(queue, "agent_1", "first", Normal, 0)
  let assert Ok(_) = actor.enqueue(queue, "agent_1", "second", Normal, 0)

  let assert Ok(job) = actor.next(queue, "agent_1")
  job.prompt |> should.equal("first")

  let assert Ok(job) = actor.next(queue, "agent_1")
  job.prompt |> should.equal("second")

  actor.stop(queue)
  process.sleep(100)
}

// ============================================================================
// cancel Tests
// ============================================================================

pub fn cancel_removes_job_test() {
  let assert Ok(queue) = actor.start()

  let assert Ok(id1) = actor.enqueue(queue, "agent_1", "task1", High, 0)
  let assert Ok(_) = actor.enqueue(queue, "agent_1", "task2", Normal, 0)

  let result = actor.cancel(queue, id1)
  case result {
    Ok(_) -> Nil
    _ -> should.fail()
  }

  actor.count(queue, "agent_1") |> should.equal(1)

  actor.stop(queue)
  process.sleep(100)
}

pub fn cancel_returns_error_for_unknown_test() {
  let assert Ok(queue) = actor.start()

  let result = actor.cancel(queue, "nonexistent")
  case result {
    Error(_) -> Nil
    _ -> should.fail()
  }

  actor.stop(queue)
  process.sleep(100)
}

// ============================================================================
// drain Tests
// ============================================================================

pub fn drain_returns_all_jobs_sorted_test() {
  let assert Ok(queue) = actor.start()

  let assert Ok(_) = actor.enqueue(queue, "agent_1", "low", Low, 0)
  let assert Ok(_) = actor.enqueue(queue, "agent_1", "high", High, 0)
  let assert Ok(_) = actor.enqueue(queue, "agent_1", "normal", Normal, 0)

  let jobs = actor.drain(queue, "agent_1")

  list.length(jobs) |> should.equal(3)

  let assert [first, second, third] = jobs
  first.priority |> should.equal(High)
  second.priority |> should.equal(Normal)
  third.priority |> should.equal(Low)

  // Queue should be empty after drain
  actor.count(queue, "agent_1") |> should.equal(0)

  actor.stop(queue)
  process.sleep(100)
}

pub fn drain_empty_queue_test() {
  let assert Ok(queue) = actor.start()

  let jobs = actor.drain(queue, "agent_1")
  list.is_empty(jobs) |> should.be_true()

  actor.stop(queue)
  process.sleep(100)
}

pub fn drain_only_affects_target_agent_test() {
  let assert Ok(queue) = actor.start()

  let assert Ok(_) = actor.enqueue(queue, "agent_1", "task1", High, 0)
  let assert Ok(_) = actor.enqueue(queue, "agent_2", "task2", Normal, 0)

  let jobs = actor.drain(queue, "agent_1")
  list.length(jobs) |> should.equal(1)

  actor.count(queue, "agent_1") |> should.equal(0)
  actor.count(queue, "agent_2") |> should.equal(1)

  actor.stop(queue)
  process.sleep(100)
}

// ============================================================================
// list_jobs Tests
// ============================================================================

pub fn list_jobs_returns_sorted_without_removing_test() {
  let assert Ok(queue) = actor.start()

  let assert Ok(_) = actor.enqueue(queue, "agent_1", "low", Low, 0)
  let assert Ok(_) = actor.enqueue(queue, "agent_1", "high", High, 0)

  let jobs = actor.list_jobs(queue, "agent_1")

  list.length(jobs) |> should.equal(2)
  let assert [first, _] = jobs
  first.priority |> should.equal(High)

  // Count should still be 2
  actor.count(queue, "agent_1") |> should.equal(2)

  actor.stop(queue)
  process.sleep(100)
}

// ============================================================================
// count Tests
// ============================================================================

pub fn count_empty_queue_test() {
  let assert Ok(queue) = actor.start()

  actor.count(queue, "agent_1") |> should.equal(0)

  actor.stop(queue)
  process.sleep(100)
}

pub fn count_after_enqueue_test() {
  let assert Ok(queue) = actor.start()

  let assert Ok(_) = actor.enqueue(queue, "agent_1", "task", High, 0)
  actor.count(queue, "agent_1") |> should.equal(1)

  actor.stop(queue)
  process.sleep(100)
}

// ============================================================================
// Multi-Agent Tests
// ============================================================================

pub fn agents_have_independent_queues_test() {
  let assert Ok(queue) = actor.start()

  let assert Ok(_) = actor.enqueue(queue, "agent_1", "task1", High, 0)
  let assert Ok(_) = actor.enqueue(queue, "agent_2", "task2", Low, 0)

  actor.count(queue, "agent_1") |> should.equal(1)
  actor.count(queue, "agent_2") |> should.equal(1)

  let assert Ok(job) = actor.next(queue, "agent_1")
  job.agent_id |> should.equal("agent_1")

  actor.stop(queue)
  process.sleep(100)
}
