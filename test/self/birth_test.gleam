import envoy
import exception
import gleam/erlang/process
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
    let first =
      step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu observo antes de falar.") })
    case first {
      birth.AskName(text) ->
        string.contains(text, "Que nome você quer me dar?") |> should.be_true()
      _ -> should.fail()
    }
    let assert Some(loaded) = core.load(root, "sim:a")
    loaded.name |> should.equal(None)
    let assert Some(prose) = core.read_prose(root, "sim:a")
    prose |> should.equal("Eu observo antes de falar.")

    step(root, "sim:a", "Lua", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Lua"))
    let named = step(root, "sim:a", "sim", 3000, fn(_) { Ok("") })
    named |> should.equal(birth.NameAccepted("Lua"))
    let assert Some(named_core) = core.load(root, "sim:a")
    named_core.name |> should.equal(Some("Lua"))
    named_core.version |> should.equal(1)
    named_core.constellation_version |> should.equal(1)
    named_core.traits |> list.length |> should.equal(7)
    let assert Ok(biography) = read_file(core.biography_path(root, "sim:a"))
    string.contains(biography, "\"kind\":\"birth\"")
    |> should.be_true()

    step(root, "sim:a", "oi de novo", 3000, fn(_) { Ok("") })
    |> should.equal(birth.AlreadyBorn)
  })
}

pub fn failed_birth_writes_nothing_test() {
  with_constellation(fn(root) {
    step(root, "sim:a", "oi", 1000, fn(_) { Error("no llm") })
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
    step(root, "sim:a", "oi", 2000, fn(_) { Ok("novo") })
    |> should.equal(birth.BirthFailed)
    let assert Ok(after) = read_file(path)
    after |> should.equal("{malformed")
  })
}

pub fn invalid_name_asks_again_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    step(root, "sim:a", "////", 2000, fn(_) { Ok("") })
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
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    step(root, "sim:a", "Bia", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Bia"))
    let assert Ok(pending) = read_file(birth.name_pending_path(root, "sim:a"))
    string.contains(pending, "\"candidate\":\"Bia\"") |> should.be_true()
    let assert Some(unnamed) = core.load(root, "sim:a")
    unnamed.name |> should.equal(None)

    step(root, "sim:a", "Sim!", 3000, fn(_) { Ok("") })
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
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    step(root, "sim:a", "Bia", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Bia"))
    step(root, "sim:a", "não", 3000, fn(_) { Ok("") })
    |> should.equal(birth.NameRejected("Tudo bem. Que nome você quer me dar?"))
    let assert Some(loaded) = core.load(root, "sim:a")
    loaded.name |> should.equal(None)
    read_file(birth.name_pending_path(root, "sim:a")) |> should.be_error()
    let assert Ok(biography) = read_file(core.biography_path(root, "sim:a"))
    string.contains(biography, "\"kind\":\"name\"") |> should.be_false()

    step(root, "sim:a", "Luna", 4000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Luna"))
  })
}

pub fn expired_pending_is_ignored_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    step(root, "sim:a", "Bia", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Bia"))
    step(root, "sim:a", "Luna", 2000 + 600_001, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Luna"))
    let assert Ok(pending) = read_file(birth.name_pending_path(root, "sim:a"))
    string.contains(pending, "\"candidate\":\"Luna\"") |> should.be_true()
  })
}

pub fn model_extracts_name_from_a_natural_reply_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    let reply =
      "Bia. A não ser que você prefira outro nome — nesse caso, diga qual e por quê."
    birth.step(root, "sim:a", reply, 2000, fn(_) { Ok("") }, fn(prompt) {
      string.contains(prompt, reply) |> should.be_true()
      string.contains(prompt, "Qual nome a pessoa quer dar à agente?")
      |> should.be_true()
      Ok("{\"name\": \"Bia\"}")
    })
    |> should.equal(birth.ConfirmName("Bia"))
  })
}

pub fn model_without_a_name_rejects_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    birth.step(
      root,
      "sim:a",
      "não sei [mock-name-none]",
      2000,
      fn(_) { Ok("") },
      fn(_) { Ok("{\"name\": null}") },
    )
    |> should.equal(birth.NameRejected(birth.rejected_message()))
    let assert Some(loaded) = core.load(root, "sim:a")
    loaded.name |> should.equal(None)
    read_file(birth.name_pending_path(root, "sim:a")) |> should.be_error()
  })
}

pub fn invalid_model_json_rejects_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    birth.step(root, "sim:a", "pode ser Luna", 2000, fn(_) { Ok("") }, fn(_) {
      Ok("não é json")
    })
    |> should.equal(birth.NameRejected(birth.rejected_message()))
  })
}

pub fn invalid_model_name_rejects_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    let long_name = string.repeat("a", 60)
    birth.step(
      root,
      "sim:a",
      "pode ser esse nome enorme",
      2000,
      fn(_) { Ok("") },
      fn(_) { Ok("{\"name\": \"" <> long_name <> "\"}") },
    )
    |> should.equal(birth.NameRejected(birth.rejected_message()))
  })
}

pub fn single_word_does_not_call_the_model_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    birth.step(root, "sim:a", "Bia", 2000, fn(_) { Ok("") }, fn(_) {
      Error("the model must not be called")
    })
    |> should.equal(birth.ConfirmName("Bia"))
  })
}

pub fn denied_extraction_rejects_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    birth.step(root, "sim:a", "pode ser Luna", 2000, fn(_) { Ok("") }, fn(_) {
      Error("ledger denied")
    })
    |> should.equal(birth.NameRejected(birth.rejected_message()))
    let assert Some(loaded) = core.load(root, "sim:a")
    loaded.name |> should.equal(None)
    read_file(birth.name_pending_path(root, "sim:a")) |> should.be_error()
  })
}

pub fn missing_name_prompt_rejects_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    with_name_prompt(root <> "/missing_name_prompt.md", fn() {
      birth.step(root, "sim:a", "pode ser Luna", 2000, fn(_) { Ok("") }, fn(_) {
        Ok("{\"name\": \"Luna\"}")
      })
      |> should.equal(birth.NameRejected(birth.rejected_message()))
    })
    let assert Some(loaded) = core.load(root, "sim:a")
    loaded.name |> should.equal(None)
  })
}

pub fn two_agents_respect_min_distance_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("A.") })
    let _ = step(root, "sim:b", "oi", 1000, fn(_) { Ok("B.") })
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

fn with_name_prompt(path: String, body: fn() -> a) -> a {
  let previous = envoy.get("SUPERNOVA_NAME_PROMPT_PATH")
  use <- exception.defer(fn() {
    case previous {
      Ok(value) -> envoy.set("SUPERNOVA_NAME_PROMPT_PATH", value)
      Error(_) -> envoy.unset("SUPERNOVA_NAME_PROMPT_PATH")
    }
  })
  envoy.set("SUPERNOVA_NAME_PROMPT_PATH", path)
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
      let _ = step(root, "sim:p", "oi", 1000, fn(prompt) { Ok(prompt) })
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
      step(root, "sim:q", "oi", 1000, fn(_) { Ok("nunca") })
      |> should.equal(birth.Unavailable)
      core.exists(root, "sim:q") |> should.be_false()
    })
  })
}

fn step(
  root: String,
  principal: String,
  content: String,
  now: Int,
  generate: fn(String) -> Result(String, String),
) -> birth.Step {
  birth.step(root, principal, content, now, generate, fn(_) { Ok("") })
}

// Regressions from the first real battery: free replies to the confirmation
// looped forever ("Sim, Vera. Fechado." asked again and again).
fn named_extract(name: String) -> fn(String) -> Result(String, String) {
  fn(_) { Ok("{\"name\": \"" <> name <> "\"}") }
}

fn no_name_extract(_prompt: String) -> Result(String, String) {
  Ok("{\"name\": null}")
}

pub fn confirmation_in_a_sentence_with_the_same_name_is_accepted_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    step(root, "sim:a", "Vera", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Vera"))
    birth.step(
      root,
      "sim:a",
      "Sim, Vera. Fechado.",
      3000,
      fn(_) { Ok("") },
      named_extract("Vera"),
    )
    |> should.equal(birth.NameAccepted("Vera"))
    let assert Some(named) = core.load(root, "sim:a")
    named.name |> should.equal(Some("Vera"))
  })
}

pub fn confirmation_with_another_name_proposes_it_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    step(root, "sim:a", "Bia", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Bia"))
    birth.step(
      root,
      "sim:a",
      "sim, mas prefiro Ana",
      3000,
      fn(_) { Ok("") },
      named_extract("Ana"),
    )
    |> should.equal(birth.ConfirmName("Ana"))
    let assert Some(unnamed) = core.load(root, "sim:a")
    unnamed.name |> should.equal(None)
  })
}

pub fn a_yes_with_chatter_and_no_name_is_accepted_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    step(root, "sim:a", "líquen", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Líquen"))
    birth.step(
      root,
      "sim:a",
      "sim kkk, combina com você",
      3000,
      fn(_) { Ok("") },
      no_name_extract,
    )
    |> should.equal(birth.NameAccepted("Líquen"))
  })
}

pub fn chatter_without_yes_or_name_is_not_understood_test() {
  with_constellation(fn(root) {
    let _ = step(root, "sim:a", "oi", 1000, fn(_) { Ok("Eu sou.") })
    step(root, "sim:a", "Bia", 2000, fn(_) { Ok("") })
    |> should.equal(birth.ConfirmName("Bia"))
    birth.step(
      root,
      "sim:a",
      "hmm, deixa eu pensar",
      3000,
      fn(_) { Ok("") },
      no_name_extract,
    )
    |> should.equal(birth.NameRejected(birth.rejected_message()))
    let assert Some(unnamed) = core.load(root, "sim:a")
    unnamed.name |> should.equal(None)
  })
}

pub fn opens_with_affirmation_reads_the_first_word_test() {
  birth.opens_with_affirmation("Sim, Vera. Fechado.") |> should.be_true()
  birth.opens_with_affirmation("isso! combina") |> should.be_true()
  birth.opens_with_affirmation("simplesmente não") |> should.be_false()
  birth.opens_with_affirmation("não, sim") |> should.be_false()
}

// Regression from the first real battery: MiniMax-M3 wrote a core with
// Chinese characters in it, and the core is never rewritten.
pub fn usable_prose_rejects_cjk_and_empty_text_test() {
  birth.usable_prose("Eu observo antes de agir. Gosto de café.")
  |> should.be_true()
  birth.usable_prose("uma cor que parece中含有 um segredo") |> should.be_false()
  birth.usable_prose("   ") |> should.be_false()
}

fn queued_generate(
  answers: List(String),
) -> fn(String) -> Result(String, String) {
  let queue = process.new_subject()
  list.each(answers, fn(answer) { process.send(queue, answer) })
  fn(_prompt) {
    case process.receive(queue, 0) {
      Ok(answer) -> Ok(answer)
      Error(_) -> Error("no more answers")
    }
  }
}

pub fn birth_gives_up_after_three_broken_core_texts_test() {
  with_constellation(fn(root) {
    let generate = queued_generate(["um 中", "dois 한국", "três の", "Eu sou."])
    step(root, "sim:a", "oi", 1000, generate) |> should.equal(birth.BirthFailed)
    core.load(root, "sim:a") |> should.equal(None)
  })
}

pub fn birth_retries_a_broken_core_text_test() {
  with_constellation(fn(root) {
    let generate = queued_generate(["quebrado 中文", "Eu observo antes de agir."])
    let assert birth.AskName(text) = step(root, "sim:a", "oi", 1000, generate)
    string.starts_with(text, "Eu observo antes de agir.") |> should.be_true()
    let assert Ok(prose) = read_file(core.prose_path(root, "sim:a"))
    string.contains(prose, "中") |> should.be_false()
  })
}

// Regression from the battery: "Prazer, clara." read as if the agent greeted
// the person by that name; and the name kept the person's lowercase.
pub fn accepted_name_is_capitalized_and_taken_as_own_test() {
  birth.capitalize_name("clara") |> should.equal("Clara")
  birth.capitalize_name("Ícaro") |> should.equal("Ícaro")
  birth.capitalize_name("élan") |> should.equal("Élan")
  birth.accepted_message("Clara") |> should.equal("Clara, então. Prazer!")
}

fn with_intro_prompt(path: String, body: fn() -> a) -> a {
  let previous = envoy.get("SUPERNOVA_INTRO_PROMPT_PATH")
  use <- exception.defer(fn() {
    case previous {
      Ok(value) -> envoy.set("SUPERNOVA_INTRO_PROMPT_PATH", value)
      Error(_) -> envoy.unset("SUPERNOVA_INTRO_PROMPT_PATH")
    }
  })
  envoy.set("SUPERNOVA_INTRO_PROMPT_PATH", path)
  body()
}

fn core_or_intro(prompt: String) -> Result(String, String) {
  case string.contains(prompt, "Escreva a primeira coisa que ela diz") {
    True -> Ok("Cheguei agora. Falo pouco.")
    False -> Ok("Primeiro parágrafo do núcleo.\n\nSegundo parágrafo, longo.")
  }
}

// Regression from the battery: the agent presented herself with the whole
// core (300 words) while the core said "falo pouco".
pub fn the_agent_presents_herself_briefly_test() {
  with_constellation(fn(root) {
    step(root, "sim:a", "oi", 1000, core_or_intro)
    |> should.equal(birth.AskName(
      "Cheguei agora. Falo pouco.\n\n" <> birth.question(),
    ))
  })
}

pub fn without_the_intro_prompt_the_first_paragraph_presents_her_test() {
  with_constellation(fn(root) {
    with_intro_prompt(root <> "/missing_intro_prompt.md", fn() {
      step(root, "sim:a", "oi", 1000, core_or_intro)
      |> should.equal(birth.AskName(
        "Primeiro parágrafo do núcleo.\n\n" <> birth.question(),
      ))
    })
  })
}
