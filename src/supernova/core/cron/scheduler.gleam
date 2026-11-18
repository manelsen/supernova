//// Cron Scheduler — manages scheduled jobs.
////
//// Pure data structure for job definitions. Execution is handled externally
//// by a runner that checks intervals and triggers handlers.
////
//// ## Usage
////
//// ```gleam
//// let state = scheduler.new()
//// let state = scheduler.add_job(state, "heartbeat", 5000, fn() { "tick" })
//// scheduler.list_jobs(state) // ["heartbeat"]
//// ```

import gleam/dict.{type Dict}
import gleam/list
import gleam/order
import gleam/string

/// A scheduled job.
pub type CronJob {
  CronJob(
    /// Job name (unique identifier)
    name: String,
    /// Interval in milliseconds
    interval_ms: Int,
    /// Handler function (returns a result string)
    handler: fn() -> String,
  )
}

/// Scheduler state.
pub type SchedulerState {
  SchedulerState(jobs: Dict(String, CronJob))
}

/// Create a new empty scheduler.
pub fn new() -> SchedulerState {
  SchedulerState(jobs: dict.new())
}

/// Add a job to the scheduler.
pub fn add_job(
  state: SchedulerState,
  name: String,
  interval_ms: Int,
  handler: fn() -> String,
) -> SchedulerState {
  let job = CronJob(name: name, interval_ms: interval_ms, handler: handler)
  let new_jobs = dict.insert(state.jobs, name, job)
  SchedulerState(jobs: new_jobs)
}

/// Remove a job by name.
pub fn remove_job(state: SchedulerState, name: String) -> SchedulerState {
  let new_jobs = dict.delete(state.jobs, name)
  SchedulerState(jobs: new_jobs)
}

/// List all job names.
pub fn list_jobs(state: SchedulerState) -> List(String) {
  state.jobs
  |> dict.keys
  |> list.sort(string_compare)
}

/// Get a job's interval by name.
pub fn get_interval(
  state: SchedulerState,
  name: String,
) -> Result(Int, String) {
  case dict.get(state.jobs, name) {
    Ok(job) -> Ok(job.interval_ms)
    Error(_) -> Error("Job not found: " <> name)
  }
}

/// Execute a job by name.
pub fn execute_job(
  state: SchedulerState,
  name: String,
) -> Result(String, String) {
  case dict.get(state.jobs, name) {
    Ok(job) -> Ok(job.handler())
    Error(_) -> Error("Job not found: " <> name)
  }
}

fn string_compare(a: String, b: String) -> order.Order {
  string.compare(a, b)
}
