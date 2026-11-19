//// Small audit helper shared by reflection and forgetting.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types as audit_types
import supernova/core/closed_group/global as closed_group_global

pub fn record(
  principal: String,
  operation: String,
  target: String,
  result: audit_types.AuditResult,
  details: String,
) -> Nil {
  case closed_group_global.get_audit() {
    Some(log) ->
      audit_actor.log_entry(
        log,
        audit_types.AuditEntry(
          timestamp: closed_group_global.now(),
          agent_id: principal,
          operation: operation,
          target: target,
          result: result,
          details: details,
        ),
      )
    None -> Nil
  }
}

pub fn counts(pairs: List(#(String, Int))) -> String {
  pairs
  |> list.map(fn(pair) {
    let #(name, value) = pair
    name <> "=" <> int.to_string(value)
  })
  |> string.join(",")
}
