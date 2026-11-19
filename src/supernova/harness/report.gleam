//// Markdown and JSON report for one harness execution.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import supernova/harness/cost
import supernova/harness/judge

pub type RunOutcome {
  RunOutcome(
    index: Int,
    approved: Bool,
    failures: List(String),
    criteria: List(judge.CriterionResult),
    costs: cost.Costs,
    transcript_path: String,
  )
}

pub type ScenarioOutcome {
  ScenarioOutcome(
    id: String,
    critical: Bool,
    runs: List(RunOutcome),
    costs: cost.Costs,
  )
}

pub type Report {
  Report(
    outcomes: List(ScenarioOutcome),
    partial: Bool,
    calibrated: Bool,
    total: cost.Costs,
    started_at: Int,
  )
}

pub fn approval_rate(outcome: ScenarioOutcome) -> Float {
  case outcome.runs {
    [] -> 0.0
    runs ->
      int.to_float(list.length(list.filter(runs, fn(run) { run.approved })))
      /. int.to_float(list.length(runs))
  }
}

pub fn passes(outcome: ScenarioOutcome) -> Bool {
  case outcome.critical {
    True -> approval_rate(outcome) == 1.0
    False -> approval_rate(outcome) >=. 0.6666666666666666
  }
}

pub fn ok(report: Report) -> Bool {
  case report.partial {
    True -> False
    False -> list.all(report.outcomes, passes)
  }
}

pub fn render_markdown(report: Report) -> String {
  let header = [
    "# Harness de personas e juiz",
    "",
    case report.calibrated {
      True -> "Juiz calibrado."
      False ->
        "**juiz não calibrado** — os vereditos não contam como aprovação."
    },
    case report.partial {
      True -> "**parcial: teto de custo**"
      False -> ""
    },
    "",
    "| cenário | crítico | execuções | aprovação | custo |",
    "|---|---|---|---|---|",
  ]
  let rows =
    report.outcomes
    |> list.map(fn(outcome) {
      let approved =
        outcome.runs |> list.filter(fn(run) { run.approved }) |> list.length
      "| "
      <> outcome.id
      <> " | "
      <> case outcome.critical {
        True -> "sim"
        False -> "não"
      }
      <> " | "
      <> int.to_string(approved)
      <> "/"
      <> int.to_string(list.length(outcome.runs))
      <> " | "
      <> format_percent(approval_rate(outcome))
      <> " | US$ "
      <> format_money(cost.total(outcome.costs))
      <> " |"
    })
  let details =
    report.outcomes
    |> list.flat_map(fn(outcome) {
      outcome.runs
      |> list.filter(fn(run) { !run.approved })
      |> list.flat_map(fn(run) {
        ["", "## " <> outcome.id <> " execução " <> int.to_string(run.index)]
        |> list.append(
          run.failures
          |> list.map(fn(failure) { "- " <> failure }),
        )
        |> list.append(
          run.criteria
          |> list.filter(fn(criterion) {
            criterion.status == judge.Inconclusive
          })
          |> list.map(fn(criterion) {
            "- " <> criterion.id <> " inconclusivo — " <> criterion.why
          }),
        )
      })
    })
  let totals = [
    "",
    "## Custo",
    "",
    "- agentes: US$ " <> format_money(report.total.agents_usd),
    "- personas: US$ " <> format_money(report.total.personas_usd),
    "- juiz: US$ " <> format_money(report.total.judge_usd),
    "- total: US$ " <> format_money(cost.total(report.total)),
  ]
  list.flatten([header, rows, details, totals]) |> string.join("\n")
}

pub fn render_json(report: Report) -> String {
  json.to_string(
    json.object([
      #("partial", json.bool(report.partial)),
      #("calibrated", json.bool(report.calibrated)),
      #("ok", json.bool(ok(report))),
      #("started_at", json.int(report.started_at)),
      #(
        "total",
        json.object([
          #("agents_usd", json.float(report.total.agents_usd)),
          #("personas_usd", json.float(report.total.personas_usd)),
          #("judge_usd", json.float(report.total.judge_usd)),
          #("usd", json.float(cost.total(report.total))),
        ]),
      ),
      #(
        "scenarios",
        json.array(
          list.map(report.outcomes, fn(outcome) {
            json.object([
              #("id", json.string(outcome.id)),
              #("critical", json.bool(outcome.critical)),
              #("approval_rate", json.float(approval_rate(outcome))),
              #("passed", json.bool(passes(outcome))),
              #(
                "runs",
                json.array(
                  list.map(outcome.runs, fn(run) {
                    json.object([
                      #("index", json.int(run.index)),
                      #("approved", json.bool(run.approved)),
                      #("failures", json.array(run.failures, json.string)),
                      #(
                        "criteria",
                        json.array(
                          list.map(run.criteria, fn(criterion) {
                            json.object([
                              #("id", json.string(criterion.id)),
                              #("score", json.int(criterion.score)),
                              #(
                                "status",
                                json.string(case criterion.status {
                                  judge.Valid -> "valid"
                                  judge.Inconclusive -> "inconclusive"
                                }),
                              ),
                              #(
                                "evidence",
                                json.array(
                                  list.map(criterion.evidence, fn(item) {
                                    json.object([
                                      #("line", json.int(item.line)),
                                      #("quote", json.string(item.quote)),
                                    ])
                                  }),
                                  fn(value) { value },
                                ),
                              ),
                            ])
                          }),
                          fn(value) { value },
                        ),
                      ),
                      #(
                        "cost",
                        json.object([
                          #("agents_usd", json.float(run.costs.agents_usd)),
                          #("personas_usd", json.float(run.costs.personas_usd)),
                          #("judge_usd", json.float(run.costs.judge_usd)),
                        ]),
                      ),
                      #("transcript", json.string(run.transcript_path)),
                    ])
                  }),
                  fn(value) { value },
                ),
              ),
            ])
          }),
          fn(value) { value },
        ),
      ),
    ]),
  )
}

fn format_percent(value: Float) -> String {
  int.to_string(float.round(value *. 100.0)) <> "%"
}

fn format_money(value: Float) -> String {
  float_to_binary(value)
}

@external(erlang, "erlang", "float_to_binary")
fn float_to_binary(value: Float) -> String
