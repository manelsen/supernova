//// Judge calibration: the judge must approve every `pass-*` transcript and
//// reject every `fail-*` one before a scored run may start.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import supernova/harness/judge
import supernova/harness/scenario.{type Rubric}
import supernova/harness/transcript

pub type Case {
  Case(name: String, should_pass: Bool, lines: List(String))
}

pub type CalibrationResult {
  CalibrationResult(ok: Bool, failures: List(String))
}

/// Load `calibration/<rubric>/pass-*.jsonl` and `fail-*.jsonl`.
pub fn load(root: String, rubric_id: String) -> Result(List(Case), String) {
  let directory = root <> "/calibration/" <> rubric_id
  let passes = find_files(directory, "pass-*.jsonl")
  let fails = find_files(directory, "fail-*.jsonl")
  let paths =
    list.append(
      list.map(passes, fn(path) { #(path, True) }),
      list.map(fails, fn(path) { #(path, False) }),
    )
  case paths {
    [] ->
      Error(
        "no calibration transcripts for rubric "
        <> rubric_id
        <> " in "
        <> directory,
      )
    _ ->
      paths
      |> list.try_map(fn(item) {
        let #(path, should_pass) = item
        let name = file_name(path)
        case read_file(path) {
          Error(_) -> Error("cannot read calibration transcript: " <> path)
          Ok(raw) -> {
            let lines =
              raw
              |> string.split("\n")
              |> list.filter(fn(line) { string.trim(line) != "" })
              |> list.filter_map(fn(line) {
                case transcript.decode_line(line) {
                  Some(event) -> Ok(transcript.render(event))
                  None -> Error(Nil)
                }
              })
            Ok(Case(name: name, should_pass: should_pass, lines: lines))
          }
        }
      })
  }
}

fn file_name(path: String) -> String {
  path
  |> string.split("/")
  |> list.last
  |> unwrap_or(path)
}

fn unwrap_or(value: Result(a, b), default: a) -> a {
  case value {
    Ok(inner) -> inner
    Error(_) -> default
  }
}

/// `judge_answer` returns either an invalid answer (retry/exhausted in the
/// caller) or the parsed criteria.
pub fn evaluate(
  cases: List(Case),
  rubric: Rubric,
  judge_answer: fn(Case) ->
    Result(Result(List(judge.CriterionResult), String), String),
) -> CalibrationResult {
  let failures =
    cases
    |> list.filter_map(fn(item) {
      case judge_answer(item) {
        Error(reason) ->
          Ok("calibration " <> item.name <> " could not be judged: " <> reason)
        Ok(Error(reason)) ->
          Ok("calibration " <> item.name <> " was invalid: " <> reason)
        Ok(Ok(criteria)) -> {
          let verdict = judge.verdict([], rubric, Ok(criteria))
          case item.should_pass, verdict.ok {
            True, False ->
              Ok(
                "calibration "
                <> item.name
                <> " should pass but was rejected: "
                <> string.join(verdict.failures, "; "),
              )
            False, True ->
              Ok("calibration " <> item.name <> " should fail but was approved")
            _, _ -> Error(Nil)
          }
        }
      }
    })
  CalibrationResult(ok: list.is_empty(failures), failures: failures)
}

@external(erlang, "supernova_file_system_ffi", "find_files")
fn find_files(dir: String, pattern: String) -> List(String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)
