import envoy
import exception
import gleam/float
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/harness/cli_model
import test_workspace

const fixtures = "test/fixtures/harness"

fn omp_config(executable: String, timeout: Int) -> cli_model.CliConfig {
  cli_model.CliConfig(
    kind: cli_model.Omp,
    executable: executable,
    model: "mistral/deepseek-v4-1-flash-1017",
    max_usd_per_call: 0.05,
    timeout_seconds: timeout,
  )
}

fn claude_config(executable: String, timeout: Int) -> cli_model.CliConfig {
  cli_model.CliConfig(
    kind: cli_model.Claude,
    executable: executable,
    model: "opus",
    max_usd_per_call: 0.5,
    timeout_seconds: timeout,
  )
}

fn absolute(path: String) -> String {
  cwd() <> "/" <> path
}

fn with_fixture(name: String, body: fn(String) -> a) -> a {
  let previous = envoy.get("FAKE_FIXTURE")
  envoy.set("FAKE_FIXTURE", absolute(fixtures <> "/" <> name))
  use <- exception.defer(fn() {
    case previous {
      Ok(value) -> envoy.set("FAKE_FIXTURE", value)
      Error(_) -> envoy.unset("FAKE_FIXTURE")
    }
  })
  body(absolute(fixtures <> "/" <> name))
}

pub fn omp_reads_text_model_and_single_message_cost_test() {
  with_fixture("omp_ok.jsonl", fn(_fixture) {
    test_workspace.with_isolated_workspace("harness-cli-omp", fn(root) {
      let work = root <> "/work"
      let assert Ok(_) = ensure_dir(work)
      let assert Ok(result) =
        cli_model.call(
          omp_config(absolute(fixtures <> "/fake_omp.sh"), 10),
          "# harness:persona\nsistema",
          "transcript",
          work,
          None,
        )
      result.text |> should.equal("OK.")
      result.model |> should.equal("deepseek-v4-1-flash-1017")
      let expected = 0.000048548
      should.be_true(
        float.absolute_value(result.cost_usd -. expected) <. 0.000000001,
      )
    })
  })
}

pub fn claude_reads_structured_verdict_test() {
  with_fixture("claude_ok.json", fn(_fixture) {
    test_workspace.with_isolated_workspace("harness-cli-claude", fn(root) {
      let work = root <> "/work"
      let assert Ok(_) = ensure_dir(work)
      let assert Ok(result) =
        cli_model.call(
          claude_config(absolute(fixtures <> "/fake_claude.sh"), 10),
          "# harness:judge\nsistema",
          "[1] bia: oi",
          work,
          Some("{\"type\":\"object\"}"),
        )
      string.contains(result.text, "\"cumprimentou\"") |> should.be_true()
      result.model |> should.equal("claude-opus-5-5")
      result.cost_usd |> should.equal(0.012204)
    })
  })
}

pub fn exit_code_3_is_cost_cap_test() {
  test_workspace.with_isolated_workspace("harness-cli-exit3", fn(root) {
    let work = root <> "/work"
    let assert Ok(_) = ensure_dir(work)
    let assert Error(message) =
      cli_model.call(
        omp_config(absolute(fixtures <> "/fake_exit3.sh"), 10),
        "sys",
        "in",
        work,
        None,
      )
    string.contains(message, "cost cap") |> should.be_true()
  })
}

pub fn claude_is_error_is_failure_test() {
  test_workspace.with_isolated_workspace("harness-cli-error", fn(root) {
    let work = root <> "/work"
    let assert Ok(_) = ensure_dir(work)
    let assert Error(message) =
      cli_model.call(
        claude_config(absolute(fixtures <> "/fake_error_claude.sh"), 10),
        "sys",
        "in",
        work,
        None,
      )
    string.contains(message, "claude reported an error") |> should.be_true()
  })
}

pub fn non_json_output_is_error_test() {
  test_workspace.with_isolated_workspace("harness-cli-garbage", fn(root) {
    let work = root <> "/work"
    let assert Ok(_) = ensure_dir(work)
    let assert Error(claude_message) =
      cli_model.call(
        claude_config(absolute(fixtures <> "/fake_garbage.sh"), 10),
        "sys",
        "in",
        work,
        None,
      )
    string.contains(claude_message, "not JSON") |> should.be_true()
    let assert Error(omp_message) =
      cli_model.call(
        omp_config(absolute(fixtures <> "/fake_garbage.sh"), 10),
        "sys",
        "in",
        work,
        None,
      )
    string.contains(omp_message, "no assistant message") |> should.be_true()
  })
}

pub fn timeout_kills_the_process_test() {
  test_workspace.with_isolated_workspace("harness-cli-timeout", fn(root) {
    let work = root <> "/work"
    let assert Ok(_) = ensure_dir(work)
    let pid_file = root <> "/pid"
    envoy.set("FAKE_PID_FILE", pid_file)
    let assert Error(message) =
      cli_model.call(
        omp_config(absolute(fixtures <> "/fake_slow.sh"), 1),
        "sys",
        "in",
        work,
        None,
      )
    string.contains(message, "timed out") |> should.be_true()
    let assert Ok(pid_text) = read_file(pid_file)
    let pid = case int.parse(string.trim(pid_text)) {
      Ok(value) -> value
      Error(_) -> 0
    }
    process_alive(pid) |> should.equal(False)
  })
}

pub fn three_hundred_kib_prompt_arrives_whole_test() {
  with_fixture("omp_ok.jsonl", fn(_fixture) {
    test_workspace.with_isolated_workspace("harness-cli-large", fn(root) {
      let work = root <> "/work"
      let records = root <> "/records"
      let assert Ok(_) = ensure_dir(work)
      let assert Ok(_) = ensure_dir(records)
      envoy.set("FAKE_RECORD_DIR", records)
      let prompt = string.repeat("x", 300 * 1024)
      let assert Ok(_) =
        cli_model.call(
          omp_config(absolute(fixtures <> "/fake_omp.sh"), 10),
          "sys",
          prompt,
          work,
          None,
        )
      let assert Ok(recorded) = read_file(records <> "/transcript.md")
      string.length(recorded) |> should.equal(300 * 1024)
    })
  })
}

pub fn persona_text_never_goes_through_a_shell_test() {
  with_fixture("omp_ok.jsonl", fn(_fixture) {
    test_workspace.with_isolated_workspace("harness-cli-shell", fn(root) {
      let work = root <> "/work"
      let records = root <> "/records"
      let assert Ok(_) = ensure_dir(work)
      let assert Ok(_) = ensure_dir(records)
      envoy.set("FAKE_RECORD_DIR", records)
      let dangerous =
        "quero $(rm -rf x) e \"aspas\"\ncom quebras\n`id`; echo fim"
      let assert Ok(_) =
        cli_model.call(
          omp_config(absolute(fixtures <> "/fake_omp.sh"), 10),
          dangerous,
          dangerous,
          work,
          None,
        )
      let assert Ok(recorded) = read_file(records <> "/transcript.md")
      recorded |> should.equal(dangerous)
      let assert Ok(system) = read_file(records <> "/system.md")
      system |> should.equal(dangerous)
      file_exists(work <> "/x") |> should.equal(Ok(False))
    })
  })
}

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_harness_ffi", "process_alive")
fn process_alive(pid: Int) -> Bool

@external(erlang, "supernova_harness_ffi", "cwd")
fn cwd() -> String

// Regression: a real CLI may log on stderr and read a piped stdin until EOF.
// stderr must not corrupt the JSON, and stdin must be closed so the call does
// not hang until the timeout.
pub fn cli_ignores_stderr_and_gets_closed_stdin_test() {
  with_fixture("claude_ok.json", fn(_fixture) {
    test_workspace.with_isolated_workspace("harness-cli-noisy", fn(root) {
      let work = root <> "/work"
      let assert Ok(_) = ensure_dir(work)
      let assert Ok(result) =
        cli_model.call(
          claude_config(absolute(fixtures <> "/fake_noisy_stdin.sh"), 10),
          "# harness:judge\nsistema",
          "instrução",
          work,
          None,
        )
      result.model |> should.equal("claude-opus-5-5")
    })
  })
}

// Regression: a zero cost serialized as the integer 0 is still a cost.
pub fn integer_costs_are_accepted_test() {
  with_fixture("claude_int_cost.json", fn(_fixture) {
    test_workspace.with_isolated_workspace("harness-cli-int-claude", fn(root) {
      let work = root <> "/work"
      let assert Ok(_) = ensure_dir(work)
      let assert Ok(result) =
        cli_model.call(
          claude_config(absolute(fixtures <> "/fake_claude.sh"), 10),
          "# harness:judge\nsistema",
          "instrução",
          work,
          None,
        )
      result.cost_usd |> should.equal(0.0)
    })
  })
  with_fixture("omp_int_cost.jsonl", fn(_fixture) {
    test_workspace.with_isolated_workspace("harness-cli-int-omp", fn(root) {
      let work = root <> "/work"
      let assert Ok(_) = ensure_dir(work)
      let assert Ok(result) =
        cli_model.call(
          omp_config(absolute(fixtures <> "/fake_omp.sh"), 10),
          "# harness:persona\nsistema",
          "transcript",
          work,
          None,
        )
      result.cost_usd |> should.equal(0.0)
      result.text |> should.equal("OK.")
    })
  })
}

// An argument above the kernel's per-argument limit is refused up front.
pub fn oversized_argument_is_refused_test() {
  with_fixture("claude_ok.json", fn(_fixture) {
    test_workspace.with_isolated_workspace("harness-cli-big-arg", fn(root) {
      let work = root <> "/work"
      let assert Ok(_) = ensure_dir(work)
      let assert Error(reason) =
        cli_model.call(
          claude_config(absolute(fixtures <> "/fake_claude.sh"), 10),
          "# harness:judge\nsistema",
          string.repeat("x", 200_000),
          work,
          None,
        )
      string.contains(reason, "too long") |> should.be_true()
    })
  })
}
