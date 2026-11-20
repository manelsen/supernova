import envoy
import gleam/list
import gleam/string
import gleeunit/should
import supernova/harness/report
import supernova/harness/run
import test_workspace

fn write_config(path: String, key_name: String) -> Nil {
  let body =
    "agent: {provider: mock, model: mock-model, api_key_env: "
    <> key_name
    <> "}\n"
    <> "persona: {cli: omp, executable: /bin/true, model: p, max_usd_per_call: 0.01}\n"
    <> "judge: {cli: claude, executable: /bin/true, model: j, max_usd_per_call: 0.1}\n"
    <> "budget: {instance_daily_usd: 2.0, member_daily_usd: 0.5}\n"
    <> "reflection: {every_turns: 1}\n"
    <> "turn_timeout_seconds: 20\n"
  let assert Ok(_) = ensure_dir(dir_name(path))
  let assert Ok(_) = write_file(path, body)
  Nil
}

fn base_options(root: String) -> run.Options {
  run.Options(
    config_path: root <> "/harness.yaml",
    scenario_selector: "provisorio",
    runs: 2,
    max_usd: 100.0,
    out_dir: root <> "/out",
    long: False,
    skip_calibration: False,
    keep_data: False,
    mock_persona_cost: 0.0,
  )
}

pub fn end_to_end_mock_run_writes_report_test() {
  test_workspace.with_isolated_workspace("harness-run-e2e", fn(root) {
    write_config(root <> "/harness.yaml", "SUPERNOVA_HARNESS_TEST_KEY")
    let assert Ok(value) = run.execute(base_options(root))
    value.partial |> should.equal(False)
    value.calibrated |> should.equal(True)
    report.ok(value) |> should.be_true()
    let reports = find_files(root <> "/out", "*/report.md")
    let verdicts = find_files(root <> "/out", "*/verdicts.json")
    let transcripts =
      find_files(root <> "/out", "*/provisorio/*/transcripts.jsonl")
    list.length(reports) |> should.equal(1)
    list.length(verdicts) |> should.equal(1)
    list.length(transcripts) |> should.equal(2)
    let assert Ok(report_text) = read_file(list.first(reports) |> unwrap)
    string.contains(report_text, "| provisorio |") |> should.be_true()
  })
}

pub fn api_key_value_never_reaches_disk_test() {
  test_workspace.with_isolated_workspace("harness-run-secret", fn(root) {
    envoy.set("SUPERNOVA_HARNESS_TEST_KEY", "sk-harness-secret-9911")
    write_config(root <> "/harness.yaml", "SUPERNOVA_HARNESS_TEST_KEY")
    let assert Ok(_value) = run.execute(base_options(root))
    let files =
      find_files(root <> "/out", "**/*")
      |> list.filter(fn(path) { !string.ends_with(path, "/") })
    files
    |> list.each(fn(path) {
      case read_file(path) {
        Ok(content) ->
          string.contains(content, "sk-harness-secret-9911")
          |> should.equal(False)
        Error(_) -> Nil
      }
    })
  })
}

pub fn cost_cap_stops_and_marks_partial_test() {
  test_workspace.with_isolated_workspace("harness-run-cap", fn(root) {
    write_config(root <> "/harness.yaml", "SUPERNOVA_HARNESS_TEST_KEY")
    let options =
      run.Options(..base_options(root), max_usd: 0.005, mock_persona_cost: 0.01)
    let assert Ok(value) = run.execute(options)
    value.partial |> should.equal(True)
    report.ok(value) |> should.equal(False)
    let reports = find_files(root <> "/out", "*/report.md")
    let assert Ok(report_text) = read_file(list.first(reports) |> unwrap)
    string.contains(report_text, "parcial: teto de custo") |> should.be_true()
    let transcripts =
      find_files(root <> "/out", "*/provisorio/*/transcripts.jsonl")
    list.length(transcripts) |> should.equal(1)
  })
}

fn dir_name(path: String) -> String {
  path
  |> string.split("/")
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.join("/")
}

fn unwrap(value: Result(a, b)) -> a {
  let assert Ok(inner) = value
  inner
}

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "find_files")
fn find_files(dir: String, pattern: String) -> List(String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

pub fn money_is_formatted_without_scientific_notation_test() {
  report.format_money(0.044666252) |> should.equal("0.0447")
  report.format_money(0.0) |> should.equal("0.0000")
  report.format_money(3.0) |> should.equal("3.0000")
}

pub fn max_usd_accepts_integers_and_decimals_test() {
  run.parse_usd("3") |> should.equal(Ok(3.0))
  run.parse_usd("0.5") |> should.equal(Ok(0.5))
  run.parse_usd("três") |> should.equal(Error(Nil))
}
