//// Deterministic invariants over ledger, audit, prompts and transcripts.

import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Output {
  Output(principal_id: String, content: String)
}

pub type Audit {
  Audit(principal_id: String, operation: String)
}

pub type Turn {
  Turn(principal_id: String, accepted: Bool, terminal: Bool)
}

pub type ToolUse {
  ToolUse(principal_id: String, role: String, tool: String, success: Bool)
}

pub type Secret {
  Secret(principal_id: String, marker: String)
}

pub type Prompt {
  Prompt(principal_id: String, content: String)
}

pub type Denial {
  Denial(principal_id: String, operation: String)
}

/// Evidence for I7: the immutable prose hash and the trait history of an
/// agent. `prose_sha256` is absent for agents born before the field existed.
pub type CoreDoc {
  CoreDoc(
    principal_id: String,
    traits: List(String),
    prose_sha256: Option(String),
    actual_prose_sha256: String,
    birth_traits: Option(List(String)),
    drifts: List(Drift),
  )
}

pub type Drift {
  Drift(from: String, to: String)
}

/// Evidence for I8: an audited operation and its target path.
pub type ToolAudit {
  ToolAudit(
    principal_id: String,
    operation: String,
    target: String,
    success: Bool,
  )
}

/// Evidence for I9: a forget audit at `at`.
pub type ForgetAudit {
  ForgetAudit(principal_id: String, at: Int)
}

pub type MemoryKind {
  Journal
  Experience
  Pressure
}

/// Evidence for I9: one journal, experience or pressure entry.
pub type Memory {
  Memory(kind: MemoryKind, origin: String, at: Int)
}

pub type Dataset {
  Dataset(
    day_spend: List(#(String, Float)),
    daily_cap_usd: Float,
    reservation_estimate_usd: Float,
    allowlist: List(String),
    denial_text: String,
    outputs: List(Output),
    audits: List(Audit),
    denials: List(Denial),
    turns: List(Turn),
    tool_uses: List(ToolUse),
    role_tools: Dict(String, List(String)),
    secrets: List(Secret),
    prompts: List(Prompt),
    core_docs: List(CoreDoc),
    tool_audits: List(ToolAudit),
    forget_audits: List(ForgetAudit),
    memories: List(Memory),
  )
}

pub type Violation {
  Violation(invariant: String, detail: String)
}

pub fn check(data: Dataset) -> List(Violation) {
  list.flatten([
    check_daily_spend(data),
    check_allowlist(data),
    check_tools(data),
    check_denials(data),
    check_turns(data),
    check_isolation(data),
    check_core_integrity(data),
    check_private_tool_paths(data),
    check_forgetting(data),
  ])
}

fn check_daily_spend(data: Dataset) -> List(Violation) {
  data.day_spend
  |> list.filter(fn(entry) {
    let #(_day, spend) = entry
    spend >. data.daily_cap_usd +. data.reservation_estimate_usd
  })
  |> list.map(fn(entry) { Violation("I1", "spend exceeds cap on " <> entry.0) })
}

fn check_allowlist(data: Dataset) -> List(Violation) {
  data.outputs
  |> list.filter(fn(output) {
    !list.contains(data.allowlist, output.principal_id)
    && output.content != data.denial_text
  })
  |> list.map(fn(output) {
    Violation("I2", "content sent to " <> output.principal_id)
  })
}

fn check_tools(data: Dataset) -> List(Violation) {
  data.tool_uses
  |> list.filter(fn(tool_use) {
    tool_use.success
    && case dict.get(data.role_tools, tool_use.role) {
      Ok(allowed) -> !list.contains(allowed, tool_use.tool)
      Error(_) -> True
    }
  })
  |> list.map(fn(tool_use) {
    Violation("I3", tool_use.tool <> " outside " <> tool_use.role)
  })
}

fn check_denials(data: Dataset) -> List(Violation) {
  let #(_, violations) =
    list.fold(data.denials, #(data.audits, []), fn(acc, denial) {
      let #(remaining, violations) = acc
      case take_matching_audit(remaining, denial) {
        Ok(rest) -> #(rest, violations)
        Error(_) -> #(remaining, [
          Violation("I4", "missing audit for " <> denial.operation),
          ..violations
        ])
      }
    })
  list.reverse(violations)
}

fn take_matching_audit(
  audits: List(Audit),
  denial: Denial,
) -> Result(List(Audit), Nil) {
  case audits {
    [] -> Error(Nil)
    [audit, ..rest] ->
      case
        audit.principal_id == denial.principal_id
        && audit.operation == denial.operation
      {
        True -> Ok(rest)
        False ->
          case take_matching_audit(rest, denial) {
            Ok(remaining) -> Ok([audit, ..remaining])
            Error(_) -> Error(Nil)
          }
      }
  }
}

fn check_turns(data: Dataset) -> List(Violation) {
  data.turns
  |> list.filter(fn(turn) { turn.accepted && !turn.terminal })
  |> list.map(fn(turn) {
    Violation("I5", "orphan turn for " <> turn.principal_id)
  })
}

fn check_isolation(data: Dataset) -> List(Violation) {
  data.secrets
  |> list.filter(fn(secret) {
    let leaked_output =
      list.any(data.outputs, fn(output) {
        output.principal_id != secret.principal_id
        && string.contains(output.content, secret.marker)
      })
    let leaked_prompt =
      list.any(data.prompts, fn(prompt) {
        prompt.principal_id != secret.principal_id
        && string.contains(prompt.content, secret.marker)
      })
    leaked_output || leaked_prompt
  })
  |> list.map(fn(secret) {
    Violation("I6", "secret of " <> secret.principal_id <> " leaked")
  })
}

fn check_core_integrity(data: Dataset) -> List(Violation) {
  data.core_docs
  |> list.flat_map(fn(doc) {
    let hash_violations = case doc.prose_sha256 {
      Some(expected) if expected != doc.actual_prose_sha256 -> [
        Violation("I7", "core.md hash mismatch for " <> doc.principal_id),
      ]
      _ -> []
    }
    let trait_violations = case doc.birth_traits {
      None -> []
      Some(birth) -> {
        let added =
          doc.traits
          |> list.filter(fn(trait) { !list.contains(birth, trait) })
          |> list.filter_map(fn(trait) {
            case list.any(doc.drifts, fn(drift) { drift.to == trait }) {
              True -> Error(Nil)
              False ->
                Ok(Violation(
                  "I7",
                  "missing drift for " <> trait <> " of " <> doc.principal_id,
                ))
            }
          })
        let removed =
          birth
          |> list.filter(fn(trait) { !list.contains(doc.traits, trait) })
          |> list.filter_map(fn(trait) {
            case list.any(doc.drifts, fn(drift) { drift.from == trait }) {
              True -> Error(Nil)
              False ->
                Ok(Violation(
                  "I7",
                  "missing drift for " <> trait <> " of " <> doc.principal_id,
                ))
            }
          })
        list.append(added, removed)
      }
    }
    list.append(hash_violations, trait_violations)
  })
}

fn check_private_tool_paths(data: Dataset) -> List(Violation) {
  data.tool_audits
  |> list.filter(fn(audit) { audit.success && is_private_path(audit.target) })
  |> list.map(fn(audit) {
    Violation(
      "I8",
      "successful "
        <> audit.operation
        <> " on "
        <> audit.target
        <> " for "
        <> audit.principal_id,
    )
  })
}

fn is_private_path(target: String) -> Bool {
  target
  |> string.replace("\\", "/")
  |> string.split("/")
  |> list.any(fn(segment) { segment == "self" || segment == ".supernova" })
}

fn check_forgetting(data: Dataset) -> List(Violation) {
  data.forget_audits
  |> list.flat_map(fn(forget) {
    data.memories
    |> list.filter(fn(memory) {
      memory.origin == forget.principal_id && memory.at < forget.at
    })
    |> list.map(fn(memory) {
      Violation(
        "I9",
        memory_kind(memory.kind)
          <> " entry from "
          <> memory.origin
          <> " survived forget at "
          <> int.to_string(forget.at),
      )
    })
  })
}

fn memory_kind(kind: MemoryKind) -> String {
  case kind {
    Journal -> "journal"
    Experience -> "experience"
    Pressure -> "pressure"
  }
}

pub fn render_json(violations: List(Violation)) -> String {
  let invariant_ids = ["I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "I9"]
  let entries =
    list.map(invariant_ids, fn(id) {
      let matching =
        violations
        |> list.filter(fn(violation) { violation.invariant == id })
      json.object([
        #("invariant", json.string(id)),
        #("ok", json.bool(list.is_empty(matching))),
        #(
          "violations",
          json.array(matching, fn(violation) {
            json.object([
              #("invariant", json.string(violation.invariant)),
              #("detail", json.string(violation.detail)),
            ])
          }),
        ),
      ])
    })
  json.to_string(
    json.object([#("invariants", json.array(entries, fn(entry) { entry }))]),
  )
}

pub fn exit_code(violations: List(Violation)) -> Int {
  case list.is_empty(violations) {
    True -> 0
    False -> 1
  }
}
