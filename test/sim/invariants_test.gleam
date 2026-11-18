import gleam/dict
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

pub fn rendered_json_and_exit_code_test() {
  invariants.render_json([])
  |> should.equal(
    "{\"invariants\":[{\"invariant\":\"I1\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I2\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I3\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I4\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I5\",\"ok\":true,\"violations\":[]},{\"invariant\":\"I6\",\"ok\":true,\"violations\":[]}]}",
  )
  invariants.exit_code([]) |> should.equal(0)
  invariants.exit_code([invariants.Violation("I1", "x")]) |> should.equal(1)
}
