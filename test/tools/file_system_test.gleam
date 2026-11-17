import gleam/list
import gleeunit
import gleeunit/should
import supernova/tools/file_system

pub fn main() {
  gleeunit.main()
}

pub fn read_write_and_list_within_workspace_test() {
  let workspace = "/tmp"
  let file_name = "supernova_fs_test.txt"
  let content = "hello from filesystem test"

  file_system.write(workspace, file_name, content) |> should.equal(Ok(Nil))
  file_system.read(workspace, file_name) |> should.equal(Ok(content))

  case file_system.list(workspace, ".") {
    Ok(entries) -> list.contains(entries, file_name) |> should.equal(True)
    Error(reason) -> panic as reason
  }
}

pub fn path_traversal_is_blocked_test() {
  case file_system.read("/tmp", "../etc/passwd") {
    Ok(_) -> panic as "Expected path traversal to be blocked"
    Error(_) -> Nil
  }
}

pub fn absolute_path_is_blocked_test() {
  file_system.read("workspace", "/etc/passwd")
  |> should.equal(Error("Absolute path blocked: /etc/passwd"))

  file_system.write("workspace", "/etc/passwd", "x")
  |> should.equal(Error("Absolute path blocked: /etc/passwd"))

  file_system.list("workspace", "/etc")
  |> should.equal(Error("Absolute path blocked: /etc"))
}

pub fn tool_definition_has_expected_name_test() {
  let tool = file_system.tool()
  tool.name |> should.equal("file_system")
}
