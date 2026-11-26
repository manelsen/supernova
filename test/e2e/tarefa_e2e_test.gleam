//// PRD-F, F-06: a task through the real pipeline (closed group, gateway,
//// router, executor, mock LLM). The person asks; the agent starts a task
//// and answers at once; the result arrives later as a "[Tarefa]" message,
//// the agent answers it, and the history keeps the result as the tool call
//// it was.

import e2e/e2e_support as support
import exception
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/sim_router
import supernova/channel/port
import supernova/config
import supernova/core/access/types as access_types
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/pure as cg_pure
import supernova/core/session/history_store
import supernova/core/session/supervisor as session_supervisor
import supernova/core/syscall/actor as syscall_actor
import supernova/core/tool_dispatch
import supernova/llm/provider
import supernova/self/tasks
import supernova/stress/fake_tools
import test_budget

fn cfg() -> config.Config {
  let base = support.channel_config()
  config.Config(
    ..base,
    access: config.AccessConfig(
      ..support.access_config([], ["sim:carol"]),
      allowed_chats: ["sim:carol"],
    ),
    capabilities: config.CapabilitiesConfig(
      ..base.capabilities,
      member: config.RoleCapabilitiesConfig(
        ..base.capabilities.member,
        allowed: list.append(base.capabilities.member.allowed, fake_tools.names),
      ),
    ),
  )
}

fn message(id: String, content: String) -> port.ChannelMessage {
  port.ChannelMessage(
    id: id,
    channel: "sim",
    channel_id: "carol",
    user_id: "carol",
    username: "carol",
    content: content,
    is_bot: False,
    reply_to_id: None,
  )
}

fn route(router: sim_router.SimRouter, message: port.ChannelMessage) -> String {
  let events = process.new_subject()
  case
    sim_router.route_inbound_for_handler(
      router,
      port.InboundMessage(message),
      events,
    )
  {
    Ok(port.ImmediateReply(reply)) -> reply.content
    Ok(port.StreamReply(_)) -> await_stream(events)
    other -> "UNEXPECTED " <> string.inspect(other)
  }
}

fn await_stream(events: process.Subject(port.ChannelStreamEvent)) -> String {
  case process.receive(events, 5000) {
    Ok(port.StreamComplete(reply)) -> reply.content
    Ok(port.StreamUpdate(_)) -> await_stream(events)
    Ok(port.StreamFailure(_)) | Error(_) -> ""
  }
}

pub fn a_task_answers_now_and_its_result_comes_later_test() {
  support.with_runtime_root(cfg(), fn(root) {
    fake_tools.enable()
    use <- exception.defer(fake_tools.disable)
    let assert Ok(gateway) =
      syscall_actor.start_with_capabilities(
        None,
        Some(test_budget.unlimited()),
        None,
        dict.from_list([
          #(
            "member",
            cg_pure.manifest_for(cfg().capabilities, access_types.Member),
          ),
        ]),
        tool_dispatch.execute,
      )
    closed_group_global.set_gateway(gateway)
    let deliveries = process.new_subject()
    let assert Ok(registry) =
      tasks.start(
        tasks.Context(
          data_dir: root,
          offset_minutes: -180,
          clock: fn() { 1_795_273_200_000 },
          limit_ms: 5000,
          deliver: fn(delivered) {
            process.send(deliveries, delivered)
            Ok(Nil)
          },
          can_deliver: fn(_) { True },
        ),
      )
    use <- exception.defer(fn() { tasks.stop(registry) })
    let store = history_store.HistoryStore(data_dir: root, limit: 40)
    let assert Ok(sessions) = session_supervisor.start_with_history(store)
    use <- exception.defer(fn() { session_supervisor.stop(sessions) })
    let assert Ok(router) =
      sim_router.start_with_session_supervisor(
        sessions,
        provider.ProviderConfig(
          name: "mock",
          api_key: None,
          base_url: None,
          default_model: "mock-model",
        ),
      )
    // Born and named first.
    let _ = route(router, message("m1", "oi"))
    let _ = route(router, message("m2", "Lua"))
    let _ = route(router, message("m3", "sim"))

    // The turn starts the task and answers without waiting for it.
    let started = now()
    route(router, message("m4", "[mock-tarefa lenta 400] faça o levantamento"))
    |> should.equal("Mock response")
    { now() - started < 400 } |> should.be_true
    process.receive(deliveries, 0) |> should.be_error

    // The result arrives later, as a message in the same chat.
    let assert Ok(delivered) = process.receive(deliveries, 5000)
    delivered.channel |> should.equal("sim")
    delivered.channel_id |> should.equal("carol")
    string.contains(delivered.content, "terminou: lenta: 400 ms")
    |> should.be_true

    // The agent answers it, and the history keeps the call and its result.
    let _ = route(router, delivered)
    let said = history_store.load(store, "sim:carol:carol")
    said
    |> list.any(fn(stored) {
      stored.role == "tool" && stored.content == "lenta: 400 ms"
    })
    |> should.be_true
    said
    |> list.any(fn(stored) {
      stored.role == "tool_call" && string.contains(stored.content, "lenta")
    })
    |> should.be_true
  })
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now() -> Int
