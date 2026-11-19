import gleam/int
import gleam/list
import gleeunit/should
import supernova/self/memory

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

fn base() -> String {
  "/tmp/supernova-memory-" <> int.to_string(now_ms())
}

pub fn experiences_keep_order_and_recent_is_bounded_test() {
  let dir = base()
  let assert Ok(Nil) =
    memory.append_experiences(dir, "telegram:1", [
      memory.Experience(at: 1, origin: "telegram:1", text: "um"),
      memory.Experience(at: 2, origin: "telegram:1", text: "dois"),
    ])
  memory.recent_experiences(dir, "telegram:1", 1)
  |> list.map(fn(item) { item.text })
  |> should.equal(["dois"])
}

pub fn pressures_replace_and_filter_origin_test() {
  let dir = base()
  let pressure =
    memory.Pressure(
      at: 1,
      origin: "telegram:1",
      from: "curiosa",
      to: "cauta",
      strength: 0.8,
      reason: "promessa quebrada",
    )
  let other =
    memory.Pressure(
      at: 2,
      origin: "telegram:2",
      from: "curiosa",
      to: "cauta",
      strength: 0.3,
      reason: "outra",
    )
  let assert Ok(Nil) =
    memory.append_pressures(dir, "telegram:1", [pressure, other])
  let #(kept, removed) =
    memory.without_origin_pressures(dir, "telegram:1", "telegram:2")
  removed |> should.equal(1)
  let assert Ok(Nil) = memory.replace_pressures(dir, "telegram:1", kept)
  memory.pressures(dir, "telegram:1")
  |> list.map(fn(item) { item.origin })
  |> should.equal(["telegram:1"])
}

pub fn addendum_appends_test() {
  let dir = base()
  let assert Ok(Nil) = memory.append_addendum(dir, "telegram:1", "Primeira.")
  let assert Ok(Nil) = memory.append_addendum(dir, "telegram:1", "Segunda.")
  let text = memory.addenda(dir, "telegram:1")
  text |> should.equal("\n\nPrimeira.\n\n\nSegunda.\n")
}
