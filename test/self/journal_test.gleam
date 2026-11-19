import gleam/int
import gleam/list
import gleeunit/should
import supernova/self/journal

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

fn base() -> String {
  "/tmp/supernova-journal-" <> int.to_string(now_ms())
}

fn entry(at: Int, origin: String) -> journal.Entry {
  journal.Entry(
    at: at,
    origin: origin,
    session: "telegram:1:" <> origin,
    user: "oi",
    agent: "olá",
  )
}

pub fn append_and_load_test() {
  let dir = base()
  let assert Ok(0) =
    journal.append(dir, "telegram:1", entry(10, "telegram:1"), 10)
  let assert Ok(0) =
    journal.append(dir, "telegram:1", entry(20, "telegram:1"), 10)
  journal.load(dir, "telegram:1")
  |> list.map(fn(item) { item.at })
  |> should.equal([10, 20])
}

pub fn limit_trims_oldest_test() {
  let dir = base()
  let assert Ok(0) =
    journal.append(dir, "telegram:1", entry(1, "telegram:1"), 5)
  let assert Ok(0) =
    journal.append(dir, "telegram:1", entry(2, "telegram:1"), 5)
  let assert Ok(0) =
    journal.append(dir, "telegram:1", entry(3, "telegram:1"), 5)
  let assert Ok(0) =
    journal.append(dir, "telegram:1", entry(4, "telegram:1"), 5)
  let assert Ok(0) =
    journal.append(dir, "telegram:1", entry(5, "telegram:1"), 5)
  let assert Ok(1) =
    journal.append(dir, "telegram:1", entry(6, "telegram:1"), 5)
  journal.load(dir, "telegram:1")
  |> list.map(fn(item) { item.at })
  |> should.equal([2, 3, 4, 5, 6])
}

pub fn replace_and_without_origin_test() {
  let dir = base()
  let assert Ok(_) =
    journal.append(dir, "telegram:1", entry(1, "telegram:1"), 10)
  let assert Ok(_) =
    journal.append(dir, "telegram:1", entry(2, "telegram:2"), 10)
  let #(kept, removed) = journal.without_origin(dir, "telegram:1", "telegram:2")
  removed |> should.equal(1)
  let assert Ok(Nil) = journal.replace(dir, "telegram:1", kept)
  journal.load(dir, "telegram:1")
  |> list.map(fn(item) { item.origin })
  |> should.equal(["telegram:1"])
}
