//// Tasks: tool calls the agent leaves running in the background (PRD-F,
//// phase B, F-05 to F-07).
////
//// ```
//// turn ──tarefa(iniciar)──► registry ──spawn──► runner ──tool_runner──► tool
////   ◄── "Tarefa 7 iniciada" ──┘                   │
////                              ◄──── outcome ─────┘
//// registry ──deliver──► "[Tarefa] A tarefa 7 … terminou: …" in the chat of origin
//// ```
////
//// - **Owner.** One registry for the instance keeps the runners. A runner
////   is not linked to the turn that started it: the turn answers at once and
////   ends, the task goes on. Killing a runner (cancel, /esquecer) makes the
////   tool_runner guard stop the tool call (PRD-F, I2).
//// - **On disk first (I7).** A task is written before it runs, its outcome
////   before it is delivered, and `delivered` after the delivery is handed
////   to the chat lane. A restart between the outcome and the delivery
////   delivers once at boot; a task that was running is told as interrupted
////   (D6), never run again.
//// - **The person's (I6).** The delivery goes to the chat the task was
////   asked in, with the principal who asked, through the same handler as any
////   message (gate, budget, history), like the agenda.
//// - **Forgetting cancels (I8).** /esquecer kills the person's runners and
////   deletes the file; a delivery already on its way checks the forget epoch
////   and is dropped.
//// - **No budget, no delivery yet (D5).** When the person has no budget,
////   the outcome waits and goes with the person's next message.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import supernova/agenda/schedule
import supernova/channel/port
import supernova/core/agent_identity
import supernova/core/tool_runner
import supernova/metrics/record
import supernova/self/epoch

/// At most this many tasks running at once per agent (D4).
pub const max_running = 7

/// A task's time limit (D4): 30 minutes.
pub const default_limit_ms = 1_800_000

/// How long a task waits for a slot of its tool before giving up.
pub const slot_wait_ms = 60_000

/// The longest reason a task may carry, in characters.
pub const max_reason_length = 200

/// A result delivered in the chat is cut here, like a tool result kept in
/// the conversation (#59).
pub const max_result_chars = 4000

/// Finished tasks kept in the file, besides the running ones.
const kept_finished = 20

/// Tools that may not run in the background (D3): the instant ones, which
/// change local files in milliseconds, and `tarefa` itself.
pub fn may_run_in_background(tool: String) -> Bool {
  !list.contains(["agenda", "file_system", "canvas", "tarefa", "sonda"], tool)
}

/// Where a task was asked for: who asked, as which role, in which chat.
pub type Origin {
  Origin(
    agent_id: String,
    principal: String,
    role: String,
    channel: String,
    channel_id: String,
    user_id: String,
  )
}

pub type Status {
  Running
  Done
  Failed
  TimedOut
  Cancelled
  Interrupted
}

pub type Task {
  Task(
    id: Int,
    tool: String,
    arguments: String,
    reason: String,
    principal: String,
    channel: String,
    channel_id: String,
    user_id: String,
    started_at: Int,
    epoch: Int,
    status: Status,
    result: String,
    delivered: Bool,
  )
}

/// What the registry needs from the rest of Supernova, set at boot.
pub type Context {
  Context(
    data_dir: String,
    offset_minutes: Int,
    clock: fn() -> Int,
    limit_ms: Int,
    /// Hand a message to the chat lane, as the agenda does.
    deliver: fn(port.ChannelMessage) -> Result(Nil, String),
    /// Whether the person has budget for a reply now (D5).
    can_deliver: fn(String) -> Bool,
  )
}

/// Runs one tool call for the task's principal, through the gateway.
pub type Invoke =
  fn(String, String) -> Result(String, String)

// ============================================================================
// The registry
// ============================================================================

pub opaque type Message {
  Begin(
    reply: Subject(Result(Int, String)),
    origin: Origin,
    tool: String,
    arguments: String,
    reason: String,
    invoke: Invoke,
  )
  Listing(reply: Subject(List(Task)), agent_id: String)
  Cancel(reply: Subject(Result(Nil, String)), agent_id: String, id: Int)
  Forget(reply: Subject(Nil), agent_id: String)
  Finished(agent_id: String, id: Int, outcome: tool_runner.Outcome)
  RunnerDown(process.Down)
  Deliver(agent_id: String)
  Delivered(agent_id: String, id: Int)
  DeliveryEnded(agent_id: String, id: Int)
  Recover(reply: Subject(Int))
  Stop(reply: Subject(Nil))
}

type State {
  State(
    context: Context,
    me: Subject(Message),
    /// Runner pid → (agent, task id).
    runners: Dict(Pid, #(String, Int)),
    /// Deliveries handed to a delivering process and not answered yet.
    delivering: List(#(String, Int)),
  )
}

pub type Registry =
  Subject(Message)

const registry_key = "supernova_tasks_registry"

/// Start the registry and publish it for the `tarefa` tool.
pub fn start(context: Context) -> Result(Registry, actor.StartError) {
  actor.new_with_initialiser(5000, fn(me) {
    let selector =
      process.new_selector()
      |> process.select(me)
      |> process.select_monitors(RunnerDown)
    actor.initialised(
      State(context: context, me: me, runners: dict.new(), delivering: []),
    )
    |> actor.selecting(selector)
    |> actor.returning(me)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) {
    global_put(registry_key, started.data)
    started.data
  })
}

/// The running registry, if any.
pub fn registry() -> Option(Registry) {
  case global_has(registry_key) {
    True -> Some(global_get(registry_key))
    False -> None
  }
}

/// Stop the registry and its runners (tests, shutdown).
pub fn stop(running: Registry) -> Nil {
  case registry() {
    Some(current) if current == running -> global_erase(registry_key)
    _ -> Nil
  }
  case process.subject_owner(running) {
    Ok(pid) ->
      case process.is_alive(pid) {
        True -> actor.call(running, waiting: 10_000, sending: Stop)
        False -> Nil
      }
    Error(Nil) -> Nil
  }
}

/// Start `tool` with `arguments` in the background for `origin`. Returns
/// the task id at once.
pub fn begin(
  registry: Registry,
  origin: Origin,
  tool: String,
  arguments: String,
  reason: String,
  invoke: Invoke,
) -> Result(Int, String) {
  actor.call(registry, waiting: 10_000, sending: Begin(
    _,
    origin,
    tool,
    arguments,
    reason,
    invoke,
  ))
}

/// The agent's tasks: running ones and finished ones not yet delivered,
/// newest first.
pub fn list_open(registry: Registry, agent_id: String) -> List(Task) {
  actor.call(registry, waiting: 10_000, sending: Listing(_, agent_id))
}

pub fn cancel(
  registry: Registry,
  agent_id: String,
  id: Int,
) -> Result(Nil, String) {
  actor.call(registry, waiting: 10_000, sending: Cancel(_, agent_id, id))
}

/// /esquecer: stop the agent's tasks and delete what is kept of them.
pub fn forget(agent_id: String) -> Nil {
  case registry() {
    Some(registry) ->
      actor.call(registry, waiting: 10_000, sending: Forget(_, agent_id))
    None -> Nil
  }
}

/// The person wrote: deliver what waited for budget (D5).
pub fn person_active(agent_id: String) -> Nil {
  case registry() {
    Some(registry) -> process.send(registry, Deliver(agent_id))
    None -> Nil
  }
}

/// At boot: tasks that were running are interrupted (D6); every outcome
/// not delivered yet is delivered. Returns how many tasks were interrupted.
pub fn recover(registry: Registry) -> Int {
  actor.call(registry, waiting: 60_000, sending: Recover)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let context = state.context
  case message {
    Begin(reply, origin, tool, arguments, reason, invoke) -> {
      let outcome =
        update(context.data_dir, origin.agent_id, fn(file) {
          let running =
            list.count(file.tasks, fn(task) { task.status == Running })
          case running >= max_running, may_run_in_background(tool) {
            _, False ->
              Error(
                "a ferramenta "
                <> tool
                <> " não roda em segundo plano: chame-a direto",
              )
            True, _ ->
              Error(
                "já há "
                <> int.to_string(max_running)
                <> " tarefas rodando; espere uma terminar ou cancele uma",
              )
            False, True -> {
              let task =
                Task(
                  id: file.next_id,
                  tool: tool,
                  arguments: arguments,
                  reason: string.slice(reason, 0, max_reason_length),
                  principal: origin.principal,
                  channel: origin.channel,
                  channel_id: origin.channel_id,
                  user_id: origin.user_id,
                  started_at: context.clock(),
                  epoch: epoch.current(context.data_dir, origin.agent_id),
                  status: Running,
                  result: "",
                  delivered: False,
                )
              Ok(#(
                TaskFile(next_id: file.next_id + 1, tasks: [task, ..file.tasks]),
                task,
              ))
            }
          }
        })
      case outcome {
        Error(reason) -> {
          actor.send(reply, Error(reason))
          actor.continue(state)
        }
        Ok(task) -> {
          let runner =
            spawn_runner(state.me, origin, task, invoke, context.limit_ms)
          record.count("tasks_total", [#("outcome", "started")])
          actor.send(reply, Ok(task.id))
          actor.continue(
            State(
              ..state,
              runners: dict.insert(state.runners, runner, #(
                origin.agent_id,
                task.id,
              )),
            ),
          )
        }
      }
    }

    Listing(reply, agent_id) -> {
      let open =
        load(context.data_dir, agent_id)
        |> result.map(fn(file) {
          list.filter(file.tasks, fn(task) {
            task.status == Running || !task.delivered
          })
        })
        |> result.unwrap([])
      actor.send(reply, open)
      actor.continue(state)
    }

    Cancel(reply, agent_id, id) -> {
      let changed =
        update(context.data_dir, agent_id, fn(file) {
          case list.find(file.tasks, fn(task) { task.id == id }) {
            Error(Nil) -> Error("não há tarefa " <> int.to_string(id))
            Ok(task) if task.status != Running ->
              Error("a tarefa " <> int.to_string(id) <> " já terminou")
            Ok(_) ->
              Ok(#(
                replace(file, id, fn(task) {
                  Task(..task, status: Cancelled, delivered: True)
                }),
                Nil,
              ))
          }
        })
      case changed {
        Error(reason) -> {
          actor.send(reply, Error(reason))
          actor.continue(state)
        }
        Ok(Nil) -> {
          record.count("tasks_total", [#("outcome", "cancelled")])
          let state = kill_runners(state, fn(key) { key == #(agent_id, id) })
          actor.send(reply, Ok(Nil))
          actor.continue(state)
        }
      }
    }

    Forget(reply, agent_id) -> {
      let state = kill_runners(state, fn(key) { key.0 == agent_id })
      let _ = delete_file(path(context.data_dir, agent_id))
      actor.send(reply, Nil)
      actor.continue(
        State(
          ..state,
          delivering: list.filter(state.delivering, fn(key) {
            key.0 != agent_id
          }),
        ),
      )
    }

    Finished(agent_id, id, outcome) -> {
      let #(status, text) = case outcome {
        tool_runner.Done(Ok(output)) -> #(Done, output)
        tool_runner.Done(Error(reason)) -> #(Failed, reason)
        tool_runner.TimedOut(limit_ms) -> #(
          TimedOut,
          "passou do prazo de " <> describe_ms(limit_ms),
        )
      }
      // A task cancelled or forgotten meanwhile stays as it is.
      let _ =
        update(context.data_dir, agent_id, fn(file) {
          case list.find(file.tasks, fn(task) { task.id == id }) {
            Ok(task) if task.status == Running ->
              Ok(#(
                replace(file, id, fn(task) {
                  Task(..task, status: status, result: text)
                }),
                Nil,
              ))
            _ -> Error("not running")
          }
        })
      record.count("tasks_total", [#("outcome", status_name(status))])
      actor.continue(start_deliveries(state, agent_id))
    }

    RunnerDown(process.ProcessDown(pid: pid, reason: reason, ..)) ->
      case dict.get(state.runners, pid) {
        Error(Nil) -> actor.continue(state)
        Ok(#(agent_id, id)) -> {
          let state = State(..state, runners: dict.delete(state.runners, pid))
          case reason {
            // The runner sent its outcome before it ended.
            process.Normal -> actor.continue(state)
            _ ->
              handle(
                state,
                Finished(
                  agent_id,
                  id,
                  tool_runner.Done(Error("a tarefa parou sem resultado")),
                ),
              )
          }
        }
      }
    RunnerDown(process.PortDown(..)) -> actor.continue(state)

    Deliver(agent_id) -> actor.continue(start_deliveries(state, agent_id))

    Delivered(agent_id, id) -> {
      let _ =
        update(context.data_dir, agent_id, fn(file) {
          Ok(#(
            replace(file, id, fn(task) { Task(..task, delivered: True) }),
            Nil,
          ))
        })
      actor.continue(state)
    }

    DeliveryEnded(agent_id, id) ->
      actor.continue(
        State(
          ..state,
          delivering: list.filter(state.delivering, fn(key) {
            key != #(agent_id, id)
          }),
        ),
      )

    Recover(reply) -> {
      let agents = owners(context.data_dir)
      let interrupted =
        list.fold(agents, 0, fn(count, agent_id) {
          let changed =
            update(context.data_dir, agent_id, fn(file) {
              let running =
                list.count(file.tasks, fn(task) { task.status == Running })
              Ok(#(
                TaskFile(
                  ..file,
                  tasks: list.map(file.tasks, fn(task) {
                    case task.status {
                      Running -> Task(..task, status: Interrupted)
                      _ -> task
                    }
                  }),
                ),
                running,
              ))
            })
          count + result.unwrap(changed, 0)
        })
      let state = list.fold(agents, state, start_deliveries)
      actor.send(reply, interrupted)
      actor.continue(state)
    }

    Stop(reply) -> {
      let state = kill_runners(state, fn(_) { True })
      actor.send(reply, Nil)
      let _ = state
      actor.stop()
    }
  }
}

fn spawn_runner(
  registry: Subject(Message),
  origin: Origin,
  task: Task,
  invoke: Invoke,
  limit_ms: Int,
) -> Pid {
  let pid =
    process.spawn_unlinked(fn() {
      let outcome =
        tool_runner.start_in_slot(
          limit_ms,
          Some(tool_runner.SlotRequest(
            tool: task.tool,
            agent: origin.agent_id,
            wait_ms: slot_wait_ms,
          )),
          fn() { invoke(task.tool, task.arguments) },
        )
        |> tool_runner.await
      process.send(registry, Finished(origin.agent_id, task.id, outcome))
    })
  let _ = process.monitor(pid)
  pid
}

fn kill_runners(state: State, matching: fn(#(String, Int)) -> Bool) -> State {
  let #(killed, kept) =
    dict.to_list(state.runners)
    |> list.partition(fn(entry) { matching(entry.1) })
  list.each(killed, fn(entry) { process.kill(entry.0) })
  State(..state, runners: dict.from_list(kept))
}

/// Hand every outcome of `agent_id` not delivered yet to a delivering
/// process, unless one is already on its way.
fn start_deliveries(state: State, agent_id: String) -> State {
  let context = state.context
  let pending =
    load(context.data_dir, agent_id)
    |> result.map(fn(file) {
      list.filter(file.tasks, fn(task) {
        task.status != Running
        && task.status != Cancelled
        && !task.delivered
        && !list.contains(state.delivering, #(agent_id, task.id))
      })
    })
    |> result.unwrap([])
  list.fold(list.reverse(pending), state, fn(state, task) {
    let me = state.me
    process.spawn_unlinked(fn() {
      case deliver_one(context, agent_id, task) {
        True -> process.send(me, Delivered(agent_id, task.id))
        False -> Nil
      }
      process.send(me, DeliveryEnded(agent_id, task.id))
    })
    State(..state, delivering: [#(agent_id, task.id), ..state.delivering])
  })
}

/// Deliver one outcome. True when it was handed to the chat lane, or when
/// it must never be delivered (the person forgot in between).
fn deliver_one(context: Context, agent_id: String, task: Task) -> Bool {
  case epoch.unchanged(context.data_dir, agent_id, task.epoch) {
    False -> {
      record.count("tasks_delivered_total", [#("outcome", "dropped")])
      True
    }
    True ->
      case context.can_deliver(task.principal) {
        False -> {
          record.count("tasks_delivered_total", [#("outcome", "held")])
          False
        }
        True ->
          case context.deliver(message_for(context, agent_id, task)) {
            Ok(Nil) -> {
              record.count("tasks_delivered_total", [#("outcome", "delivered")])
              True
            }
            Error(reason) -> {
              record.count("tasks_delivered_total", [#("outcome", "failed")])
              let _ = reason
              False
            }
          }
      }
  }
}

/// The message the agent receives when a task ends.
pub fn message_for(
  context: Context,
  agent_id: String,
  task: Task,
) -> port.ChannelMessage {
  port.ChannelMessage(
    id: message_id(agent_id, task.id),
    channel: task.channel,
    channel_id: task.channel_id,
    user_id: task.user_id,
    username: "",
    content: delivery_text(task, context.offset_minutes),
    is_bot: False,
    reply_to_id: None,
  )
}

pub fn message_id(agent_id: String, id: Int) -> String {
  "tarefa:" <> int.to_string(id) <> ":" <> agent_id
}

pub fn delivery_text(task: Task, offset: Int) -> String {
  let head =
    "[Tarefa] A tarefa "
    <> int.to_string(task.id)
    <> " ("
    <> task.reason
    <> "), que você iniciou às "
    <> string.slice(schedule.format_local(task.started_at, offset), 11, 5)
  case task.status {
    Interrupted ->
      head
      <> ", foi interrompida pelo reinício do serviço e não terminou. Ela não"
      <> " é refeita sozinha. Sua pessoa não escreveu agora. Avise a ela."
    Failed ->
      head
      <> ", terminou com erro: "
      <> cut(task.result)
      <> "\nSua pessoa não escreveu agora. Conte a ela o que aconteceu."
    TimedOut ->
      head
      <> ", "
      <> task.result
      <> " e foi interrompida.\nSua pessoa não escreveu agora. Conte a ela o"
      <> " que aconteceu."
    _ ->
      head
      <> ", terminou: "
      <> cut(task.result)
      <> "\nSua pessoa não escreveu agora. Conte a ela o resultado."
  }
}

fn cut(text: String) -> String {
  case string.length(text) > max_result_chars {
    True -> string.slice(text, 0, max_result_chars) <> " …(cortado)"
    False -> text
  }
}

/// The task a delivered message is about, read from its id: the tool call
/// and its result, for the conversation history.
pub fn result_for_message(
  data_dir: String,
  message_id: String,
) -> Option(Task) {
  case string.split_once(message_id, ":") {
    Ok(#("tarefa", rest)) ->
      case string.split_once(rest, ":") {
        Ok(#(number, agent_id)) ->
          case int.parse(number) {
            Ok(id) ->
              load(data_dir, agent_id)
              |> result.map(fn(file) {
                list.find(file.tasks, fn(task) { task.id == id })
                |> option.from_result
              })
              |> result.unwrap(None)
            Error(Nil) -> None
          }
        Error(Nil) -> None
      }
    _ -> None
  }
}

pub fn status_name(status: Status) -> String {
  case status {
    Running -> "running"
    Done -> "done"
    Failed -> "failed"
    TimedOut -> "timeout"
    Cancelled -> "cancelled"
    Interrupted -> "interrupted"
  }
}

fn status_from(name: String) -> Status {
  case name {
    "running" -> Running
    "done" -> Done
    "failed" -> Failed
    "timeout" -> TimedOut
    "cancelled" -> Cancelled
    _ -> Interrupted
  }
}

fn describe_ms(ms: Int) -> String {
  case ms >= 60_000 {
    True -> int.to_string(ms / 60_000) <> " min"
    False -> int.to_string(ms / 1000) <> " s"
  }
}

pub fn declare_metrics() -> Nil {
  list.each(["started", "done", "failed", "timeout", "cancelled"], fn(outcome) {
    record.declare("tasks_total", [#("outcome", outcome)])
  })
  list.each(["delivered", "held", "dropped", "failed"], fn(outcome) {
    record.declare("tasks_delivered_total", [#("outcome", outcome)])
  })
}

// ============================================================================
// Persistence: <self>/tasks.json, under a per-agent lock
// ============================================================================

type TaskFile {
  TaskFile(next_id: Int, tasks: List(Task))
}

pub fn path(data_dir: String, agent_id: String) -> String {
  agent_identity.self_dir(data_dir, agent_id) <> "/tasks.json"
}

fn replace(file: TaskFile, id: Int, change: fn(Task) -> Task) -> TaskFile {
  TaskFile(
    ..file,
    tasks: list.map(file.tasks, fn(task) {
      case task.id == id {
        True -> change(task)
        False -> task
      }
    }),
  )
}

fn update(
  data_dir: String,
  agent_id: String,
  change: fn(TaskFile) -> Result(#(TaskFile, a), String),
) -> Result(a, String) {
  with_lock("tasks:" <> agent_id, fn() {
    use current <- result.try(load(data_dir, agent_id))
    use #(file, value) <- result.try(change(current))
    use _ <- result.try(save(data_dir, agent_id, prune(file)))
    Ok(value)
  })
}

/// Keep the running and undelivered tasks and the last finished ones.
fn prune(file: TaskFile) -> TaskFile {
  let #(open, closed) =
    list.partition(file.tasks, fn(task) {
      task.status == Running || !task.delivered
    })
  TaskFile(..file, tasks: list.append(open, list.take(closed, kept_finished)))
  |> fn(pruned) {
    TaskFile(
      ..pruned,
      tasks: list.sort(pruned.tasks, fn(a, b) { int.compare(b.id, a.id) }),
    )
  }
}

fn load(data_dir: String, agent_id: String) -> Result(TaskFile, String) {
  let file = path(data_dir, agent_id)
  case file_exists(file) {
    Ok(False) -> Ok(TaskFile(next_id: 1, tasks: []))
    Error(reason) -> Error(reason)
    Ok(True) -> {
      use text <- result.try(read_file(file))
      json.parse(text, file_decoder())
      |> result.replace_error("tasks file is damaged: " <> file)
    }
  }
}

fn save(
  data_dir: String,
  agent_id: String,
  file: TaskFile,
) -> Result(Nil, String) {
  let target = path(data_dir, agent_id)
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, agent_id)))
  use _ <- result.try(write_file(target <> ".tmp", encode(file)))
  rename(target <> ".tmp", target)
}

/// Agents that have a tasks file.
fn owners(data_dir: String) -> List(String) {
  list_agent_dirs(data_dir <> "/agents")
  |> list.map(agent_identity.decode_principal)
  |> list.filter(fn(agent_id) {
    file_exists(path(data_dir, agent_id)) == Ok(True)
  })
}

fn encode(file: TaskFile) -> String {
  json.object([
    #("next_id", json.int(file.next_id)),
    #(
      "tasks",
      json.array(file.tasks, fn(task) {
        json.object([
          #("id", json.int(task.id)),
          #("tool", json.string(task.tool)),
          #("arguments", json.string(task.arguments)),
          #("reason", json.string(task.reason)),
          #("principal", json.string(task.principal)),
          #("channel", json.string(task.channel)),
          #("channel_id", json.string(task.channel_id)),
          #("user_id", json.string(task.user_id)),
          #("started_at", json.int(task.started_at)),
          #("epoch", json.int(task.epoch)),
          #("status", json.string(status_name(task.status))),
          #("result", json.string(task.result)),
          #("delivered", json.bool(task.delivered)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn file_decoder() -> decode.Decoder(TaskFile) {
  let task = {
    use id <- decode.field("id", decode.int)
    use tool <- decode.field("tool", decode.string)
    use arguments <- decode.field("arguments", decode.string)
    use reason <- decode.field("reason", decode.string)
    use principal <- decode.field("principal", decode.string)
    use channel <- decode.field("channel", decode.string)
    use channel_id <- decode.field("channel_id", decode.string)
    use user_id <- decode.field("user_id", decode.string)
    use started_at <- decode.field("started_at", decode.int)
    use epoch <- decode.field("epoch", decode.int)
    use status <- decode.field("status", decode.string)
    use result <- decode.field("result", decode.string)
    use delivered <- decode.field("delivered", decode.bool)
    decode.success(Task(
      id:,
      tool:,
      arguments:,
      reason:,
      principal:,
      channel:,
      channel_id:,
      user_id:,
      started_at:,
      epoch:,
      status: status_from(status),
      result:,
      delivered:,
    ))
  }
  use next_id <- decode.field("next_id", decode.int)
  use tasks <- decode.field("tasks", decode.list(task))
  decode.success(TaskFile(next_id:, tasks:))
}

@external(erlang, "supernova_self_ffi", "with_lock")
fn with_lock(key: String, body: fn() -> a) -> a

@external(erlang, "supernova_self_ffi", "list_agent_dirs")
fn list_agent_dirs(path: String) -> List(String)

@external(erlang, "supernova_self_ffi", "rename_file")
fn rename(from: String, to: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_file_system_ffi", "delete_file")
fn delete_file(path: String) -> Result(Nil, String)

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: a) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn global_get(key: String) -> a

@external(erlang, "supernova_global_ffi", "global_has")
fn global_has(key: String) -> Bool

@external(erlang, "supernova_global_ffi", "global_erase")
fn global_erase(key: String) -> Nil
