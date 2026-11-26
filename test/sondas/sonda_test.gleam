//// PRD-S, S-07: the `sonda` tool's checks, the probe's delivery text, the
//// web probes' slots, and the hands of the disk and code probes.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/mcp/computer
import supernova/core/executor
import supernova/core/tool_slots
import supernova/llm/provider
import supernova/self/tasks
import supernova/sondas/condutor
import supernova/sondas/maos
import supernova/sondas/sonda
import test_workspace

type Fake

@external(erlang, "mcp_computer_fake_ffi", "start")
fn start_fake(responder: fn(String) -> #(Int, String)) -> Fake

@external(erlang, "mcp_computer_fake_ffi", "requests")
fn requests(fake: Fake) -> List(String)

@external(erlang, "mcp_computer_fake_ffi", "stop")
fn stop(fake: Fake) -> Nil

@external(erlang, "erlang", "element")
fn port_of(index: Int, fake: Fake) -> Int

fn fake_computer(body: String) -> #(Int, String) {
  let method =
    json.parse(body, decode.at(["mensagem", "method"], decode.string))
  let id = json.parse(body, decode.at(["mensagem", "id"], decode.int))
  case method, id {
    Ok("initialize"), Ok(id) ->
      answer(id, "{\"protocolVersion\":\"2025-11-25\"}")
    Ok("tools/list"), Ok(id) ->
      answer(id, "{\"tools\":[{\"name\":\"read_text_file\"}]}")
    _, _ -> #(200, "{\"ok\":true}")
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

fn pc(fake: Fake) -> computer.Computer {
  computer.Computer(
    url: "http://127.0.0.1:" <> int.to_string(port_of(1, fake)),
    token: "",
    timeout_ms: 5000,
  )
}

fn origin() -> tasks.Origin {
  tasks.Origin(
    agent_id: "sim:ana",
    principal: "sim:ana",
    role: "member",
    channel: "sim",
    channel_id: "ana",
    user_id: "ana",
  )
}

fn env(
  computer: option.Option(computer.Computer),
  may_code: Bool,
) -> sonda.Env {
  sonda.Env(
    llm_config: provider.ProviderConfig(
      name: "mock",
      api_key: None,
      base_url: None,
      default_model: "mock-model",
    ),
    base: executor.empty_run_context(),
    gateway: fn(_, _) { Ok("ok") },
    may_code: may_code,
    costing: condutor.Costing(
      cost: fn(_, _, _) { 0.0 },
      reserve_output_tokens: 0,
    ),
    computer: computer,
  )
}

pub fn the_tool_checks_its_arguments_test() {
  let dir = test_workspace.create_temp_dir("sonda")
  let assert Ok(registry) =
    tasks.start(
      tasks.Context(
        data_dir: dir,
        offset_minutes: 0,
        clock: fn() { 0 },
        limit_ms: 1000,
        deliver: fn(_) { Ok(Nil) },
        can_deliver: fn(_) { True },
      ),
    )
  let some_pc =
    Some(computer.Computer(
      url: "http://127.0.0.1:1",
      token: "",
      timeout_ms: 100,
    ))
  let run = fn(args, may_code) {
    sonda.execute(origin(), args, env(some_pc, may_code))
  }
  run("{}", False) |> should.be_error
  let assert Error(reason) =
    run("{\"tipo\":\"shell\",\"instrucoes\":\"x\"}", False)
  string.contains(reason, "desconhecido") |> should.be_true
  run("{\"tipo\":\"web\",\"instrucoes\":\"  \"}", False) |> should.be_error
  let assert Error(reason) =
    run("{\"tipo\":\"codigo\",\"instrucoes\":\"x\"}", False)
  string.contains(reason, "precisa do computador") |> should.be_true
  let long =
    "{\"tipo\":\"web\",\"instrucoes\":\"" <> string.repeat("a", 2001) <> "\"}"
  let assert Error(reason) = run(long, False)
  string.contains(reason, "2000") |> should.be_true
  sonda.execute(
    origin(),
    "{\"tipo\":\"web\",\"instrucoes\":\"x\"}",
    env(None, False),
  )
  |> should.be_error
  // A valid probe is accepted at once; it fails later, with no computer.
  let assert Ok(started) =
    run("{\"tipo\":\"disco\",\"instrucoes\":\"organize\"}", False)
  string.starts_with(started, "Sonda disco #1 disparada (prazo de 2 min")
  |> should.be_true
  tasks.stop(registry)
  sonda.execute(
    origin(),
    "{\"tipo\":\"web\",\"instrucoes\":\"x\"}",
    env(some_pc, False),
  )
  |> should.equal(Error("sondas indisponíveis agora"))
  test_workspace.remove_dir_recursive(dir)
}

pub fn the_tool_shows_code_only_to_who_has_the_computer_test() {
  string.contains(sonda.tool(False).description, "codigo") |> should.be_false
  string.contains(sonda.tool(True).description, "codigo writes")
  |> should.be_true
}

pub fn the_delivery_of_a_probe_test() {
  let task =
    tasks.Task(
      id: 4,
      tool: "sonda_web",
      arguments: "{}",
      reason: "preço",
      principal: "sim:ana",
      channel: "sim",
      channel_id: "ana",
      user_id: "ana",
      started_at: 0,
      epoch: 0,
      status: tasks.Done,
      result: "concluída: achei",
      delivered: False,
    )
  tasks.delivery_text(task, 0)
  |> string.starts_with("[Sonda web #4] concluída: achei")
  |> should.be_true
  tasks.delivery_text(tasks.Task(..task, status: tasks.Failed, result: "x"), 0)
  |> string.starts_with("[Sonda web #4] falhou: x")
  |> should.be_true
  tasks.delivery_text(
    tasks.Task(
      ..task,
      status: tasks.TimedOut,
      result: "passou do prazo de 30 min",
    ),
    0,
  )
  |> string.contains("prazo esgotado")
  |> should.be_true
  tasks.delivery_text(tasks.Task(..task, status: tasks.Interrupted), 0)
  |> string.contains("interrompida pelo reinício")
  |> should.be_true
}

/// S23: five web probes at once in the instance.
pub fn web_probes_share_five_slots_test() {
  tool_slots.limits_for("sonda_web") |> should.equal(tool_slots.Limits(7, 5))
}

pub fn disk_hands_use_the_file_server_test() {
  let fake = start_fake(fake_computer)
  let assert Ok(hands) =
    maos.open(pc(fake), condutor.Disk, "sim:ana", 2, fn(_, _) { Ok("") })
  hands.tools
  |> list.map(fn(tool) { tool.name })
  |> should.equal(["read_text_file"])
  hands.folder |> should.equal(computer.probe_folder("sim:ana", 2))
  hands.keep("tudo")
  hands.close()
  let sent = requests(fake)
  list.any(sent, fn(raw) { string.contains(raw, "\"servidor\":\"filesystem\"") })
  |> should.be_true
  list.any(sent, fn(raw) { string.contains(raw, "\"texto\":\"tudo\"") })
  |> should.be_true
  stop(fake)
}

/// The code probe's computer goes through the gateway, with the person's
/// role; nothing else runs.
pub fn code_hands_go_through_the_gateway_test() {
  let calls = process.new_subject()
  let assert Ok(hands) =
    maos.open(
      computer.Computer(url: "http://127.0.0.1:1", token: "", timeout_ms: 100),
      condutor.Code,
      "sim:ana",
      3,
      fn(name, _) {
        process.send(calls, name)
        Ok("saída")
      },
    )
  hands.tools
  |> list.map(fn(tool) { tool.name })
  |> should.equal(["computador"])
  hands.invoke("computador", "{}") |> should.equal(Ok("saída"))
  hands.invoke("safe_shell", "{}") |> should.be_error
  process.receive(calls, 0) |> should.equal(Ok("computador"))
  process.receive(calls, 0) |> should.be_error
}

/// S-I5: a conductor killed at its limit still closes its session.
pub fn a_killed_conductor_closes_its_session_test() {
  let fake = start_fake(fake_computer)
  let opened = process.new_subject()
  let conductor =
    process.spawn_unlinked(fn() {
      let assert Ok(_) =
        maos.open(pc(fake), condutor.Disk, "sim:ana", 5, fn(_, _) { Ok("") })
      process.send(opened, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(opened, 5000)
  process.kill(conductor)
  wait_for(fn() {
    requests(fake)
    |> list.any(fn(raw) { string.contains(raw, "\"acao\":\"fechar\"") })
  })
  stop(fake)
}

fn wait_for(condition: fn() -> Bool) -> Nil {
  wait_within(condition, 3000)
}

fn wait_within(condition: fn() -> Bool, left: Int) -> Nil {
  case condition(), left <= 0 {
    True, _ -> Nil
    False, True -> panic as "never happened"
    False, False -> {
      process.sleep(20)
      wait_within(condition, left - 20)
    }
  }
}
