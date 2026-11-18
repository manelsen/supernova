import envoy
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/self/birth
import supernova/self/core
import supernova/self/sampler
import test_workspace

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

pub fn main() -> Nil {
  gleeunit.main()
}

fn with_constellation(body: fn(String) -> a) -> a {
  let previous = envoy.get("SUPERNOVA_CONSTELLATION_PATH")
  envoy.set(
    "SUPERNOVA_CONSTELLATION_PATH",
    "test/fixtures/constellation_small.json",
  )
  let root = "/tmp/supernova_birth_test_" <> int_to_string(unique_integer())
  let result =
    test_workspace.with_isolated_workspace("birth", fn(_) { body(root) })
  case previous {
    Ok(value) -> envoy.set("SUPERNOVA_CONSTELLATION_PATH", value)
    Error(_) -> envoy.unset("SUPERNOVA_CONSTELLATION_PATH")
  }
  result
}

pub fn birth_writes_self_and_accepts_name_test() {
  with_constellation(fn(root) {
    let step =
      birth.step(root, "sim:a", "oi", 1000, fn(_) {
        Ok("Eu observo antes de falar.")
      })
    case step {
      birth.AskName(text) ->
        string.contains(text, "Como você quer me chamar?") |> should.be_true()
      _ -> should.fail()
    }
    let assert Some(loaded) = core.load(root, "sim:a")
    loaded.name |> should.equal(None)
    let assert Some(prose) = core.read_prose(root, "sim:a")
    prose |> should.equal("Eu observo antes de falar.")

    let named = birth.step(root, "sim:a", "Lua", 2000, fn(_) { Ok("") })
    named |> should.equal(birth.NameAccepted("Lua"))
    let assert Some(named_core) = core.load(root, "sim:a")
    named_core.name |> should.equal(Some("Lua"))
    named_core.version |> should.equal(1)
    named_core.constellation_version |> should.equal(1)
    named_core.traits |> list.length |> should.equal(7)
    let assert Ok(biography) = read_file(core.biography_path(root, "sim:a"))
    string.contains(biography, "\"kind\":\"birth\"")
    |> should.be_true()

    birth.step(root, "sim:a", "oi de novo", 3000, fn(_) { Ok("") })
    |> should.equal(birth.AlreadyBorn)
  })
}

pub fn failed_birth_writes_nothing_test() {
  with_constellation(fn(root) {
    birth.step(root, "sim:a", "oi", 1000, fn(_) { Error("no llm") })
    |> should.equal(birth.BirthFailed)
    core.load(root, "sim:a") |> should.equal(None)
  })
}

pub fn invalid_name_asks_again_test() {
  with_constellation(fn(root) {
    let _ = birth.step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    birth.step(root, "sim:a", "////", 2000, fn(_) { Ok("") })
    |> should.equal(birth.AskName(birth.question()))
    let assert Some(loaded) = core.load(root, "sim:a")
    loaded.name |> should.equal(None)
  })
}

pub fn two_agents_respect_min_distance_test() {
  with_constellation(fn(root) {
    let _ = birth.step(root, "sim:a", "oi", 1000, fn(_) { Ok("A.") })
    let _ = birth.step(root, "sim:b", "oi", 1000, fn(_) { Ok("B.") })
    let assert Some(a) = core.load(root, "sim:a")
    let assert Some(b) = core.load(root, "sim:b")
    { sampler.jaccard_distance(a.traits, b.traits) >=. 0.4 }
    |> should.be_true()
  })
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}
