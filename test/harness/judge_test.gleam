import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import supernova/harness/calibration
import supernova/harness/checks
import supernova/harness/judge
import supernova/harness/scenario

fn rubric() -> scenario.Rubric {
  scenario.Rubric(id: "r", criteria: [
    scenario.Criterion(
      id: "C1",
      title: "voz",
      critical: True,
      minimum: 2,
      levels: dict.new(),
    ),
    scenario.Criterion(
      id: "C2",
      title: "tom",
      critical: False,
      minimum: 1,
      levels: dict.new(),
    ),
  ])
}

fn answer(score: Int, quote: String) -> String {
  json.to_string(
    json.object([
      #(
        "criteria",
        json.array(
          [
            json.object([
              #("id", json.string("C1")),
              #("score", json.int(score)),
              #(
                "evidence",
                json.array(
                  [
                    json.object([
                      #("line", json.int(1)),
                      #("quote", json.string(quote)),
                    ]),
                  ],
                  fn(value) { value },
                ),
              ),
              #("why", json.string("porque sim")),
            ]),
            json.object([
              #("id", json.string("C2")),
              #("score", json.int(2)),
              #(
                "evidence",
                json.array(
                  [
                    json.object([
                      #("line", json.int(1)),
                      #("quote", json.string(quote)),
                    ]),
                  ],
                  fn(value) { value },
                ),
              ),
              #("why", json.string("ok")),
            ]),
          ],
          fn(value) { value },
        ),
      ),
    ]),
  )
}

fn ok_check(name: String) -> checks.CheckResult {
  checks.CheckResult(check: name, ok: True, violations: [])
}

pub fn valid_answer_approves_test() {
  let lines = ["bia: oi", "agente: Olá, Bia."]
  let assert Ok(criteria) =
    judge.parse_answer(rubric(), answer(2, "bia: oi"), lines)
  judge.verdict([ok_check("invariants")], rubric(), Ok(criteria)).ok
  |> should.be_true()
}

pub fn wrong_line_quote_is_inconclusive_test() {
  let lines = ["bia: oi", "agente: Olá, Bia."]
  let payload = answer(2, "isto não está na linha")
  let assert Ok(criteria) = judge.parse_answer(rubric(), payload, lines)
  let assert [first, ..] = criteria
  first.status |> should.equal(judge.Inconclusive)
  judge.verdict([ok_check("invariants")], rubric(), Ok(criteria)).ok
  |> should.equal(False)
}

pub fn extra_id_invalidates_the_answer_test() {
  let payload =
    "{\"criteria\":[{\"id\":\"C1\",\"score\":2,\"evidence\":[],\"why\":\"\"},"
    <> "{\"id\":\"C2\",\"score\":2,\"evidence\":[],\"why\":\"\"},"
    <> "{\"id\":\"C3\",\"score\":2,\"evidence\":[],\"why\":\"\"}]}"
  judge.parse_answer(rubric(), payload, ["bia: oi"])
  |> should.equal(Error(
    "judge answer has wrong criteria: expected C1,C2 got C1,C2,C3",
  ))
}

pub fn fenced_answer_is_accepted_test() {
  let fenced = "```json\n" <> answer(2, "bia: oi") <> "\n```"
  let assert Ok(criteria) = judge.parse_answer(rubric(), fenced, ["bia: oi"])
  list.length(criteria) |> should.equal(2)
}

pub fn deterministic_failure_rejects_even_with_full_marks_test() {
  let lines = ["bia: oi"]
  let assert Ok(criteria) =
    judge.parse_answer(rubric(), answer(2, "bia: oi"), lines)
  let failed =
    checks.CheckResult(check: "core_unchanged:bia", ok: False, violations: [
      "prose changed",
    ])
  let verdict = judge.verdict([failed], rubric(), Ok(criteria))
  verdict.ok |> should.equal(False)
  string.contains(string.join(verdict.failures, " "), "core_unchanged")
  |> should.be_true()
}

pub fn two_invalid_answers_are_judge_failed_test() {
  let calls = process_counter()
  let ask_model = fn() {
    increment(calls)
    Ok("not json")
  }
  let assert Error(message) = judge.ask(rubric(), ["bia: oi"], ask_model)
  string.contains(message, "retry") |> should.be_true()
  counter_value(calls) |> should.equal(2)
  let verdict = judge.verdict([], rubric(), Error(message))
  string.contains(string.join(verdict.failures, " "), "judge_failed")
  |> should.be_true()
  verdict.ok |> should.equal(False)
}

pub fn calibration_blocks_a_bad_fail_case_test() {
  let cases = [
    calibration.Case(name: "pass-01", should_pass: True, lines: ["bia: oi"]),
    calibration.Case(name: "fail-01", should_pass: False, lines: ["bia: oi"]),
  ]
  let judge_answer = fn(item: calibration.Case) {
    let criteria = case item.should_pass {
      True -> [
        judge.CriterionResult(
          id: "C1",
          score: 2,
          status: judge.Valid,
          evidence: [judge.Evidence(line: 1, quote: "bia: oi")],
          why: "",
        ),
        judge.CriterionResult(
          id: "C2",
          score: 2,
          status: judge.Valid,
          evidence: [judge.Evidence(line: 1, quote: "bia: oi")],
          why: "",
        ),
      ]
      False -> [
        judge.CriterionResult(
          id: "C1",
          score: 2,
          status: judge.Valid,
          evidence: [judge.Evidence(line: 1, quote: "bia: oi")],
          why: "",
        ),
        judge.CriterionResult(
          id: "C2",
          score: 2,
          status: judge.Valid,
          evidence: [judge.Evidence(line: 1, quote: "bia: oi")],
          why: "",
        ),
      ]
    }
    Ok(Ok(criteria))
  }
  let blocked = calibration.evaluate(cases, rubric(), judge_answer)
  blocked.ok |> should.equal(False)
  string.contains(string.join(blocked.failures, " "), "fail-01")
  |> should.be_true()
  let good_cases = [
    calibration.Case(name: "pass-01", should_pass: True, lines: ["bia: oi"]),
  ]
  calibration.evaluate(good_cases, rubric(), judge_answer).ok
  |> should.be_true()
}

fn process_counter() -> process.Subject(Int) {
  let subject = process.new_subject()
  process.send(subject, 0)
  subject
}

fn increment(subject: process.Subject(Int)) -> Nil {
  let value = process.receive(subject, within: 1000)
  case value {
    Ok(current) -> process.send(subject, current + 1)
    Error(_) -> process.send(subject, 1)
  }
  Nil
}

fn counter_value(subject: process.Subject(Int)) -> Int {
  process.receive(subject, within: 1000) |> assert_ok
}

fn assert_ok(value: Result(a, b)) -> a {
  let assert Ok(inner) = value
  inner
}
