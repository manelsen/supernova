//// Tests for Cron Scheduler.

import gleeunit/should
import supernova/core/cron/scheduler

pub fn new_scheduler_test() {
  let state = scheduler.new()

  scheduler.list_jobs(state)
  |> should.equal([])
}

pub fn add_job_test() {
  let state = scheduler.new()

  let state = scheduler.add_job(state, "heartbeat", 5000, fn() { "tick" })

  let jobs = scheduler.list_jobs(state)
  jobs
  |> should.equal(["heartbeat"])
}

pub fn add_multiple_jobs_test() {
  let state = scheduler.new()

  let state = scheduler.add_job(state, "job1", 1000, fn() { "a" })
  let state = scheduler.add_job(state, "job2", 2000, fn() { "b" })

  let jobs = scheduler.list_jobs(state)
  jobs
  |> should.equal(["job1", "job2"])
}

pub fn remove_job_test() {
  let state = scheduler.new()

  let state = scheduler.add_job(state, "to_remove", 1000, fn() { "x" })
  let state = scheduler.add_job(state, "to_keep", 2000, fn() { "y" })

  let state = scheduler.remove_job(state, "to_remove")

  scheduler.list_jobs(state)
  |> should.equal(["to_keep"])
}

pub fn remove_nonexistent_job_test() {
  let state = scheduler.new()

  let state = scheduler.remove_job(state, "nope")

  scheduler.list_jobs(state)
  |> should.equal([])
}

pub fn get_job_interval_test() {
  let state = scheduler.new()

  let state = scheduler.add_job(state, "timed", 30_000, fn() { "ok" })

  scheduler.get_interval(state, "timed")
  |> should.equal(Ok(30_000))
}

pub fn get_nonexistent_interval_test() {
  let state = scheduler.new()

  scheduler.get_interval(state, "ghost")
  |> should.be_error
}
