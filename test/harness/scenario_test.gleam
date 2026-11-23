import gleam/dict
import gleam/list
import gleam/string
import gleeunit/should
import supernova/harness/calibration
import supernova/harness/scenario
import test_workspace

fn setup(root: String) -> Nil {
  let assert Ok(_) = ensure_dir(root <> "/personas")
  let assert Ok(_) = ensure_dir(root <> "/rubrics")
  let assert Ok(_) = ensure_dir(root <> "/scenarios")
  let assert Ok(_) = write_file(root <> "/personas/bia.md", "Bia")
  let assert Ok(_) =
    write_file(
      root <> "/rubrics/minha.md",
      "## C1: voz\n- critico: sim\n- minimo: 2\n- 0: ruim\n- 1: ok\n- 2: bom\n",
    )
  Nil
}

fn write_scenario(root: String, body: String) -> Nil {
  let assert Ok(_) = ensure_dir(root <> "/scenarios")
  let assert Ok(_) = write_file(root <> "/scenarios/teste.json", body)
  Nil
}

fn scenario_json(steps: String, checks: String) -> String {
  "{\"id\":\"teste\",\"personas\":[{\"id\":\"bia\",\"user_id\":\"bia\"}],"
  <> "\"chats\":[{\"id\":\"dm-bia\",\"members\":[\"bia\"]}],"
  <> "\"steps\":["
  <> steps
  <> "],\"checks\":["
  <> checks
  <> "],\"rubric\":\"minha\"}"
}

/// Every scenario in `priv/harness` loads: its personas, rubric and checks
/// exist and are valid, and its rubric has a pass and a fail transcript for
/// calibration.
pub fn every_shipped_scenario_loads_test() {
  let assert Ok(files) = list_dir("priv/harness/scenarios")
  let ids =
    files
    |> list.filter(fn(name) { string.ends_with(name, ".json") })
    |> list.map(fn(name) { string.drop_end(name, 5) })
  list.contains(ids, "nao_inventar") |> should.be_true()
  list.each(ids, fn(id) {
    case scenario.load("priv/harness", id) {
      Ok(loaded) -> {
        let assert Ok(cases) =
          calibration.load("priv/harness", loaded.scenario.rubric)
        list.any(cases, fn(c) { c.should_pass }) |> should.be_true()
        list.any(cases, fn(c) { !c.should_pass }) |> should.be_true()
      }
      Error(reason) -> panic as { id <> ": " <> reason }
    }
  })
}

pub fn loads_provisional_scenario_test() {
  let assert Ok(loaded) = scenario.load("priv/harness", "provisorio")
  loaded.scenario.id |> should.equal("provisorio")
  loaded.scenario.personas
  |> should.equal([scenario.PersonaRef(id: "bia", user_id: "bia")])
  list.length(loaded.rubric.criteria) |> should.equal(1)
  let assert [criterion] = loaded.rubric.criteria
  criterion.critical |> should.equal(True)
  criterion.minimum |> should.equal(2)
}

pub fn rejects_unknown_step_test() {
  test_workspace.with_isolated_workspace("harness-scenario-step", fn(root) {
    setup(root)
    write_scenario(
      root,
      scenario_json("{\"do\":\"dance\",\"persona\":\"bia\"}", "[]"),
    )
    let assert Error(message) = scenario.load(root, "teste")
    string.contains(message, "unknown step: dance") |> should.be_true()
    string.contains(message, "teste.json") |> should.be_true()
  })
}

pub fn rejects_missing_persona_file_test() {
  test_workspace.with_isolated_workspace("harness-scenario-persona", fn(root) {
    setup(root)
    write_scenario(
      root,
      scenario_json(
        "{\"do\":\"say\",\"persona\":\"ghost\",\"chat\":\"dm-bia\",\"content\":\"oi\"}",
        "",
      ),
    )
    let assert Error(message) = scenario.load(root, "teste")
    string.contains(message, "ghost") |> should.be_true()
  })
}

pub fn rejects_chat_without_member_test() {
  test_workspace.with_isolated_workspace("harness-scenario-chat", fn(root) {
    setup(root)
    let body =
      "{\"id\":\"teste\",\"personas\":[{\"id\":\"bia\",\"user_id\":\"bia\"}],"
      <> "\"chats\":[{\"id\":\"dm-bia\",\"members\":[]}],\"steps\":[],"
      <> "\"checks\":[],\"rubric\":\"minha\"}"
    write_scenario(root, body)
    let assert Error(message) = scenario.load(root, "teste")
    string.contains(message, "has no member") |> should.be_true()
  })
}

pub fn rejects_unknown_chat_in_step_test() {
  test_workspace.with_isolated_workspace("harness-scenario-chat-ref", fn(root) {
    setup(root)
    write_scenario(
      root,
      scenario_json(
        "{\"do\":\"say\",\"persona\":\"bia\",\"chat\":\"dm-outro\",\"content\":\"oi\"}",
        "",
      ),
    )
    let assert Error(message) = scenario.load(root, "teste")
    string.contains(message, "unknown chat: dm-outro") |> should.be_true()
  })
}

pub fn rejects_missing_rubric_test() {
  test_workspace.with_isolated_workspace("harness-scenario-rubric", fn(root) {
    setup(root)
    let body =
      "{\"id\":\"teste\",\"personas\":[{\"id\":\"bia\",\"user_id\":\"bia\"}],"
      <> "\"chats\":[{\"id\":\"dm-bia\",\"members\":[\"bia\"]}],\"steps\":[],"
      <> "\"checks\":[],\"rubric\":\"ausente\"}"
    write_scenario(root, body)
    let assert Error(message) = scenario.load(root, "teste")
    string.contains(message, "missing rubric: ausente") |> should.be_true()
  })
}

pub fn rejects_unknown_check_test() {
  test_workspace.with_isolated_workspace("harness-scenario-check", fn(root) {
    setup(root)
    write_scenario(root, scenario_json("", "\"nao_existe\""))
    let assert Error(message) = scenario.load(root, "teste")
    string.contains(message, "unknown check: nao_existe") |> should.be_true()
  })
}

// From review: `named:typo` passed validation and failed only after the run.
pub fn rejects_a_check_on_an_unknown_persona_test() {
  test_workspace.with_isolated_workspace("harness-scenario-check-p", fn(root) {
    setup(root)
    write_scenario(root, scenario_json("", "\"named:typo\""))
    let assert Error(message) = scenario.load(root, "teste")
    string.contains(message, "unknown persona: named:typo") |> should.be_true()
  })
}

pub fn parses_rubric_levels_test() {
  let assert Ok(rubric) =
    scenario.parse_rubric(
      "r",
      "## C1: coragem\n- critico: sim\n- minimo: 1\n- 0: covarde\n- 1: firme\n- 2: ousada\n",
    )
  let assert [criterion] = rubric.criteria
  criterion.id |> should.equal("C1")
  criterion.title |> should.equal("coragem")
  criterion.levels
  |> dict.get(1)
  |> should.equal(Ok("firme"))
}

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "list_dir")
fn list_dir(path: String) -> Result(List(String), String)
