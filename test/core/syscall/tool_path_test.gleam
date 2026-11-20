import gleam/dict
import gleam/option
import gleam/string
import gleeunit/should
import supernova/core/capability_manifest/types as cap_types
import supernova/core/syscall/actor
import supernova/core/workspace_policy/actor as policy_actor
import supernova/core/workspace_policy/types as policy_types
import test_workspace

// Regression from the battery: the gateway authorized a path inside the
// agent's workspace and then ran the tool on the raw path, relative to the
// process directory. Agents listed the application's root, read its files
// and wrote next to them (one read a file another agent had written).
pub fn file_system_runs_on_the_authorized_path_test() {
  test_workspace.with_isolated_workspace("tool-path", fn(root) {
    let assert Ok(policy) = policy_actor.start(root)
    let manifests =
      dict.from_list([
        #(
          "member",
          cap_types.CapabilityManifest(
            allowed_tools: ["file_system"],
            denied_tools: [],
          ),
        ),
      ])
    let assert Ok(gateway) =
      actor.start_with_capabilities(
        option.Some(policy),
        option.None,
        option.None,
        manifests,
        fn(_, _) { Error("the raw executor must not run file_system") },
      )
    let args =
      "{\"action\":\"write\",\"path\":\"notas-isolamento.md\",\"content\":\"oi\"}"
    let assert Ok(reservation) =
      actor.authorize_tool_call(gateway, "sim:a", "member", "file_system", args)
    let assert Ok(execute) = actor.claim_tool_call(gateway, reservation)
    execute("file_system", args) |> should.equal(Ok("ok"))

    // Written where the policy points, inside the root; not in the cwd.
    let assert Ok(target) =
      policy_actor.authorize(
        policy,
        "sim:a",
        policy_types.OpRead,
        "notas-isolamento.md",
      )
    string.starts_with(target, root) |> should.be_true()
    read_file(target) |> should.equal(Ok("oi"))
    file_exists("notas-isolamento.md") |> should.equal(Ok(False))

    // Reading through the gateway reads the same file back.
    let read_args = "{\"action\":\"read\",\"path\":\"notas-isolamento.md\"}"
    let assert Ok(read_reservation) =
      actor.authorize_tool_call(
        gateway,
        "sim:a",
        "member",
        "file_system",
        read_args,
      )
    let assert Ok(read) = actor.claim_tool_call(gateway, read_reservation)
    read("file_system", read_args) |> should.equal(Ok("oi"))
  })
}

// Regression from the battery: a fresh agent listed its workspace before
// writing anything and got "no such file or directory", then told its person
// the tool was broken.
pub fn listing_a_fresh_workspace_is_empty_test() {
  test_workspace.with_isolated_workspace("tool-list", fn(root) {
    let assert Ok(policy) = policy_actor.start(root)
    let manifests =
      dict.from_list([
        #(
          "member",
          cap_types.CapabilityManifest(
            allowed_tools: ["file_system"],
            denied_tools: [],
          ),
        ),
      ])
    let assert Ok(gateway) =
      actor.start_with_capabilities(
        option.Some(policy),
        option.None,
        option.None,
        manifests,
        fn(_, _) { Error("the raw executor must not run file_system") },
      )
    let args = "{\"action\":\"list\",\"path\":\".\"}"
    let assert Ok(reservation) =
      actor.authorize_tool_call(gateway, "sim:b", "member", "file_system", args)
    let assert Ok(execute) = actor.claim_tool_call(gateway, reservation)
    execute("file_system", args) |> should.equal(Ok("(empty directory)"))
  })
}

fn external_reader_gateway(
  root: String,
  body: fn(actor.SyscallGateway) -> a,
) -> a {
  let assert Ok(policy) = policy_actor.start(root)
  policy_actor.set_rule(
    policy,
    "sim:x",
    policy_types.rule_with_external_read("sim:x"),
  )
  let manifests =
    dict.from_list([
      #(
        "member",
        cap_types.CapabilityManifest(
          allowed_tools: ["file_system"],
          denied_tools: [],
        ),
      ),
    ])
  let assert Ok(gateway) =
    actor.start_with_capabilities(
      option.Some(policy),
      option.None,
      option.None,
      manifests,
      fn(_, _) { Error("the raw executor must not run file_system") },
    )
  body(gateway)
}

// From review: the write check matched only a lowercase "write", so "WRITE"
// authorized as a read and, with external read allowed, wrote outside the
// workspace.
pub fn an_uppercase_write_is_still_a_write_test() {
  test_workspace.with_isolated_workspace("tool-write-case", fn(root) {
    external_reader_gateway(root, fn(gateway) {
      let target = root <> "-outside-case.txt"
      let args =
        "{\"action\":\"WRITE\",\"path\":\"" <> target <> "\",\"content\":\"x\"}"
      case
        actor.authorize_tool_call(
          gateway,
          "sim:x",
          "member",
          "file_system",
          args,
        )
      {
        Error(_) -> Nil
        Ok(reservation) -> {
          let assert Ok(execute) = actor.claim_tool_call(gateway, reservation)
          let _ = execute("file_system", args)
          Nil
        }
      }
      file_exists(target) |> should.equal(Ok(False))
    })
  })
}

// A read authorization never runs a write, whatever arguments reach the
// executor.
pub fn a_read_authorization_does_not_write_test() {
  test_workspace.with_isolated_workspace("tool-read-only", fn(root) {
    external_reader_gateway(root, fn(gateway) {
      let read_args = "{\"action\":\"read\",\"path\":\"nota.md\"}"
      let assert Ok(reservation) =
        actor.authorize_tool_call(
          gateway,
          "sim:x",
          "member",
          "file_system",
          read_args,
        )
      let assert Ok(execute) = actor.claim_tool_call(gateway, reservation)
      execute(
        "file_system",
        "{\"action\":\"write\",\"path\":\"nota.md\",\"content\":\"x\"}",
      )
      |> should.be_error()
    })
  })
}

// From review: listing created the directory, even outside the workspace
// under a read authorization.
pub fn listing_does_not_create_the_directory_test() {
  test_workspace.with_isolated_workspace("tool-list-create", fn(root) {
    external_reader_gateway(root, fn(gateway) {
      let target = root <> "-new-external-dir"
      let args = "{\"action\":\"list\",\"path\":\"" <> target <> "\"}"
      case
        actor.authorize_tool_call(
          gateway,
          "sim:x",
          "member",
          "file_system",
          args,
        )
      {
        Error(_) -> Nil
        Ok(reservation) -> {
          let assert Ok(execute) = actor.claim_tool_call(gateway, reservation)
          let _ = execute("file_system", args)
          Nil
        }
      }
      file_exists(target) |> should.equal(Ok(False))
    })
  })
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)
