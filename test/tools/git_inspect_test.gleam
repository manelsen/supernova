import gleeunit/should
import supernova/tools/git_inspect
import supernova/tools/safe_shell

// ---------------------------------------------------------------------------
// Rejection tests
//
// These call ONLY `safe_shell.validate/1`. A rejected command must never be
// executed: a missing guard would run it for real.
// ---------------------------------------------------------------------------

fn assert_git_blocked(command: String, subcommand: String) -> Nil {
  safe_shell.validate(command)
  |> should.equal(Error("Blocked: git subcommand not allowed: " <> subcommand))
}

pub fn safe_shell_rejects_git_write_subcommands_test() {
  assert_git_blocked("git push", "push")
  assert_git_blocked("git push origin main", "push")
  assert_git_blocked("git commit -m x", "commit")
  assert_git_blocked("git reset --hard", "reset")
  assert_git_blocked("git checkout main", "checkout")
  assert_git_blocked("git clean -fd", "clean")
  assert_git_blocked("git config user.email x@y", "config")
}

pub fn safe_shell_rejects_git_global_options_test() {
  // `-c`/`-C`/`--exec-path` before the subcommand would defeat the allow-list.
  assert_git_blocked("git -c k=v log", "-c")
  assert_git_blocked("git -C /tmp status", "-C")
  assert_git_blocked("git --exec-path status", "--exec-path")
  assert_git_blocked(
    "git --exec-path=/tmp/evil status",
    "--exec-path=/tmp/evil",
  )
}

pub fn safe_shell_rejects_git_global_options_after_subcommand_test() {
  assert_git_blocked("git diff -C", "-C")
  assert_git_blocked("git log --exec-path=/tmp/evil", "--exec-path=/tmp/evil")
}

pub fn safe_shell_rejects_bare_git_test() {
  safe_shell.validate("git")
  |> should.equal(Error("Blocked: git subcommand required"))
}

pub fn safe_shell_rejects_git_shell_metacharacters_test() {
  // The dangerous-character guard still applies to git commands.
  safe_shell.validate("git log; id")
  |> should.equal(Error("Command contains blocked operators: git log; id"))
  safe_shell.validate("git diff $(id)")
  |> should.equal(Error("Command contains blocked operators: git diff $(id)"))
}

// ---------------------------------------------------------------------------
// Validation tests: read-only subcommands validate (and stay argv-split).
// ---------------------------------------------------------------------------

pub fn safe_shell_allows_read_only_git_subcommands_test() {
  safe_shell.validate("git status --short")
  |> should.equal(Ok(["git", "status", "--short"]))
  safe_shell.validate("git log --oneline -10")
  |> should.equal(Ok(["git", "log", "--oneline", "-10"]))
  safe_shell.validate("git branch --show-current")
  |> should.equal(Ok(["git", "branch", "--show-current"]))
  safe_shell.validate("git diff")
  |> should.equal(Ok(["git", "diff"]))
  safe_shell.validate("git show")
  |> should.equal(Ok(["git", "show"]))
}

// ---------------------------------------------------------------------------
// Execution test
//
// Runs inside a throw-away repository under /tmp, never in the project tree.
// The FFI helper restores the process cwd even if the test fails.
// ---------------------------------------------------------------------------

pub fn git_inspect_works_in_temp_repo_test() {
  let status = with_temp_repo(fn() { git_inspect.status() })
  status |> should.be_ok

  let log = with_temp_repo(fn() { git_inspect.log() })
  log |> should.be_ok

  let diff = with_temp_repo(fn() { git_inspect.diff() })
  diff |> should.be_ok

  let show = with_temp_repo(fn() { git_inspect.show() })
  show |> should.be_ok
}

@external(erlang, "test_git_repo_ffi", "with_temp_repo")
fn with_temp_repo(run: fn() -> Result(String, String)) -> Result(String, String)
