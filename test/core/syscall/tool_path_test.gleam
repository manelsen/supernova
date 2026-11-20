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

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)
