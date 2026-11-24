//// lembrar is offered only with the memory on, runs through the syscall
//// gateway for the caller's own conversations, and members may use it.

import exception
import gleam/dict
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import supernova/agenda/runtime as agenda_runtime
import supernova/config
import supernova/core/capability_manifest/types as cap_types
import supernova/core/session/history_store.{HistoryStore, StoredMessage}
import supernova/core/syscall/actor
import supernova/core/tool_dispatch
import supernova/memory/decision
import supernova/memory/runtime
import supernova/tools/lembrar
import test_workspace

const base = 1_795_694_400_000

fn with_dir(body: fn(String) -> a) -> a {
  let dir = test_workspace.create_temp_dir("lembrar")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(dir)
}

/// Every excerpt has the same vector; the Decision says excerpt 1.
fn fake() -> decision.Transport {
  fn(url, _headers, _body) {
    case url == decision.embed_url {
      True -> Ok(#(200, "{\"embedding\":{\"values\":[1,0]}}"))
      False ->
        Ok(#(
          200,
          "{\"answers\":{\"falado\":{\"noul\":0.9},\"t1\":{\"noul\":0.9}}}",
        ))
    }
  }
}

fn with_memory(dir: String, body: fn() -> a) -> a {
  runtime.configure(runtime.Settings(
    transport: fake(),
    api_key: "k",
    gate_threshold: 0.1,
    gate_timeout_ms: 2000,
    recall_timeout_ms: 5000,
    charge: runtime.no_charge,
    within_budget: runtime.always_within,
  ))
  agenda_runtime.configure(
    agenda_runtime.Context(data_dir: dir, offset_minutes: -180, clock: fn() {
      base
    }),
  )
  use <- exception.defer(fn() {
    runtime.clear()
    agenda_runtime.clear()
  })
  body()
}

fn names() -> List(String) {
  tool_dispatch.builtin_tools() |> list.map(fn(tool) { tool.name })
}

pub fn offered_only_with_the_memory_on_test() {
  use dir <- with_dir
  names() |> list.contains("lembrar") |> should.be_false()
  use <- with_memory(dir)
  names() |> list.contains("lembrar") |> should.be_true()
}

pub fn the_gateway_recalls_for_the_caller_test() {
  use dir <- with_dir
  use <- with_memory(dir)
  let store = HistoryStore(data_dir: dir, limit: 100)
  let assert Ok(Nil) =
    history_store.append(store, "telegram:111:111", [
      StoredMessage(role: "user", content: "o código é ABACAXI-7781", at: base),
    ])
  let manifests =
    dict.from_list([
      #(
        "member",
        cap_types.CapabilityManifest(
          allowed_tools: ["lembrar"],
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
      fn(_, _) { Error("the raw executor must not run lembrar") },
    )
  let args = "{\"assunto\":\"o código\"}"
  let recall = fn(principal) {
    let assert Ok(reservation) =
      actor.authorize_tool_call(gateway, principal, "member", "lembrar", args)
    let assert Ok(execute) = actor.claim_tool_call(gateway, reservation)
    execute("lembrar", args)
  }
  let assert Ok(found) = recall("telegram:111")
  found |> string.contains("ABACAXI-7781") |> should.be_true()
  recall("telegram:222")
  |> should.equal(Ok(
    "Vocês ainda não têm conversas guardadas além das mensagens que você vê.",
  ))
  lembrar.execute("telegram:111", "{}")
  |> should.equal(Error("Invalid arguments for lembrar: assunto is required"))
}

pub fn members_may_recall_by_default_test() {
  config.default_capabilities_config().member.allowed
  |> list.contains("lembrar")
  |> should.be_true()
}
