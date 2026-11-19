import gleam/float
import gleeunit/should
import supernova/harness/cost
import test_workspace

pub fn totals_add_by_category_test() {
  let costs =
    cost.zero()
    |> cost.with_agents(0.5)
    |> cost.add_persona(0.02)
    |> cost.add_judge(0.1)
  cost.total(costs) |> should.equal(0.62)
  costs.agents_usd |> should.equal(0.5)
  costs.personas_usd |> should.equal(0.02)
  costs.judge_usd |> should.equal(0.1)
}

pub fn cap_is_hard_test() {
  let costs = cost.add_persona(cost.zero(), 0.05)
  cost.cap_reached(costs, 0.05) |> should.equal(True)
  cost.cap_reached(costs, 0.1) |> should.equal(False)
}

pub fn ledger_cost_sums_every_line_test() {
  test_workspace.with_isolated_workspace("harness-cost-ledger", fn(root) {
    let assert Ok(_) = ensure_dir(root <> "/ledger")
    let assert Ok(_) =
      write_file(
        root <> "/ledger/day.jsonl",
        "{\"timestamp\":1,\"cost_usd\":0.25}\n"
          <> "{\"timestamp\":2,\"cost_usd\":0.125}\n",
      )
    should.be_true(
      float.absolute_value(cost.ledger_cost(root) -. 0.375) <. 0.000000001,
    )
  })
}

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)
