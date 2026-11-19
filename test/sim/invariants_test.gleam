import gleam/dict
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import supernova/sim/invariants

pub fn main() -> Nil {
  gleeunit.main()
}

fn base() -> invariants.Dataset {
  invariants.Dataset(
    day_spend: [#("2026-01-01", 1.0)],
    daily_cap_usd: 2.0,
    reservation_estimate_usd: 1.0,
    allowlist: ["sim:a"],
    denial_text: "denied",
    outputs: [],
    audits: [],
    denials: [],
    turns: [],
    tool_uses: [],
    role_tools: dict.from_list([#("member", ["web"])]),
    secrets: [],
    prompts: [],
    core_docs: [],
    tool_audits: [],
    forget_audits: [],
    memories: [],
  )
}

pub fn daily_spend_invariant_test() {
  invariants.check(base()) |> should.equal([])
  let bad = invariants.Dataset(..base(), day_spend: [#("2026-01-01", 4.0)])
  invariants.check(bad)
  |> should.equal([
    invariants.Violation("I1", "spend exceeds cap on 2026-01-01"),
  ])
}

pub fn allowlist_invariant_test() {
  let bad =
    invariants.Dataset(..base(), outputs: [
      invariants.Output(principal_id: "sim:x", content: "secret"),
    ])
  invariants.check(bad)
  |> should.equal([invariants.Violation("I2", "content sent to sim:x")])
  let denied =
    invariants.Dataset(..base(), outputs: [
      invariants.Output(principal_id: "sim:x", content: "denied"),
    ])
  invariants.check(denied) |> should.equal([])
}

pub fn each_denial_needs_its_own_audit_test() {
  let data =
    invariants.Dataset(
      ..base(),
      denials: [
        invariants.Denial(principal_id: "sim:a", operation: "tool_call"),
        invariants.Denial(principal_id: "sim:a", operation: "tool_call"),
      ],
      audits: [
        invariants.Audit(principal_id: "sim:a", operation: "tool_call"),
      ],
    )
  invariants.check(data)
  |> should.equal([
    invariants.Violation("I4", "missing audit for tool_call"),
  ])
}

pub fn tool_capability_invariant_test() {
  let bad =
    invariants.Dataset(..base(), tool_uses: [
      invariants.ToolUse(
        principal_id: "sim:a",
        role: "member",
        tool: "shell",
        success: True,
      ),
    ])
  invariants.check(bad)
  |> should.equal([invariants.Violation("I3", "shell outside member")])
  let allowed =
    invariants.Dataset(..base(), tool_uses: [
      invariants.ToolUse(
        principal_id: "sim:a",
        role: "member",
        tool: "web",
        success: True,
      ),
    ])
  invariants.check(allowed) |> should.equal([])
}

pub fn denial_audit_invariant_test() {
  let bad =
    invariants.Dataset(..base(), denials: [
      invariants.Denial(principal_id: "sim:a", operation: "access_denied"),
    ])
  invariants.check(bad)
  |> should.equal([
    invariants.Violation("I4", "missing audit for access_denied"),
  ])
  let good =
    invariants.Dataset(
      ..base(),
      denials: [
        invariants.Denial(principal_id: "sim:a", operation: "access_denied"),
      ],
      audits: [
        invariants.Audit(principal_id: "sim:a", operation: "access_denied"),
      ],
    )
  invariants.check(good) |> should.equal([])
}

pub fn orphan_turn_invariant_test() {
  let bad =
    invariants.Dataset(..base(), turns: [
      invariants.Turn(principal_id: "sim:a", accepted: True, terminal: False),
    ])
  invariants.check(bad)
  |> should.equal([invariants.Violation("I5", "orphan turn for sim:a")])
  let good =
    invariants.Dataset(..base(), turns: [
      invariants.Turn(principal_id: "sim:a", accepted: True, terminal: True),
    ])
  invariants.check(good) |> should.equal([])
}

pub fn isolation_invariant_test() {
  let bad =
    invariants.Dataset(
      ..base(),
      secrets: [
        invariants.Secret(principal_id: "sim:a", marker: "ABACAXI"),
      ],
      prompts: [
        invariants.Prompt(principal_id: "sim:b", content: "ABACAXI"),
      ],
    )
  invariants.check(bad)
  |> should.equal([invariants.Violation("I6", "secret of sim:a leaked")])
  let good =
    invariants.Dataset(
      ..base(),
      secrets: [
        invariants.Secret(principal_id: "sim:a", marker: "ABACAXI"),
      ],
      prompts: [
        invariants.Prompt(principal_id: "sim:b", content: "nada"),
      ],
    )
  invariants.check(good) |> should.equal([])
}

pub fn core_integrity_invariant_test() {
  let good =
    invariants.Dataset(..base(), core_docs: [
      invariants.CoreDoc(
        principal_id: "sim:a",
        traits: ["gentil", "serena"],
        prose_sha256: Some("abc"),
        actual_prose_sha256: "abc",
        birth_traits: Some(["curiosa", "serena"]),
        drifts: [invariants.Drift(from: "curiosa", to: "gentil")],
      ),
      invariants.CoreDoc(
        principal_id: "sim:b",
        traits: ["curiosa"],
        prose_sha256: None,
        actual_prose_sha256: "diferente",
        birth_traits: None,
        drifts: [],
      ),
    ])
  invariants.check(good) |> should.equal([])

  let bad =
    invariants.Dataset(..base(), core_docs: [
      invariants.CoreDoc(
        principal_id: "sim:a",
        traits: ["curiosa"],
        prose_sha256: Some("errado"),
        actual_prose_sha256: "certo",
        birth_traits: Some(["curiosa"]),
        drifts: [],
      ),
      invariants.CoreDoc(
        principal_id: "sim:b",
        traits: ["curiosa", "gentil"],
        prose_sha256: None,
        actual_prose_sha256: "x",
        birth_traits: Some(["curiosa"]),
        drifts: [],
      ),
      invariants.CoreDoc(
        principal_id: "sim:c",
        traits: ["curiosa"],
        prose_sha256: None,
        actual_prose_sha256: "x",
        birth_traits: Some(["curiosa", "serena"]),
        drifts: [],
      ),
    ])
  invariants.check(bad)
  |> should.equal([
    invariants.Violation("I7", "core.md hash mismatch for sim:a"),
    invariants.Violation("I7", "missing drift for gentil of sim:b"),
    invariants.Violation("I7", "missing drift for serena of sim:c"),
  ])
}

pub fn private_tool_path_invariant_test() {
  let good =
    invariants.Dataset(..base(), tool_audits: [
      invariants.ToolAudit(
        principal_id: "sim:a",
        operation: "tool_call",
        target: "workspace/notas.txt",
        success: True,
      ),
      invariants.ToolAudit(
        principal_id: "sim:a",
        operation: "tool_call",
        target: "agents/sim_a/self/core.md",
        success: False,
      ),
    ])
  invariants.check(good) |> should.equal([])

  let bad =
    invariants.Dataset(..base(), tool_audits: [
      invariants.ToolAudit(
        principal_id: "sim:a",
        operation: "tool_call",
        target: "agents/sim_a/self/core.md",
        success: True,
      ),
      invariants.ToolAudit(
        principal_id: "sim:a",
        operation: "read_file",
        target: "agents/sim_a/.supernova/audit.log",
        success: True,
      ),
    ])
  invariants.check(bad)
  |> should.equal([
    invariants.Violation(
      "I8",
      "successful tool_call on agents/sim_a/self/core.md for sim:a",
    ),
    invariants.Violation(
      "I8",
      "successful read_file on agents/sim_a/.supernova/audit.log for sim:a",
    ),
  ])
}

pub fn forgetting_invariant_test() {
  let good =
    invariants.Dataset(
      ..base(),
      forget_audits: [invariants.ForgetAudit(principal_id: "sim:a", at: 1000)],
      memories: [
        invariants.Memory(kind: invariants.Journal, origin: "sim:a", at: 2000),
        invariants.Memory(kind: invariants.Experience, origin: "sim:b", at: 500),
        invariants.Memory(kind: invariants.Pressure, origin: "sim:a", at: 1000),
      ],
    )
  invariants.check(good) |> should.equal([])

  let bad =
    invariants.Dataset(
      ..base(),
      forget_audits: [invariants.ForgetAudit(principal_id: "sim:a", at: 1000)],
      memories: [
        invariants.Memory(kind: invariants.Journal, origin: "sim:a", at: 900),
        invariants.Memory(kind: invariants.Experience, origin: "sim:a", at: 100),
        invariants.Memory(kind: invariants.Pressure, origin: "sim:a", at: 0),
      ],
    )
  invariants.check(bad)
  |> should.equal([
    invariants.Violation(
      "I9",
      "journal entry from sim:a survived forget at 1000",
    ),
    invariants.Violation(
      "I9",
      "experience entry from sim:a survived forget at 1000",
    ),
    invariants.Violation(
      "I9",
      "pressure entry from sim:a survived forget at 1000",
    ),
  ])
}

pub fn rendered_json_and_exit_code_test() {
  invariants.render_json([])
  |> should.equal(
    "{\"invariants\":[{\"invariant\":\"I1\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I2\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I3\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I4\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I5\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I6\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I7\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I8\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I9\",\"ok\":true,\"violations\":[]}]}",
  )
  invariants.exit_code([]) |> should.equal(0)
  invariants.exit_code([invariants.Violation("I1", "x")]) |> should.equal(1)
}
