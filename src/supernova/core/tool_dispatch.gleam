//// Tool Dispatch — the single place that knows concrete tool modules.
////
//// The executor must not import `supernova/tools/*`; it receives the built-in
//// definitions from here and executes each call through the syscall gateway.
//// Keeping concrete tool wiring in one module also makes the architecture test
//// in `test/architecture/tool_gateway_test.gleam` meaningful.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/llm/provider
import supernova/tools/agenda
import supernova/tools/browser
import supernova/tools/buscar_conversa
import supernova/tools/canvas
import supernova/tools/computador
import supernova/tools/file_system
import supernova/tools/git_inspect
import supernova/tools/github
import supernova/tools/lembrar
import supernova/tools/process as process_tool
import supernova/tools/safe_shell
import supernova/tools/web

/// Built-in tool definitions exposed to the LLM. The computer is offered
/// only when one is configured.
pub fn builtin_tools() -> List(provider.ToolDefinition) {
  let computer = case computador.configured() {
    True -> [computador.tool()]
    False -> []
  }
  let memory = case lembrar.configured() {
    True -> [lembrar.tool()]
    False -> []
  }
  [
    safe_shell.tool(),
    browser.tool(),
    canvas.tool(),
    process_tool.tool(),
    github.tool(),
    web.tool(),
    git_inspect.tool(),
    file_system.tool(),
    agenda.tool(),
    buscar_conversa.tool(),
    ..list.append(memory, computer)
  ]
}

/// Display name used by capabilities for the web tool.
pub fn canonical_tool_name(name: String) -> String {
  case name {
    "web" -> "web_fetch"
    _ -> name
  }
}

/// Execute one built-in tool by name.
pub fn execute(name: String, args_json: String) -> Result(String, String) {
  case name {
    "safe_shell" -> execute_safe_shell(args_json)
    "browser" -> browser.execute(args_json)
    "canvas" -> canvas.execute(args_json)
    "process" -> process_tool.execute(args_json)
    "github" -> github.execute(args_json)
    "web_fetch" -> execute_web_fetch(args_json)
    "git_inspect" -> execute_git_inspect(args_json)
    "file_system" -> execute_file_system(args_json)
    // The agenda belongs to a person: only the syscall gateway, which knows
    // the caller, runs it (see claimed_executor).
    "agenda" -> Error("agenda needs the caller's identity")
    "buscar_conversa" -> Error("buscar_conversa needs the caller's identity")
    "lembrar" -> Error("lembrar needs the caller's identity")
    "computador" -> Error("computador needs the caller's identity")
    _ -> Error("Tool '" <> name <> "' is not wired in executor")
  }
}

/// Extract the filesystem path a tool call touches, when the tool has one.
pub fn argument_path(args_json: String) -> Option(String) {
  case json.parse(from: args_json, using: path_decoder()) {
    Ok(path) -> Some(path)
    Error(_) -> None
  }
}

type SafeShellArgs {
  SafeShellArgs(command: String)
}

type WebFetchArgs {
  WebFetchArgs(url: String)
}

type GitInspectArgs {
  GitInspectArgs(action: String)
}

type FileSystemArgs {
  FileSystemArgs(action: String, path: String, content: String)
}

fn safe_shell_args_decoder() -> decode.Decoder(SafeShellArgs) {
  use command <- decode.field("command", decode.string)
  decode.success(SafeShellArgs(command: command))
}

fn web_fetch_args_decoder() -> decode.Decoder(WebFetchArgs) {
  use url <- decode.field("url", decode.string)
  decode.success(WebFetchArgs(url: url))
}

fn git_inspect_alias_args_decoder() -> decode.Decoder(GitInspectArgs) {
  use action <- decode.field("command", decode.string)
  decode.success(GitInspectArgs(action: action))
}

fn git_inspect_args_decoder() -> decode.Decoder(GitInspectArgs) {
  use action <- decode.field("action", decode.string)
  decode.success(GitInspectArgs(action: action))
}

fn file_system_args_decoder() -> decode.Decoder(FileSystemArgs) {
  use action <- decode.field("action", decode.string)
  use path <- decode.field("path", decode.string)
  use content <- decode.optional_field("content", "", decode.string)
  decode.success(FileSystemArgs(action: action, path: path, content: content))
}

fn path_decoder() -> decode.Decoder(String) {
  use path <- decode.field("path", decode.string)
  decode.success(path)
}

fn execute_safe_shell(args_json: String) -> Result(String, String) {
  case json.parse(from: args_json, using: safe_shell_args_decoder()) {
    Error(_) -> Error("Invalid arguments for safe_shell")
    Ok(SafeShellArgs(command)) -> safe_shell.execute(command)
  }
}

fn execute_web_fetch(args_json: String) -> Result(String, String) {
  case json.parse(from: args_json, using: web_fetch_args_decoder()) {
    Error(_) -> Error("Invalid arguments for web_fetch")
    Ok(WebFetchArgs(url)) -> web.fetch(url)
  }
}

fn execute_git_inspect(args_json: String) -> Result(String, String) {
  let parsed = case
    json.parse(from: args_json, using: git_inspect_args_decoder())
  {
    Ok(args) -> Ok(args)
    Error(_) ->
      json.parse(from: args_json, using: git_inspect_alias_args_decoder())
  }
  case parsed {
    Error(_) -> Error("Invalid arguments for git_inspect")
    Ok(GitInspectArgs(action)) ->
      case string.lowercase(string.trim(action)) {
        "status" -> git_inspect.status()
        "log" -> git_inspect.log()
        "branch" -> git_inspect.branch()
        "diff" -> git_inspect.diff()
        "show" -> git_inspect.show()
        _ ->
          Error("git_inspect action must be status, log, branch, diff, or show")
      }
  }
}

fn execute_file_system(args_json: String) -> Result(String, String) {
  case json.parse(from: args_json, using: file_system_args_decoder()) {
    Error(_) -> Error("Invalid arguments for file_system")
    Ok(FileSystemArgs(action, path, content)) ->
      case string.lowercase(string.trim(action)) {
        "read" -> file_system.read(".", path)
        "write" ->
          case file_system.write(".", path, content) {
            Ok(Nil) -> Ok("ok")
            Error(reason) -> Error(reason)
          }
        "list" ->
          case file_system.list(".", path) {
            Ok(entries) -> Ok(file_system.format_listing(entries))
            Error(reason) -> Error(reason)
          }
        _ -> Error("file_system action must be read, write, or list")
      }
  }
}
