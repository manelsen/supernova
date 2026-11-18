import gleam/string
import gleeunit/should
import supernova/tools/safe_shell

pub fn safe_shell_blocks_etc_passwd_test() {
  safe_shell.execute("cat /etc/passwd")
  |> should.be_error
}

pub fn safe_shell_blocks_find_root_test() {
  safe_shell.execute("find / -name secret")
  |> should.be_error
}

pub fn safe_shell_blocks_any_absolute_path_with_workspace_guard_test() {
  let assert Error(srv_err) = safe_shell.execute("cat /srv/secret")
  string.contains(srv_err, "Blocked:") |> should.equal(True)

  let assert Error(ls_err) = safe_shell.execute("ls /etc")
  string.contains(ls_err, "Blocked:") |> should.equal(True)
}

pub fn safe_shell_blocks_tab_separated_absolute_path_test() {
  safe_shell.execute("cat\t/etc/passwd")
  |> should.be_error
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
