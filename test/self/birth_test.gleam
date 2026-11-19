import envoy
import exception
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/self/birth
import supernova/self/core
import supernova/self/sampler
import test_workspace

pub fn main() -> Nil {
  gleeunit.main()
}

fn with_constellation(body: fn(String) -> a) -> a {
  let previous = envoy.get("SUPERNOVA_CONSTELLATION_PATH")
  use <- exception.defer(fn() {
    case previous {
      Ok(value) -> envoy.set("SUPERNOVA_CONSTELLATION_PATH", value)
      Error(_) -> envoy.unset("SUPERNOVA_CONSTELLATION_PATH")
    }
  })
  envoy.set(
    "SUPERNOVA_CONSTELLATION_PATH",
    "test/fixtures/constellation_small.json",
  )
  test_workspace.with_isolated_workspace("birth", fn(root) { body(root) })
}

pub fn birth_writes_self_and_accepts_name_test() {
  with_constellation(fn(root) {
    let step =
      birth.step(root, "sim:a", "oi", 1000, fn(_) {
        Ok("Eu observo antes de falar.")
      })
    case step {
      birth.AskName(text) ->
        string.contains(text, "Que nome você quer me dar?") |> should.be_true()
      _ -> should.fail()
    }
    let assert Some(loaded) = core.load(root, "sim:a")
    loaded.name |> should.equal(None)
    let assert Some(prose) = core.read_prose(root, "sim:a")
    prose |> should.equal("Eu observo antes de falar.")

    birth.step(root, "sim:a", "Lua", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Lua"))
    let named = birth.step(root, "sim:a", "sim", 3000, fn(_) { Ok("") })
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

pub fn malformed_core_is_not_overwritten_test() {
  with_constellation(fn(root) {
    let sampled = sampler.Sampled(traits: ["temp_0"], seed: 1, attempts: 0)
    let assert Ok(_) =
      core.save_birth(root, "sim:a", sampled, 1, "Eu sou.", 1000)
    let path = core.core_path(root, "sim:a")
    let assert Ok(_) = write_file(path, "{malformed")
    birth.step(root, "sim:a", "oi", 2000, fn(_) { Ok("novo") })
    |> should.equal(birth.BirthFailed)
    let assert Ok(after) = read_file(path)
    after |> should.equal("{malformed")
  })
}

pub fn invalid_name_asks_again_test() {
  with_constellation(fn(root) {
    let _ = birth.step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    birth.step(root, "sim:a", "////", 2000, fn(_) { Ok("") })
    |> should.equal(birth.NameRejected(
      "Não entendi qual nome você quer me dar. Me diga só o nome.",
    ))
    let assert Some(loaded) = core.load(root, "sim:a")
    loaded.name |> should.equal(None)
  })
}

pub fn affirmation_words_are_recognized_test() {
  [
    "sim", "s", "isso", "isso mesmo", "pode", "pode ser", "exato", "claro", "ok",
    "é", "é sim", "sim sim", "perfeito", "beleza", "👍",
  ]
  |> list.each(fn(word) {
    [word, string.uppercase(word), "  " <> word <> ".", word <> "!"]
    |> list.each(fn(candidate) {
      birth.is_affirmation(candidate) |> should.be_true()
    })
  })
  birth.is_affirmation("sim, mas prefiro Ana") |> should.be_false()
  birth.is_affirmation("não") |> should.be_false()
}

pub fn negation_words_are_recognized_test() {
  ["não", "nao", "n", "não é", "outro", "nope"]
  |> list.each(fn(word) {
    [word, string.uppercase(word), "  " <> word <> ".", word <> "!"]
    |> list.each(fn(candidate) {
      birth.is_negation(candidate) |> should.be_true()
    })
  })
  birth.is_negation("não, quero Bia") |> should.be_false()
  birth.is_negation("sim") |> should.be_false()
}

pub fn name_is_confirmed_before_saving_test() {
  with_constellation(fn(root) {
    let _ = birth.step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    birth.step(root, "sim:a", "Bia", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Bia"))
    let assert Ok(pending) = read_file(birth.name_pending_path(root, "sim:a"))
    string.contains(pending, "\"candidate\":\"Bia\"") |> should.be_true()
    let assert Some(unnamed) = core.load(root, "sim:a")
    unnamed.name |> should.equal(None)

    birth.step(root, "sim:a", "Sim!", 3000, fn(_) { Ok("") })
    |> should.equal(birth.NameAccepted("Bia"))
    let assert Some(named) = core.load(root, "sim:a")
    named.name |> should.equal(Some("Bia"))
    read_file(birth.name_pending_path(root, "sim:a")) |> should.be_error()
    let assert Ok(biography) = read_file(core.biography_path(root, "sim:a"))
    string.contains(biography, "\"kind\":\"name\"") |> should.be_true()
    string.contains(biography, "\"name\":\"Bia\"") |> should.be_true()
  })
}

pub fn refused_name_is_not_saved_test() {
  with_constellation(fn(root) {
    let _ = birth.step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    birth.step(root, "sim:a", "Bia", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Bia"))
    birth.step(root, "sim:a", "não", 3000, fn(_) { Ok("") })
    |> should.equal(birth.NameRejected("Tudo bem. Que nome você quer me dar?"))
    let assert Some(loaded) = core.load(root, "sim:a")
    loaded.name |> should.equal(None)
    read_file(birth.name_pending_path(root, "sim:a")) |> should.be_error()
    let assert Ok(biography) = read_file(core.biography_path(root, "sim:a"))
    string.contains(biography, "\"kind\":\"name\"") |> should.be_false()

    birth.step(root, "sim:a", "Luna", 4000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Luna"))
  })
}

pub fn expired_pending_is_ignored_test() {
  with_constellation(fn(root) {
    let _ = birth.step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    birth.step(root, "sim:a", "Bia", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Bia"))
    birth.step(root, "sim:a", "Luna", 2000 + 600_001, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Luna"))
    let assert Ok(pending) = read_file(birth.name_pending_path(root, "sim:a"))
    string.contains(pending, "\"candidate\":\"Luna\"") |> should.be_true()
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

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_test_file(path: String, content: String) -> Result(Nil, String)

fn with_birth_prompt(path: String, body: fn() -> a) -> a {
  let previous = envoy.get("SUPERNOVA_BIRTH_PROMPT_PATH")
  use <- exception.defer(fn() {
    case previous {
      Ok(value) -> envoy.set("SUPERNOVA_BIRTH_PROMPT_PATH", value)
      Error(_) -> envoy.unset("SUPERNOVA_BIRTH_PROMPT_PATH")
    }
  })
  envoy.set("SUPERNOVA_BIRTH_PROMPT_PATH", path)
  body()
}

// The generator echoes the prompt as the prose, so core.md shows what the
// model received.
pub fn birth_prompt_fills_traits_placeholder_test() {
  with_constellation(fn(root) {
    let template = root <> "/birth_prompt.md"
    let assert Ok(_) =
      write_test_file(template, "Antes.\n\n{{traits}}\n\nResponda apenas.")
    with_birth_prompt(template, fn() {
      let _ = birth.step(root, "sim:p", "oi", 1000, fn(prompt) { Ok(prompt) })
      let assert Some(prompt) = core.read_prose(root, "sim:p")
      string.contains(prompt, "{{traits}}") |> should.be_false()
      string.starts_with(prompt, "Antes.\n\n- ") |> should.be_true()
      string.ends_with(prompt, "\n\nResponda apenas.") |> should.be_true()
      string.contains(prompt, "Traços sorteados") |> should.be_false()
    })
  })
}

pub fn birth_without_prompt_file_is_unavailable_test() {
  with_constellation(fn(root) {
    with_birth_prompt(root <> "/missing_birth_prompt.md", fn() {
      birth.step(root, "sim:q", "oi", 1000, fn(_) { Ok("nunca") })
      |> should.equal(birth.Unavailable)
      core.exists(root, "sim:q") |> should.be_false()
    })
  })
}
