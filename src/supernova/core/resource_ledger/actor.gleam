//// Resource Ledger — Actor
////
//// Singleton actor that maintains resource consumption counters per agent,
//// plus a per-principal usage trail that can be persisted as JSON Lines.
//// Delegates pure logic to the pure module, executes side effects via FFI.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(ledger) = actor.start()
//// let assert Ok(_) = actor.charge_llm(ledger, "agent_1", 100, 50)
//// let assert Ok(counters) = actor.get_snapshot(ledger, "agent_1")
//// actor.stop(ledger)
//// ```
////
//// With persistence (one `<dir>/YYYY-MM-DD.jsonl` file per UTC day):
////
//// ```gleam
//// let assert Ok(ledger) = actor.start_persistent("/var/lib/supernova/usage")
//// actor.record_llm_usage(ledger, "user_1", "openai", "gpt-4o", 100, 50, 0.01)
//// actor.stop(ledger)
//// ```

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import supernova/core/resource_ledger/pure
import supernova/core/resource_ledger/types.{
  type LedgerCommand, type LedgerError, type LedgerState, type ResourceCounters,
  type ResourceType, type UsageEvent, EmitTelemetry, LLMUsage, LedgerState,
  ToolUsage, WriteAudit,
}
import supernova/core/safe_call
import supernova/llm/pricing

// ============================================================================
// FFI — Timestamp, Audit, File System (Erlang)
// ============================================================================

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

/// Write audit log entry (Erlang FFI).
@external(erlang, "supernova_ledger_ffi", "write_audit")
fn ffi_write_audit(
  agent_id: String,
  resource: String,
  amount: Int,
  timestamp: Int,
) -> Result(Nil, String)

/// Emit telemetry event (Erlang FFI).
@external(erlang, "supernova_telemetry_ffi", "write_event")
fn ffi_write_event(
  name: String,
  timestamp: Int,
  agent_id: String,
) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "append_file")
fn ffi_append_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "list_dir")
fn ffi_list_dir(path: String) -> Result(List(String), String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ffi_ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn ffi_delete_file(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn ffi_file_exists(path: String) -> Result(Bool, String)

// ============================================================================
// Types
// ============================================================================

/// Messages that the ledger actor handles.
pub type LedgerMessage {
  /// Charge LLM tokens (prompt + completion)
  ChargeLLM(
    reply_to: Subject(Result(Nil, LedgerError)),
    agent_id: String,
    prompt_tokens: Int,
    completion_tokens: Int,
  )
  /// Charge a tool call
  ChargeTool(
    reply_to: Subject(Result(Nil, LedgerError)),
    agent_id: String,
    tool_name: String,
  )
  /// Charge storage operation
  ChargeStorage(
    reply_to: Subject(Result(Nil, LedgerError)),
    agent_id: String,
    reads: Int,
    writes: Int,
  )
  /// Charge CPU time
  ChargeCPU(
    reply_to: Subject(Result(Nil, LedgerError)),
    agent_id: String,
    cpu_time_ms: Int,
  )
  /// Get resource counters snapshot for an agent
  GetSnapshot(
    reply_to: Subject(Result(ResourceCounters, LedgerError)),
    agent_id: String,
  )
  /// Check if quota exceeded
  CheckQuota(
    reply_to: Subject(Result(Nil, LedgerError)),
    agent_id: String,
    resource: ResourceType,
    limit: Int,
  )
  /// Reset counters for an agent
  ResetCounters(reply_to: Subject(Result(Nil, LedgerError)), agent_id: String)
  /// Get total tokens for an agent
  GetTotalTokens(reply_to: Subject(Int), agent_id: String)
  /// Get total tool calls for an agent
  GetTotalToolCalls(reply_to: Subject(Int), agent_id: String)
  /// Record a completed LLM call in the usage trail
  RecordLLMUsage(
    reply_to: Subject(Nil),
    principal_id: String,
    provider: String,
    model: String,
    prompt_tokens: Int,
    completion_tokens: Int,
    cost_usd: Float,
    call_id: String,
  )
  /// Reserve estimated spend for one LLM call before it is admitted.
  AdmitLLMCall(
    reply_to: Subject(Result(Nil, String)),
    call_id: String,
    cap_usd: Float,
    estimate_usd: Float,
  )
  /// Drop an unrecorded reservation (failed call or shutdown).
  ReleaseReservation(reply_to: Subject(Nil), call_id: String)
  /// Return the current local day and its LLM spend.
  GetSpendToday(reply_to: Subject(#(String, Float)), now: Int)
  /// Return the sum of all open reservation estimates.
  GetOpenReservationsTotal(reply_to: Subject(Result(Float, Nil)))
  /// Record a tool invocation in the usage trail
  RecordToolUsage(
    reply_to: Subject(Nil),
    principal_id: String,
    tool_name: String,
    ok: Bool,
  )
  /// Get the usage trail for one principal
  GetUsage(reply_to: Subject(List(UsageEvent)), principal_id: String)
  /// Get the full usage trail
  GetAllUsage(reply_to: Subject(List(UsageEvent)))
  /// Get the total LLM cost for a UTC day
  GetDailyCost(reply_to: Subject(Float), day: String)
  /// Get the LLM cost for a UTC day for one principal
  GetDailyCostFor(reply_to: Subject(Float), day: String, principal_id: String)
  /// Delete usage trail files older than the retention window
  RotateOldFiles(reply_to: Subject(Nil), now: Int)
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to the running ledger actor.
pub type ResourceLedger =
  Subject(LedgerMessage)

/// Internal actor state: aggregate counters plus the usage trail.
type Reservation {
  Reservation(estimate_usd: Float, expires_at: Int)
}

type ActorState {
  ActorState(
    counters: Dict(String, ResourceCounters),
    /// Newest first: adding is O(1). It was appended to (a copy of every
    /// event of the last 30 days on each new one, inside the actor every
    /// turn goes through); readers that want recording order reverse it.
    events: List(UsageEvent),
    /// LLM cost by (UTC day, principal), kept as events arrive, so a
    /// person's daily cost is a lookup instead of a scan of every event.
    person_day_totals: Dict(#(String, String), Float),
    directory: Option(String),
    now: fn() -> Int,
    day_key: fn(Int) -> String,
    day_totals: Dict(String, Float),
    reservations: Dict(String, Reservation),
    recorded_calls: Dict(String, Bool),
  )
}

const reservation_ttl_ms = 600_000

fn total_for_day(totals: Dict(String, Float), day: String) -> Float {
  dict.get(totals, day) |> result.unwrap(0.0)
}

fn reservations_total(reservations: Dict(String, Reservation)) -> Float {
  reservations
  |> dict.values
  |> list.fold(0.0, fn(total, reservation) { total +. reservation.estimate_usd })
}

fn purge_expired(state: ActorState, now: Int) -> ActorState {
  let reservations =
    dict.filter(state.reservations, fn(_, reservation) {
      reservation.expires_at > now
    })
  ActorState(..state, reservations: reservations)
}

fn recompute_totals(
  events: List(UsageEvent),
  day_key: fn(Int) -> String,
) -> Dict(String, Float) {
  list.fold(events, dict.new(), fn(totals, event) {
    case event {
      LLMUsage(timestamp: timestamp, cost_usd: cost, ..) -> {
        let day = day_key(timestamp)
        let total = total_for_day(totals, day)
        dict.insert(totals, day, total +. cost)
      }
      ToolUsage(..) -> totals
    }
  })
}

fn recompute_person_day_totals(
  events: List(UsageEvent),
) -> Dict(#(String, String), Float) {
  list.fold(events, dict.new(), add_person_day_cost)
}

fn add_person_day_cost(
  totals: Dict(#(String, String), Float),
  event: UsageEvent,
) -> Dict(#(String, String), Float) {
  case event {
    LLMUsage(principal_id: principal_id, cost_usd: cost, ..) ->
      dict.upsert(totals, #(pure.event_day(event), principal_id), fn(total) {
        option.unwrap(total, 0.0) +. cost
      })
    ToolUsage(..) -> totals
  }
}

fn recorded_call_ids(events: List(UsageEvent)) -> Dict(String, Bool) {
  list.fold(events, dict.new(), fn(ids, event) {
    case event {
      LLMUsage(call_id: call_id, ..) ->
        case call_id == "" {
          True -> ids
          False -> dict.insert(ids, call_id, True)
        }
      ToolUsage(..) -> ids
    }
  })
}

// ============================================================================
// Actor Handler
// ============================================================================

/// Execute a list of commands returned by pure functions.
fn execute_commands(commands: List(LedgerCommand)) -> Nil {
  list.each(commands, fn(cmd) {
    case cmd {
      WriteAudit(agent_id, resource, amount, timestamp) -> {
        let _ = ffi_write_audit(agent_id, resource, amount, timestamp)
        Nil
      }
      EmitTelemetry(name, measurements) -> {
        let agent_id = measurement_value(measurements, "agent_id")
        let _ = ffi_write_event(name, ffi_current_timestamp(), agent_id)
        Nil
      }
    }
  })
}

fn measurement_value(
  measurements: List(#(String, String)),
  key: String,
) -> String {
  case
    list.find(measurements, fn(entry) {
      let #(entry_key, _) = entry
      entry_key == key
    })
  {
    Ok(entry) -> {
      let #(_, value) = entry
      value
    }
    Error(_) -> "unknown"
  }
}

/// View the aggregate counters as the pure module's state type.
fn ledger_view(state: ActorState) -> LedgerState {
  LedgerState(counters: state.counters)
}

/// Replace the aggregate counters, keeping the usage trail and config.
fn with_counters(state: ActorState, ledger: LedgerState) -> ActorState {
  ActorState(..state, counters: ledger.counters)
}

/// Append an event to the persisted trail, if persistence is enabled.
fn persist_event(state: ActorState, event: UsageEvent) -> Nil {
  case state.directory {
    Some(directory) -> {
      let path = directory <> "/" <> pure.event_file_name(event)
      let _ = ffi_append_file(path, pure.event_to_json(event) <> "\n")
      Nil
    }
    None -> Nil
  }
}

/// Handle incoming messages and update state.
fn handle_message(
  state: ActorState,
  message: LedgerMessage,
) -> actor.Next(ActorState, LedgerMessage) {
  case message {
    ChargeLLM(reply_to, agent_id, prompt_tokens, completion_tokens) -> {
      let timestamp = state.now()

      // Charge prompt tokens
      let #(ledger1, commands1) =
        pure.charge(
          ledger_view(state),
          agent_id,
          types.LLMTokensPrompt,
          prompt_tokens,
          timestamp,
        )
      execute_commands(commands1)

      // Charge completion tokens
      let #(ledger2, commands2) =
        pure.charge(
          ledger1,
          agent_id,
          types.LLMTokensCompletion,
          completion_tokens,
          timestamp,
        )
      execute_commands(commands2)

      actor.send(reply_to, Ok(Nil))
      actor.continue(with_counters(state, ledger2))
    }

    ChargeTool(reply_to, agent_id, tool_name) -> {
      let timestamp = state.now()
      let #(ledger, commands) =
        pure.charge(
          ledger_view(state),
          agent_id,
          types.ToolCall(tool_name),
          1,
          timestamp,
        )
      execute_commands(commands)

      actor.send(reply_to, Ok(Nil))
      actor.continue(with_counters(state, ledger))
    }

    ChargeStorage(reply_to, agent_id, reads, writes) -> {
      let timestamp = state.now()

      // Charge reads
      let #(ledger1, commands1) =
        pure.charge(
          ledger_view(state),
          agent_id,
          types.StorageRead,
          reads,
          timestamp,
        )
      execute_commands(commands1)

      // Charge writes
      let #(ledger2, commands2) =
        pure.charge(ledger1, agent_id, types.StorageWrite, writes, timestamp)
      execute_commands(commands2)

      actor.send(reply_to, Ok(Nil))
      actor.continue(with_counters(state, ledger2))
    }

    ChargeCPU(reply_to, agent_id, cpu_time_ms) -> {
      let timestamp = state.now()
      let #(ledger, commands) =
        pure.charge(
          ledger_view(state),
          agent_id,
          types.CPUTimeMs,
          cpu_time_ms,
          timestamp,
        )
      execute_commands(commands)

      actor.send(reply_to, Ok(Nil))
      actor.continue(with_counters(state, ledger))
    }

    GetSnapshot(reply_to, agent_id) -> {
      let result = pure.snapshot(ledger_view(state), agent_id)
      actor.send(reply_to, result)
      actor.continue(state)
    }

    CheckQuota(reply_to, agent_id, resource, limit) -> {
      let result =
        pure.quota_exceeded(ledger_view(state), agent_id, resource, limit)
      actor.send(reply_to, result)
      actor.continue(state)
    }

    ResetCounters(reply_to, agent_id) -> {
      let timestamp = state.now()
      let #(ledger, commands) =
        pure.reset(ledger_view(state), agent_id, timestamp)
      execute_commands(commands)

      actor.send(reply_to, Ok(Nil))
      actor.continue(with_counters(state, ledger))
    }

    GetTotalTokens(reply_to, agent_id) -> {
      let total = pure.total_tokens(ledger_view(state), agent_id)
      actor.send(reply_to, total)
      actor.continue(state)
    }

    GetTotalToolCalls(reply_to, agent_id) -> {
      let total = pure.total_tool_calls(ledger_view(state), agent_id)
      actor.send(reply_to, total)
      actor.continue(state)
    }

    RecordLLMUsage(
      reply_to,
      principal_id,
      provider,
      model,
      prompt_tokens,
      completion_tokens,
      cost_usd,
      call_id,
    ) -> {
      case call_id != "" && dict.has_key(state.recorded_calls, call_id) {
        True -> {
          actor.send(reply_to, Nil)
          actor.continue(state)
        }
        False -> {
          let timestamp = state.now()
          let event =
            LLMUsage(
              principal_id: principal_id,
              provider: provider,
              model: model,
              prompt_tokens: prompt_tokens,
              completion_tokens: completion_tokens,
              cost_usd: cost_usd,
              timestamp: timestamp,
              call_id: call_id,
            )
          persist_event(state, event)
          let day = state.day_key(timestamp)
          let totals =
            dict.insert(
              state.day_totals,
              day,
              total_for_day(state.day_totals, day) +. cost_usd,
            )
          actor.send(reply_to, Nil)
          actor.continue(
            ActorState(
              ..state,
              events: [event, ..state.events],
              person_day_totals: add_person_day_cost(
                state.person_day_totals,
                event,
              ),
              day_totals: totals,
              reservations: dict.delete(state.reservations, call_id),
              recorded_calls: case call_id {
                "" -> state.recorded_calls
                _ -> dict.insert(state.recorded_calls, call_id, True)
              },
            ),
          )
        }
      }
    }

    AdmitLLMCall(reply_to, call_id, cap_usd, estimate_usd) -> {
      let now = state.now()
      let state = purge_expired(state, now)
      let day = state.day_key(now)
      let open = reservations_total(state.reservations)
      let total = total_for_day(state.day_totals, day)
      let exceeds = case cap_usd <. 0.0 {
        True -> False
        False -> total +. open +. estimate_usd >. cap_usd
      }
      case exceeds {
        True -> {
          actor.send(reply_to, Error("instance cap would be exceeded"))
          actor.continue(state)
        }
        False -> {
          let reservation =
            Reservation(
              estimate_usd: estimate_usd,
              expires_at: now + reservation_ttl_ms,
            )
          actor.send(reply_to, Ok(Nil))
          actor.continue(
            ActorState(
              ..state,
              reservations: dict.insert(
                state.reservations,
                call_id,
                reservation,
              ),
            ),
          )
        }
      }
    }

    ReleaseReservation(reply_to, call_id) -> {
      actor.send(reply_to, Nil)
      actor.continue(
        ActorState(
          ..state,
          reservations: dict.delete(state.reservations, call_id),
        ),
      )
    }

    GetSpendToday(reply_to, now) -> {
      let day = state.day_key(now)
      actor.send(reply_to, #(day, total_for_day(state.day_totals, day)))
      actor.continue(state)
    }

    GetOpenReservationsTotal(reply_to) -> {
      let state = purge_expired(state, state.now())
      actor.send(reply_to, Ok(reservations_total(state.reservations)))
      actor.continue(state)
    }

    RecordToolUsage(reply_to, principal_id, tool_name, ok) -> {
      let event =
        ToolUsage(
          principal_id: principal_id,
          tool_name: tool_name,
          ok: ok,
          timestamp: state.now(),
        )
      persist_event(state, event)

      actor.send(reply_to, Nil)
      actor.continue(ActorState(..state, events: [event, ..state.events]))
    }

    GetUsage(reply_to, principal_id) -> {
      actor.send(
        reply_to,
        pure.usage_for(list.reverse(state.events), principal_id),
      )
      actor.continue(state)
    }

    GetAllUsage(reply_to) -> {
      actor.send(reply_to, list.reverse(state.events))
      actor.continue(state)
    }

    GetDailyCost(reply_to, day) -> {
      actor.send(reply_to, total_for_day(state.day_totals, day))
      actor.continue(state)
    }

    GetDailyCostFor(reply_to, day, principal_id) -> {
      actor.send(
        reply_to,
        dict.get(state.person_day_totals, #(day, principal_id))
          |> result.unwrap(0.0),
      )
      actor.continue(state)
    }

    RotateOldFiles(reply_to, now) -> {
      rotate_directory(state.directory, now)
      let events =
        list.filter(state.events, fn(event) {
          pure.event_within_retention(event, now)
        })
      actor.send(reply_to, Nil)
      actor.continue(
        ActorState(
          ..state,
          events: events,
          person_day_totals: recompute_person_day_totals(events),
          // Call ids older than the retention cannot come back; keeping
          // them grew the map for as long as the process lived.
          recorded_calls: recorded_call_ids(events),
          day_totals: recompute_totals(events, state.day_key),
          reservations: dict.filter(state.reservations, fn(_, reservation) {
            reservation.expires_at > now
          }),
        ),
      )
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Persistence Helpers
// ============================================================================

/// Load every persisted event, oldest day first.
fn load_events(directory: String) -> List(UsageEvent) {
  case ffi_file_exists(directory) {
    Ok(False) -> []
    _ ->
      case ffi_list_dir(directory) {
        Error(_) -> []
        Ok(names) ->
          names
          |> list.filter(pure.is_jsonl_file)
          |> list.sort(string.compare)
          |> list.flat_map(fn(name) {
            load_events_file(directory <> "/" <> name)
          })
      }
  }
}

fn load_events_file(path: String) -> List(UsageEvent) {
  case ffi_read_file(path) {
    Error(_) -> []
    Ok(content) ->
      content
      |> string.split("\n")
      |> list.filter_map(pure.event_from_json)
  }
}

/// Delete trail files older than the retention window.
fn rotate_directory(directory: Option(String), now: Int) -> Nil {
  case directory {
    None -> Nil
    Some(directory) ->
      case ffi_list_dir(directory) {
        Error(_) -> Nil
        Ok(names) ->
          list.each(names, fn(name) {
            case pure.should_rotate(name, now) {
              True -> {
                let _ = ffi_delete_file(directory <> "/" <> name)
                Nil
              }
              False -> Nil
            }
          })
      }
  }
}

fn initial_state(
  events: List(UsageEvent),
  directory: Option(String),
  now: fn() -> Int,
  day_key: fn(Int) -> String,
) -> ActorState {
  // Loaded oldest first; kept newest first.
  let events = list.reverse(events)
  ActorState(
    counters: dict.new(),
    events: events,
    person_day_totals: recompute_person_day_totals(events),
    directory: directory,
    now: now,
    day_key: day_key,
    day_totals: recompute_totals(events, day_key),
    reservations: dict.new(),
    recorded_calls: recorded_call_ids(events),
  )
}

fn utc_day_key(timestamp: Int) -> String {
  pricing.day_key(timestamp, "UTC")
}

fn start_actor(
  initial_state: ActorState,
) -> Result(ResourceLedger, actor.StartError) {
  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start the resource ledger actor without persistence.
pub fn start() -> Result(ResourceLedger, actor.StartError) {
  start_actor(initial_state([], None, ffi_current_timestamp, utc_day_key))
}

/// Start the resource ledger actor, persisting the usage trail to `directory`.
///
/// On start all `<directory>/YYYY-MM-DD.jsonl` files are loaded, and files older
/// than 30 days are deleted.
pub fn start_persistent(
  directory: String,
) -> Result(ResourceLedger, actor.StartError) {
  start_persistent_with_clock(directory, ffi_current_timestamp)
}

/// Start the persistent ledger with an injectable clock (milliseconds).
pub fn start_persistent_with_clock(
  directory: String,
  now: fn() -> Int,
) -> Result(ResourceLedger, actor.StartError) {
  let _ = ffi_ensure_dir(directory)
  rotate_directory(Some(directory), now())

  start_persistent_with_clock_and_day_key(directory, now, utc_day_key)
}

/// Start the persistent ledger with an injectable clock and day-key function.
pub fn start_persistent_with_clock_and_day_key(
  directory: String,
  now: fn() -> Int,
  day_key: fn(Int) -> String,
) -> Result(ResourceLedger, actor.StartError) {
  let _ = ffi_ensure_dir(directory)
  rotate_directory(Some(directory), now())
  let events = load_events(directory)
  start_actor(initial_state(events, Some(directory), now, day_key))
}

/// Charge LLM tokens for an agent.
pub fn charge_llm(
  ledger: ResourceLedger,
  agent_id: String,
  prompt_tokens: Int,
  completion_tokens: Int,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: ChargeLLM(
    _,
    agent_id,
    prompt_tokens,
    completion_tokens,
  ))
}

/// Charge a tool call for an agent.
pub fn charge_tool(
  ledger: ResourceLedger,
  agent_id: String,
  tool_name: String,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: ChargeTool(_, agent_id, tool_name))
}

/// Charge storage operations for an agent.
pub fn charge_storage(
  ledger: ResourceLedger,
  agent_id: String,
  reads: Int,
  writes: Int,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: ChargeStorage(
    _,
    agent_id,
    reads,
    writes,
  ))
}

/// Charge CPU time for an agent.
pub fn charge_cpu(
  ledger: ResourceLedger,
  agent_id: String,
  cpu_time_ms: Int,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: ChargeCPU(_, agent_id, cpu_time_ms))
}

/// Get resource counters snapshot for an agent.
pub fn get_snapshot(
  ledger: ResourceLedger,
  agent_id: String,
) -> Result(ResourceCounters, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: GetSnapshot(_, agent_id))
}

/// Check if an agent has exceeded a quota.
pub fn check_quota(
  ledger: ResourceLedger,
  agent_id: String,
  resource: ResourceType,
  limit: Int,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: CheckQuota(
    _,
    agent_id,
    resource,
    limit,
  ))
}

/// Reset counters for an agent.
pub fn reset_counters(
  ledger: ResourceLedger,
  agent_id: String,
) -> Result(Nil, LedgerError) {
  actor.call(ledger, waiting: 1500, sending: ResetCounters(_, agent_id))
}

/// Get total token count for an agent.
pub fn get_total_tokens(ledger: ResourceLedger, agent_id: String) -> Int {
  actor.call(ledger, waiting: 1500, sending: GetTotalTokens(_, agent_id))
}

/// Get total tool calls count for an agent.
pub fn get_total_tool_calls(ledger: ResourceLedger, agent_id: String) -> Int {
  actor.call(ledger, waiting: 1500, sending: GetTotalToolCalls(_, agent_id))
}

/// Record a completed LLM call in the usage trail.
pub fn record_llm_usage(
  ledger: ResourceLedger,
  principal_id: String,
  provider: String,
  model: String,
  prompt_tokens: Int,
  completion_tokens: Int,
  cost_usd: Float,
) -> Nil {
  let _ =
    try_record_llm_usage(
      ledger,
      principal_id,
      provider,
      model,
      prompt_tokens,
      completion_tokens,
      cost_usd,
    )
  Nil
}

/// Record an LLM call, returning an error when the ledger is unavailable.
pub fn try_record_llm_usage(
  ledger: ResourceLedger,
  principal_id: String,
  provider: String,
  model: String,
  prompt_tokens: Int,
  completion_tokens: Int,
  cost_usd: Float,
) -> Result(Nil, String) {
  try_record_llm_usage_with_call_id(
    ledger,
    principal_id,
    provider,
    model,
    prompt_tokens,
    completion_tokens,
    cost_usd,
    "legacy:" <> int.to_string(unique_integer()),
  )
}

/// Record an LLM call with the id shared by admission and settlement.
pub fn try_record_llm_usage_with_call_id(
  ledger: ResourceLedger,
  principal_id: String,
  provider: String,
  model: String,
  prompt_tokens: Int,
  completion_tokens: Int,
  cost_usd: Float,
  call_id: String,
) -> Result(Nil, String) {
  case
    safe_call.call(ledger, 1500, RecordLLMUsage(
      _,
      principal_id,
      provider,
      model,
      prompt_tokens,
      completion_tokens,
      cost_usd,
      call_id,
    ))
  {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("ledger unavailable")
  }
}

/// Reserve estimated spend before an LLM call.
pub fn admit_llm_call(
  ledger: ResourceLedger,
  call_id: String,
  cap_usd: Float,
  estimate_usd: Float,
) -> Result(Nil, String) {
  case
    safe_call.call(ledger, 1500, AdmitLLMCall(_, call_id, cap_usd, estimate_usd))
  {
    Ok(Ok(Nil)) -> Ok(Nil)
    Ok(Error(reason)) -> Error(reason)
    Error(_) -> Error("ledger unavailable")
  }
}

/// Release an unrecorded reservation.
pub fn release_reservation(ledger: ResourceLedger, call_id: String) -> Nil {
  let _ = safe_call.call(ledger, 1500, ReleaseReservation(_, call_id))
  Nil
}

/// Sum of estimated spend for all open reservations.
pub fn try_get_open_reservations_total(
  ledger: ResourceLedger,
) -> Result(Float, Nil) {
  case safe_call.call(ledger, 1500, GetOpenReservationsTotal) {
    Ok(result) -> result
    Error(_) -> Error(Nil)
  }
}

/// Current day and its total LLM spend.
pub fn try_spend_today(
  ledger: ResourceLedger,
  now: Int,
) -> Result(#(String, Float), Nil) {
  case safe_call.call(ledger, 1500, GetSpendToday(_, now)) {
    Ok(result) -> Ok(result)
    Error(_) -> Error(Nil)
  }
}

/// Record a tool invocation in the usage trail.
pub fn record_tool_usage(
  ledger: ResourceLedger,
  principal_id: String,
  tool_name: String,
  ok: Bool,
) -> Nil {
  let _ = try_record_tool_usage(ledger, principal_id, tool_name, ok)
  Nil
}

/// Record a tool call, returning an error when the ledger is unavailable.
pub fn try_record_tool_usage(
  ledger: ResourceLedger,
  principal_id: String,
  tool_name: String,
  ok: Bool,
) -> Result(Nil, String) {
  case
    safe_call.call(ledger, 1500, RecordToolUsage(_, principal_id, tool_name, ok))
  {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("ledger unavailable")
  }
}

/// Get the usage trail for one principal.
pub fn get_usage(
  ledger: ResourceLedger,
  principal_id: String,
) -> List(UsageEvent) {
  case safe_call.call(ledger, 1500, GetUsage(_, principal_id)) {
    Ok(events) -> events
    Error(_) -> []
  }
}

/// Get the full usage trail with an explicit failure.
pub fn try_get_all_usage(
  ledger: ResourceLedger,
) -> Result(List(UsageEvent), Nil) {
  case safe_call.call(ledger, 1500, GetAllUsage) {
    Ok(events) -> Ok(events)
    Error(_) -> Error(Nil)
  }
}

pub fn get_all_usage(ledger: ResourceLedger) -> List(UsageEvent) {
  case safe_call.call(ledger, 1500, GetAllUsage) {
    Ok(events) -> events
    Error(_) -> []
  }
}

/// Get the total LLM cost for a UTC day.
pub fn get_daily_cost(ledger: ResourceLedger, day: String) -> Float {
  actor.call(ledger, waiting: 1500, sending: GetDailyCost(_, day))
}

/// Get the LLM cost for a UTC day for one principal.
pub fn get_daily_cost_for(
  ledger: ResourceLedger,
  day: String,
  principal_id: String,
) -> Float {
  actor.call(ledger, waiting: 1500, sending: GetDailyCostFor(
    _,
    day,
    principal_id,
  ))
}

/// Delete usage trail files older than the retention window.
pub fn rotate_old_files(ledger: ResourceLedger, now: Int) -> Nil {
  actor.call(ledger, waiting: 1500, sending: RotateOldFiles(_, now))
}

/// Stop the ledger actor.
pub fn stop(ledger: ResourceLedger) -> Nil {
  let _ = safe_call.call(ledger, 1500, Stop)
  Nil
}
