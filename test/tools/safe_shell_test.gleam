import gleam/string
import gleeunit/should
import supernova/tools/safe_shell

fn assert_blocked_path(command: String) -> Nil {
  let assert Error(err) = safe_shell.execute(command)
  string.contains(err, "Blocked:") |> should.equal(True)
}

pub fn safe_shell_blocks_etc_passwd_test() {
  assert_blocked_path("cat /etc/passwd")
}

pub fn safe_shell_blocks_find_root_test() {
  assert_blocked_path("find / -name secret")
}

pub fn safe_shell_blocks_any_absolute_path_with_workspace_guard_test() {
  assert_blocked_path("cat /srv/secret")
  assert_blocked_path("ls /etc")
}

pub fn safe_shell_blocks_tab_separated_absolute_path_test() {
  assert_blocked_path("cat\t/etc/passwd")
}

pub fn safe_shell_allows_relative_workspace_paths_test() {
  let assert Ok(output) = safe_shell.execute("cat README.md")
  string.contains(output, "Supernova") |> should.equal(True)

  safe_shell.execute("ls -la")
  |> should.be_ok
}

pub fn safe_shell_blocks_shell_operators_test() {
  safe_shell.execute("echo ok; id")
  |> should.be_error
}

pub fn safe_shell_blocks_shell_expansions_test() {
  [
    "cat ~/.ssh/id_rsa",
    "cat $HOME/x",
    "echo $API_KEY",
    "ls src/*",
    "cat foo?",
    "cat {a,b}",
    "cat \\/etc/passwd",
    "echo hi\nid",
    "echo hi\rid",
  ]
  |> list_each_blocked()
}

fn list_each_blocked(commands: List(String)) -> Nil {
  case commands {
    [] -> Nil
    [cmd, ..rest] -> {
      let assert Error(reason) = safe_shell.execute(cmd)
      string.starts_with(reason, "Command contains blocked operators:")
      |> should.equal(True)
      list_each_blocked(rest)
    }
  }
}

// Validation-only checks: these commands must NEVER be executed by a test,
// because a missing guard would run them for real in the project root.
fn assert_rejected(command: String, expected: String) -> Nil {
  let assert Error(reason) = safe_shell.validate(command)
  string.contains(reason, expected) |> should.equal(True)
}

// A single `&` used to pass validation and run a second command through
// /bin/sh (`open_port({spawn, ...})`).
pub fn safe_shell_rejects_background_operator_test() {
  assert_rejected("echo hi & id", "blocked operators")
  assert_rejected("echo hi&id", "blocked operators")
  assert_rejected("ls (id)", "blocked operators")
}

// `find` actions that delete, execute or write files are flags, so they skip
// the workspace path check; they must be rejected explicitly.
pub fn safe_shell_rejects_find_side_effect_actions_test() {
  [
    "find . -delete", "find . -exec id", "find . -execdir id", "find . -ok id",
    "find . -okdir id", "find . -fprint out", "find . -fprint0 out",
    "find . -fprintf out x", "find . -fls out",
  ]
  |> list_each_rejected("find action not allowed")
}

fn list_each_rejected(commands: List(String), expected: String) -> Nil {
  case commands {
    [] -> Nil
    [cmd, ..rest] -> {
      assert_rejected(cmd, expected)
      list_each_rejected(rest, expected)
    }
  }
}

pub fn safe_shell_validate_returns_argv_test() {
  safe_shell.validate("ls -la src")
  |> should.equal(Ok(["ls", "-la", "src"]))
}

// The executor must never hand the command line to a shell: arguments are
// passed as argv, so metacharacters inside an argument stay literal.
pub fn safe_shell_runs_without_a_shell_test() {
  run_argv(["echo", "a & echo INJECTED"])
  |> should.equal(Ok("a & echo INJECTED"))
}

pub fn safe_shell_reports_unknown_executable_test() {
  let assert Error(reason) = run_argv(["supernova-no-such-binary"])
  string.contains(reason, "not found") |> should.equal(True)
}

@external(erlang, "supernova_safe_shell_ffi", "run_command")
fn run_argv(argv: List(String)) -> Result(String, String)

// Qwen 4, B5: a big file comes back cut, not whole into the BEAM.
pub fn safe_shell_cuts_a_big_output_test() {
  let path = "build/safe_shell_big.txt"
  let assert Ok(_) = write_file(path, string.repeat("abcdefghij\n", 20_000))
  let assert Ok(output) = safe_shell.execute("cat " <> path)
  let _ = delete_file(path)
  string.ends_with(output, "[output cut at 64 KiB]") |> should.be_true
  { string.byte_size(output) < 66_000 } |> should.be_true
}

pub fn safe_shell_keeps_a_small_output_whole_test() {
  let path = "build/safe_shell_small.txt"
  let assert Ok(_) = write_file(path, "pequeno\n")
  let assert Ok(output) = safe_shell.execute("cat " <> path)
  let _ = delete_file(path)
  output |> should.equal("pequeno")
}

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn delete_file(path: String) -> Result(Nil, String)
