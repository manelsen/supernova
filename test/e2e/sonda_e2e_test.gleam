//// PRD-S, S-07: a probe through the real pipeline (closed group, gateway,
//// router, executor, mock LLM), against a fake computer. The person asks;
//// the agent sends a web probe and answers at once; the conductor runs in
//// the background with the computer's browser tools and `buscar`; the
//// report arrives as "[Sonda web #1] …"; the whole result is kept in the
//// probe's folder and the session is closed.

import e2e/e2e_support as support
import envoy
import exception
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
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
import supernova/core/session/supervisor as session_supervisor
import supernova/core/syscall/actor as syscall_actor
import supernova/core/tool_dispatch
import supernova/llm/provider
import supernova/self/tasks
import test_budget

type Fake

@external(erlang, "mcp_computer_fake_ffi", "start")
fn start_fake(responder: fn(String) -> #(Int, String)) -> Fake

@external(erlang, "mcp_computer_fake_ffi", "requests")
fn requests(fake: Fake) -> List(String)

@external(erlang, "mcp_computer_fake_ffi", "stop")
fn stop(fake: Fake) -> Nil

@external(erlang, "erlang", "element")
fn port_of(index: Int, fake: Fake) -> Int

fn computer(body: String) -> #(Int, String) {
  let action = json.parse(body, decode.at(["acao"], decode.string))
  let method =
    json.parse(body, decode.at(["mensagem", "method"], decode.string))
  let id = json.parse(body, decode.at(["mensagem", "id"], decode.int))
  case action, method, id {
    Ok("chamar"), Ok("initialize"), Ok(id) ->
      answer(id, "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{}}")
    Ok("chamar"), Ok("tools/list"), Ok(id) ->
      answer(
        id,
        "{\"tools\":[{\"name\":\"browser_navigate\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}}}}]}",
      )
    Ok("chamar"), Ok("tools/call"), Ok(id) ->
      answer(id, "{\"content\":[{\"type\":\"text\",\"text\":\"página\"}]}")
    Ok(_), _, _ -> #(200, "{\"ok\":true}")
    _, _, _ -> #(400, "{\"ok\":false,\"error\":\"bad\"}")
  }
}

fn answer(id: Int, result: String) -> #(Int, String) {
  #(
    200,
    "{\"ok\":true,\"resposta\":{\"jsonrpc\":\"2.0\",\"id\":"
      <> int.to_string(id)
      <> ",\"result\":"
      <> result
      <> "}}",
  )
}

fn cfg() -> config.Config {
  config.Config(
    ..support.channel_config(),
    access: config.AccessConfig(
      ..support.access_config([], ["sim:carol"]),
      allowed_chats: ["sim:carol"],
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

pub fn a_member_sends_a_web_probe_test() {
  let fake = start_fake(computer)
  use <- exception.defer(fn() { stop(fake) })
  envoy.set(
    "SUPERNOVA_COMPUTER_URL",
    "http://127.0.0.1:" <> int.to_string(port_of(1, fake)),
  )
  envoy.set("SUPERNOVA_COMPUTER_TOKEN", "token-do-computador")
  envoy.set("SUPERNOVA_SEARXNG_URL", "http://127.0.0.1:1")
  use <- exception.defer(fn() {
    envoy.unset("SUPERNOVA_COMPUTER_URL")
    envoy.unset("SUPERNOVA_COMPUTER_TOKEN")
    envoy.unset("SUPERNOVA_SEARXNG_URL")
  })
  support.with_runtime_root(cfg(), fn(root) {
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
          limit_ms: 60_000,
          deliver: fn(delivered) {
            process.send(deliveries, delivered)
            Ok(Nil)
          },
          can_deliver: fn(_) { True },
        ),
      )
    use <- exception.defer(fn() { tasks.stop(registry) })
    let assert Ok(sessions) = session_supervisor.start()
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
    let _ = route(router, message("m1", "oi"))
    let _ = route(router, message("m2", "Lua"))
    let _ = route(router, message("m3", "sim"))

    // A member may not send the code probe.
    route(router, message("m4", "[mock-sonda codigo rode os testes]"))
    |> should.equal("Mock tool error")
    process.receive(deliveries, 300) |> should.be_error

    // The web probe answers now; the report comes later.
    route(router, message("m5", "[mock-sonda web procure o que é Gleam]"))
    |> should.equal("Mock response")
    let assert Ok(delivered) = process.receive(deliveries, 10_000)
    delivered.channel_id |> should.equal("carol")
    string.starts_with(delivered.content, "[Sonda web #1] concluída:")
    |> should.be_true
    string.contains(
      delivered.content,
      "Pasta no computador: /home/pwuser/pessoas/",
    )
    |> should.be_true

    // In the computer: a session opened and closed, the result kept, and
    // nothing of Supernova's secrets or the person's id.
    let sent = requests(fake)
    let has = fn(text) {
      list.any(sent, fn(raw) { string.contains(raw, text) })
    }
    has("\"servidor\":\"playwright\"") |> should.be_true
    has("\"acao\":\"guardar_resultado\"") |> should.be_true
    has("\"acao\":\"fechar\"") |> should.be_true
    has("sim:carol") |> should.be_false
    has("procure o que é Gleam") |> should.be_false
  })
}
