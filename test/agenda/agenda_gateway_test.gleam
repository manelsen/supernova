import exception
import gleam/dict
import gleam/option
import gleeunit/should
import supernova/agenda/runtime
import supernova/agenda/store
import supernova/config
import supernova/core/capability_manifest/types as cap_types
import supernova/core/syscall/actor
import test_workspace

const now = 1_795_273_200_000

fn member_gateway() -> actor.SyscallGateway {
  let manifests =
    dict.from_list([
      #(
        "member",
        cap_types.CapabilityManifest(
          allowed_tools: ["agenda"],
          denied_tools: [],
        ),
      ),
    ])
  let assert Ok(gateway) =
    actor.start_with_capabilities(
      option.None,
      option.None,
      option.None,
      manifests,
      fn(_, _) { Error("the raw executor must not run agenda") },
    )
  gateway
}

fn call(
  gateway: actor.SyscallGateway,
  principal: String,
  args: String,
) -> Result(String, String) {
  let assert Ok(reservation) =
    actor.authorize_tool_call(gateway, principal, "member", "agenda", args)
  let assert Ok(execute) = actor.claim_tool_call(gateway, reservation)
  execute("agenda", args)
}

// The gateway runs an agenda call on the caller's own agenda: one person's
// agent can neither see nor change another person's entries.
pub fn agenda_runs_for_the_caller_test() {
  let dir = test_workspace.create_temp_dir("agenda-gateway")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  runtime.configure(
    runtime.Context(data_dir: dir, offset_minutes: -180, clock: fn() { now }),
  )
  let gateway = member_gateway()
  let add =
    "{\"action\":\"add\",\"when\":\"0 5 * * *\",\"request\":\"radar da Ana\"}"
  let assert Ok(_) = call(gateway, "telegram:111", add)

  let assert [entry] = store.list(dir, "telegram:111")
  entry.request |> should.equal("radar da Ana")
  store.list(dir, "telegram:222") |> should.equal([])

  call(gateway, "telegram:222", "{\"action\":\"list\"}")
  |> should.equal(Ok("(agenda vazia)"))
  call(gateway, "telegram:222", "{\"action\":\"remove\",\"id\":1}")
  |> should.be_error
  let assert [_] = store.list(dir, "telegram:111")
}

pub fn members_may_use_the_agenda_by_default_test() {
  let defaults = config.default_capabilities_config()
  defaults.member.allowed
  |> should_contain("agenda")
}

fn should_contain(items: List(String), item: String) -> Nil {
  case items {
    [] -> should.fail()
    [first, ..] if first == item -> Nil
    [_, ..rest] -> should_contain(rest, item)
  }
}
