//// Tasks in the background (PRD-F, phase B): invariants I6 to I8, D4 to D6.
////
//// The tools are the test tools of F-01 (`lenta`, `trava`), run through
//// `tool_dispatch.execute` as the gateway would. Deliveries land on a
//// subject owned by the test.

import exception
import gleam/erlang/process.{type Pid, type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/channel/port
import supernova/core/tool_dispatch
import supernova/self/epoch
import supernova/self/forget
import supernova/self/tasks
import supernova/stress/fake_tools
import supernova/tools/tarefa
import test_workspace

const agent = "telegram:42"

fn origin() -> tasks.Origin {
  tasks.Origin(
    agent_id: agent,
    principal: agent,
    role: "member",
    channel: "telegram",
    channel_id: "-100777",
    user_id: "42",
  )
}

fn invoke(name: String, arguments: String) -> Result(String, String) {
  tool_dispatch.execute(name, arguments)
}

type Env {
  Env(
    dir: String,
    registry: tasks.Registry,
    inbox: Subject(port.ChannelMessage),
    context: tasks.Context,
  )
}

fn context(
  dir: String,
  inbox: Subject(port.ChannelMessage),
  limit_ms: Int,
) -> tasks.Context {
  tasks.Context(
    data_dir: dir,
    offset_minutes: -180,
    clock: fn() { 1_795_273_200_000 },
    limit_ms: limit_ms,
    deliver: fn(message) {
      process.send(inbox, message)
      Ok(Nil)
    },
    can_deliver: fn(_) { !budget_blocked(dir) },
  )
}

fn with_env(limit_ms: Int, body: fn(Env) -> a) -> a {
  fake_tools.enable()
  let dir = test_workspace.create_temp_dir("tasks")
  let inbox = process.new_subject()
  let context = context(dir, inbox, limit_ms)
  let assert Ok(registry) = tasks.start(context)
  use <- exception.defer(fn() {
    tasks.stop(registry)
    fake_tools.disable()
    test_workspace.remove_dir_recursive(dir)
  })
  body(Env(dir, registry, inbox, context))
}

fn start(env: Env, tool: String, ms: Int, reason: String) -> Int {
  let assert Ok(id) =
    tasks.begin(env.registry, origin(), tool, ms_args(ms), reason, invoke)
  id
}

fn ms_args(ms: Int) -> String {
  json.to_string(json.object([#("ms", json.int(ms))]))
}

/// F-05: starting returns at once; the result comes later, in the chat of
/// origin, with the principal who asked (I6).
pub fn a_task_answers_at_once_and_delivers_later_test() {
  use env <- with_env(5000)
  let begun = now()
  let id = start(env, "lenta", 300, "levantamento")
  { now() - begun < 200 } |> should.be_true
  process.receive(env.inbox, 100) |> should.be_error
  let assert Ok(message) = process.receive(env.inbox, 3000)
  message.channel |> should.equal("telegram")
  message.channel_id |> should.equal("-100777")
  message.user_id |> should.equal("42")
  message.id |> should.equal(tasks.message_id(agent, id))
  string.starts_with(message.content, "[Tarefa] A tarefa 1 (levantamento)")
  |> should.be_true
  string.contains(message.content, "terminou: lenta: 300 ms") |> should.be_true
  string.contains(message.content, "às 12:00") |> should.be_true
  // Delivered once (I7).
  process.receive(env.inbox, 300) |> should.be_error
}

/// D4: an eighth task at once is refused with a clear message.
pub fn an_eighth_task_is_refused_test() {
  use env <- with_env(5000)
  list.each([1, 2, 3, 4, 5, 6, 7], fn(_) { start(env, "trava", 0, "parada") })
  let assert Error(reason) =
    tasks.begin(env.registry, origin(), "trava", "{}", "oitava", invoke)
  string.contains(reason, "7 tarefas rodando") |> should.be_true
}

/// D3: the instant tools do not run in the background.
pub fn instant_tools_are_refused_test() {
  use env <- with_env(5000)
  list.each(["agenda", "file_system", "canvas", "tarefa"], fn(tool) {
    let assert Error(reason) =
      tasks.begin(env.registry, origin(), tool, "{}", "x", invoke)
    string.contains(reason, "não roda em segundo plano") |> should.be_true
  })
}

/// I2 of phase A, for tasks: cancelling stops the tool call, and nothing is
/// delivered.
pub fn cancel_kills_the_call_and_delivers_nothing_test() {
  use env <- with_env(5000)
  let started = process.new_subject()
  fake_tools.observe(started)
  let id = start(env, "trava", 0, "parada")
  let assert Ok(call) = process.receive(started, 2000)
  tasks.cancel(env.registry, agent, id) |> should.equal(Ok(Nil))
  wait_dead(call, 1000) |> should.be_true
  process.receive(env.inbox, 300) |> should.be_error
  tasks.list_open(env.registry, agent) |> should.equal([])
  tasks.cancel(env.registry, agent, id) |> should.be_error
}

/// The time limit of a task (D4) ends it, and the agent is told.
pub fn a_stuck_task_ends_at_its_limit_test() {
  use env <- with_env(300)
  let _ = start(env, "trava", 0, "parada")
  let assert Ok(message) = process.receive(env.inbox, 3000)
  string.contains(message.content, "passou do prazo") |> should.be_true
}

/// I8: after /esquecer no task of the person runs, nothing of it is
/// delivered, and the file is gone.
pub fn forget_cancels_and_drops_test() {
  use env <- with_env(5000)
  let started = process.new_subject()
  fake_tools.observe(started)
  let _ = start(env, "trava", 0, "parada")
  let assert Ok(call) = process.receive(started, 2000)
  tasks.forget(agent)
  wait_dead(call, 1000) |> should.be_true
  process.receive(env.inbox, 300) |> should.be_error
  file_exists(tasks.path(env.dir, agent)) |> should.equal(Ok(False))
}

/// I8 through /esquecer itself: the running call dies and the file goes.
pub fn esquecer_stops_the_tasks_test() {
  use env <- with_env(5000)
  let started = process.new_subject()
  fake_tools.observe(started)
  let _ = start(env, "trava", 0, "parada")
  let assert Ok(call) = process.receive(started, 2000)
  let assert Ok(_) = forget.forget(env.dir, agent, None)
  wait_dead(call, 1000) |> should.be_true
  file_exists(tasks.path(env.dir, agent)) |> should.equal(Ok(False))
  process.receive(env.inbox, 300) |> should.be_error
}

/// I8 with a delivery already on its way: the forget epoch drops it.
pub fn forget_drops_a_result_on_its_way_test() {
  use env <- with_env(5000)
  set_budget_blocked(env.dir, True)
  let _ = start(env, "lenta", 10, "rapida")
  // Finished and held for budget.
  wait_until(fn() { tasks.list_open(env.registry, agent) |> is_finished })
  let assert Ok(_) = epoch.bump(env.dir, agent)
  set_budget_blocked(env.dir, False)
  tasks.person_active(agent)
  process.receive(env.inbox, 500) |> should.be_error
}

/// D5: without budget the result waits, and goes with the person's next
/// message.
pub fn no_budget_holds_until_the_person_writes_test() {
  use env <- with_env(5000)
  set_budget_blocked(env.dir, True)
  let _ = start(env, "lenta", 10, "rapida")
  wait_until(fn() { tasks.list_open(env.registry, agent) |> is_finished })
  process.receive(env.inbox, 300) |> should.be_error
  set_budget_blocked(env.dir, False)
  tasks.person_active(agent)
  let assert Ok(message) = process.receive(env.inbox, 2000)
  string.contains(message.content, "lenta: 10 ms") |> should.be_true
  tasks.person_active(agent)
  process.receive(env.inbox, 300) |> should.be_error
}

/// I7: a restart between the result and the delivery delivers once.
pub fn restart_between_result_and_delivery_delivers_once_test() {
  use env <- with_env(5000)
  set_budget_blocked(env.dir, True)
  let _ = start(env, "lenta", 10, "rapida")
  wait_until(fn() { tasks.list_open(env.registry, agent) |> is_finished })
  tasks.stop(env.registry)
  set_budget_blocked(env.dir, False)
  let assert Ok(again) = tasks.start(env.context)
  use <- exception.defer(fn() { tasks.stop(again) })
  tasks.recover(again) |> should.equal(0)
  let assert Ok(message) = process.receive(env.inbox, 2000)
  string.contains(message.content, "lenta: 10 ms") |> should.be_true
  tasks.recover(again) |> should.equal(0)
  process.receive(env.inbox, 300) |> should.be_error
}

/// D6: a task running at a restart is told as interrupted, not run again.
pub fn restart_tells_running_tasks_as_interrupted_test() {
  use env <- with_env(5000)
  let started = process.new_subject()
  fake_tools.observe(started)
  let _ = start(env, "trava", 0, "parada")
  let assert Ok(_) = process.receive(started, 2000)
  tasks.stop(env.registry)
  let assert Ok(again) = tasks.start(env.context)
  use <- exception.defer(fn() { tasks.stop(again) })
  tasks.recover(again) |> should.equal(1)
  let assert Ok(message) = process.receive(env.inbox, 2000)
  string.contains(message.content, "interrompida pelo reinício")
  |> should.be_true
  process.receive(started, 300) |> should.be_error
}

/// The delivered message leads back to the task, for the history.
pub fn the_message_leads_back_to_the_task_test() {
  use env <- with_env(5000)
  let id = start(env, "lenta", 10, "rapida")
  let assert Ok(message) = process.receive(env.inbox, 2000)
  let assert Some(task) = tasks.result_for_message(env.dir, message.id)
  task.id |> should.equal(id)
  task.tool |> should.equal("lenta")
  task.result |> should.equal("lenta: 10 ms")
  tasks.result_for_message(env.dir, "agenda:1:2") |> should.equal(None)
}

/// The tool: iniciar, listar and cancelar, with arguments as an object or
/// as a string.
pub fn the_tarefa_tool_test() {
  use _env <- with_env(5000)
  let assert Ok(started) =
    tarefa.execute(
      origin(),
      "{\"acao\":\"iniciar\",\"ferramenta\":\"trava\",\"argumentos\":{\"ms\":0},\"motivo\":\"teste\"}",
      invoke,
    )
  string.starts_with(started, "Tarefa 1 iniciada") |> should.be_true
  let assert Ok(_) =
    tarefa.execute(
      origin(),
      "{\"acao\":\"iniciar\",\"ferramenta\":\"trava\",\"argumentos\":\"{\\\"ms\\\":0}\"}",
      invoke,
    )
  let assert Ok(listing) =
    tarefa.execute(origin(), "{\"acao\":\"listar\"}", invoke)
  string.contains(listing, "1 (teste, trava): rodando") |> should.be_true
  string.contains(listing, "2 (trava, trava): rodando") |> should.be_true
  tarefa.execute(origin(), "{\"acao\":\"cancelar\",\"id\":1}", invoke)
  |> should.equal(Ok("Tarefa 1 cancelada."))
  tarefa.execute(origin(), "{\"acao\":\"cancelar\"}", invoke) |> should.be_error
  tarefa.execute(origin(), "{\"acao\":\"iniciar\"}", invoke) |> should.be_error
  tarefa.execute(
    origin(),
    "{\"acao\":\"iniciar\",\"ferramenta\":\"trava\",\"argumentos\":\"nada\"}",
    invoke,
  )
  |> should.be_error
  tarefa.execute(origin(), "{\"acao\":\"voar\"}", invoke) |> should.be_error
  tarefa.execute(origin(), "nada", invoke) |> should.be_error
}

/// Without a registry the tool says so.
pub fn the_tool_without_registry_test() {
  tarefa.execute(origin(), "{\"acao\":\"listar\"}", invoke)
  |> should.equal(Error("tarefas indisponíveis agora"))
}

pub fn delivery_texts_test() {
  let task =
    tasks.Task(
      id: 3,
      tool: "web",
      arguments: "{}",
      reason: "preço",
      principal: agent,
      channel: "telegram",
      channel_id: "42",
      user_id: "42",
      started_at: 1_795_273_200_000,
      epoch: 0,
      status: tasks.Failed,
      result: "sem rede",
      delivered: False,
    )
  tasks.delivery_text(task, -180)
  |> string.contains("terminou com erro: sem rede")
  |> should.be_true
  tasks.delivery_text(
    tasks.Task(..task, status: tasks.Done, result: string.repeat("a", 5000)),
    -180,
  )
  |> string.contains("…(cortado)")
  |> should.be_true
  list.map(
    [
      tasks.Running,
      tasks.Done,
      tasks.Failed,
      tasks.TimedOut,
      tasks.Cancelled,
      tasks.Interrupted,
    ],
    tasks.status_name,
  )
  |> should.equal([
    "running", "done", "failed", "timeout", "cancelled", "interrupted",
  ])
}

fn is_finished(open: List(tasks.Task)) -> Bool {
  case open {
    [task] -> task.status == tasks.Done
    _ -> False
  }
}

fn wait_until(condition: fn() -> Bool) -> Nil {
  wait_until_within(condition, 3000)
}

fn wait_until_within(condition: fn() -> Bool, within: Int) -> Nil {
  case condition(), within <= 0 {
    True, _ -> Nil
    False, True -> panic as "condition not reached"
    False, False -> {
      process.sleep(10)
      wait_until_within(condition, within - 10)
    }
  }
}

fn wait_dead(pid: Pid, within: Int) -> Bool {
  case process.is_alive(pid), within <= 0 {
    False, _ -> True
    True, True -> False
    True, False -> {
      process.sleep(10)
      wait_dead(pid, within - 10)
    }
  }
}

fn budget_blocked(dir: String) -> Bool {
  file_exists(dir <> "/no-budget") == Ok(True)
}

fn set_budget_blocked(dir: String, blocked: Bool) -> Nil {
  let _ = case blocked {
    True -> write_file(dir <> "/no-budget", "1")
    False -> delete_file(dir <> "/no-budget")
  }
  Nil
}

fn now() -> Int {
  monotonic()
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn monotonic() -> Int

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn delete_file(path: String) -> Result(Nil, String)
