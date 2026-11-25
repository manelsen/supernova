//// Architecture — every production tool call must pass through the gateway.

import gleam/list
import gleam/string
import gleeunit/should

@external(erlang, "isolation_test_ffi", "gleam_files_under")
fn gleam_files_under(dir: String) -> List(String)

@external(erlang, "isolation_test_ffi", "read_file")
fn read_file(path: String) -> String

pub fn executor_does_not_import_concrete_tools_test() {
  let executor_path = "src/supernova/core/executor.gleam"
  let source = read_file(executor_path)
  let offending =
    source
    |> string.split("\n")
    |> list.filter(fn(line) {
      let trimmed = string.trim(line)
      string.starts_with(trimmed, "import supernova/tools/")
    })

  should.equal(offending, [])
}

pub fn production_does_not_disable_budget_test() {
  let offending =
    gleam_files_under("src")
    |> list.filter(fn(path) { !string.contains(path, "/core/budget_policy/") })
    |> list.filter(fn(path) {
      read_file(path) |> string.contains("budget_policy: None")
    })

  should.equal(offending, [])
}

pub fn gateway_is_the_only_tool_dispatch_import_test() {
  // Concrete tool modules may be imported by tool_dispatch and the tool
  // modules themselves; the executor must not reach around the gateway.
  let offenders =
    gleam_files_under("src")
    |> list.filter(fn(path) {
      string.contains(path, "core/executor.gleam")
      || string.contains(path, "core/tool_dispatch.gleam")
    })
    |> list.filter(fn(path) {
      let source = read_file(path)
      string.contains(source, "safe_shell.execute")
      || string.contains(source, "browser.execute")
      || string.contains(source, "file_system.write")
    })

  // tool_dispatch is allowed to call concrete modules; executor is not.
  let executor_offenders =
    list.filter(offenders, fn(path) { string.contains(path, "executor.gleam") })
  should.equal(executor_offenders, [])
}

/// PRD-E, E-04: a production gateway starts with its workspace, budget and
/// audit policies; none of the three is `None`.
pub fn production_gateways_start_with_every_policy_test() {
  let offending =
    gleam_files_under("src")
    |> list.filter(fn(path) {
      !string.contains(path, "/core/syscall/actor.gleam")
    })
    |> list.flat_map(fn(path) {
      read_file(path)
      |> string.split("start_with_capabilities(")
      |> list.drop(1)
      |> list.filter(fn(after) {
        after
        |> string.split(",")
        |> list.take(3)
        |> list.any(fn(argument) { string.contains(argument, "None") })
      })
      |> list.map(fn(_) { path })
    })

  should.equal(offending, [])
}

/// PRD-C, C-01: the core never matches on channel names. It asks the
/// channel's traits (`channel/catalog`).
pub fn the_core_does_not_match_channel_names_test() {
  let names = [
    "telegram", "discord", "slack", "matrix", "whatsapp", "sim", "lark",
    "google_chat", "mattermost", "wechat_work",
  ]
  let offending =
    [
      "src/supernova.gleam",
      "src/supernova/adapters/channel_common_router.gleam",
    ]
    |> list.filter(fn(path) {
      let source = read_file(path)
      list.any(names, fn(name) {
        string.contains(source, "\"" <> name <> "\" ->")
        || string.contains(source, "== \"" <> name <> "\"")
      })
    })
  should.equal(offending, [])
}

/// PRD-I, I-01: a principal is derived in one place (`agent_identity`,
/// the gate), where linked identities are resolved; nobody builds
/// `<channel>:<user>` by hand on the way to a turn.
pub fn principals_are_derived_in_one_place_test() {
  let offending =
    gleam_files_under("src/supernova")
    |> list.filter(fn(path) {
      string.contains(path, "/core/")
      || string.contains(path, "/self/")
      || string.contains(path, "channel_common_router")
    })
    |> list.filter(fn(path) {
      let source = read_file(path)
      string.contains(source, "<> \":\" <> msg.user_id")
      || string.contains(source, "<> \":\" <> interaction.user_id")
      || string.contains(source, "<> \":\" <> message.user_id")
    })
  should.equal(offending, [])
}
