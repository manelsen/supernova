//// Scenario engine: creates a disposable world, drives personas over the sim
//// HTTP channel and records everything for the checks and the judge.

import envoy
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import supernova
import supernova/channel/session
import supernova/config
import supernova/core/prompt_log
import supernova/core/session/history_store
import supernova/core/session/supervisor
import supernova/harness/clock
import supernova/harness/scenario
import supernova/harness/sim_client
import supernova/harness/transcript
import supernova/llm/provider
import supernova/self/reflection
import supernova/self/tasks
import supernova/self/template as prompt_template

/// Generate the next persona message from the rendered system prompt and the
/// transcript of the chat as this persona sees it. Cost is in USD.
/// Simulated time between two messages of a persona.
pub const message_gap_ms = 20_000

/// The user turn sent to the persona model.
pub const persona_instruction = "Escreva agora a sua próxima mensagem."

pub type PersonaDriver =
  fn(String, String) -> Result(#(String, Float), String)

pub type Input {
  Input(
    root: String,
    data_dir: String,
    transcript_path: String,
    agent: provider.ProviderConfig,
    agent_provider_name: String,
    persona: PersonaDriver,
    turn_timeout_seconds: Int,
    start_ms: Int,
    instance_daily_usd: Float,
    member_daily_usd: Float,
    every_turns: Int,
  )
}

pub type Output {
  Output(
    events: List(transcript.Event),
    transcript_path: String,
    prompts: List(prompt_log.PromptRecord),
    persona_cost_usd: Float,
  )
}

type State {
  State(
    clock: clock.Clock,
    data_dir: String,
    events: List(transcript.Event),
    seq_by_chat: dict.Dict(String, Int),
    step: Int,
    persona_cost: Float,
    sessions: supervisor.SessionSupervisor,
    /// Tasks a `wait_tasks` step already reported ("agent:id").
    tasks_seen: List(String),
  )
}

pub fn run(input: Input, loaded: scenario.Loaded) -> Result(Output, String) {
  use _ <- result.try(prepare_data_dir(input.data_dir))
  use _ <- result.try(ensure_dir(input.data_dir))
  let port = free_port()
  let token = random_token()
  use cfg <- result.try(build_config(input, loaded, port, token))
  use clock <- result.try(
    clock.start(input.start_ms)
    |> result.map_error(fn(_) { "cannot start harness clock" }),
  )
  use runtime <- result.try(
    supernova.boot(cfg, clock.as_fn(clock))
    |> result.map_error(fn(reason) { "harness boot failed: " <> reason }),
  )
  let initial =
    State(
      clock: clock,
      data_dir: input.data_dir,
      events: [],
      seq_by_chat: dict.new(),
      step: 0,
      persona_cost: 0.0,
      sessions: runtime.session_supervisor,
      tasks_seen: [],
    )
  let played = play(input, loaded, port, token, initial)
  clock.stop(clock)
  supernova.shutdown(runtime)
  use state <- result.try(played)
  let transcript_path = input.transcript_path
  let prompt_lines = prompt_log.read_all(input.data_dir)
  let body =
    state.events
    |> list.map(transcript.encode)
    |> list.append(prompt_lines)
    |> string.join("\n")
  use _ <- result.try(write_file(transcript_path, body <> "\n"))
  Ok(Output(
    events: state.events,
    transcript_path: transcript_path,
    prompts: list.filter_map(prompt_lines, fn(line) {
      case prompt_log.decode_line(line) {
        Some(record) -> Ok(record)
        None -> Error(Nil)
      }
    }),
    persona_cost_usd: state.persona_cost,
  ))
}

/// The memory for a scenario that asks for it (PRD-M), with the key from
/// the environment; off otherwise.
pub fn scenario_recall(
  wanted: Bool,
  key: Result(String, Nil),
) -> config.RecallConfig {
  config.RecallConfig(
    ..config.default_recall_config(),
    enabled: wanted,
    api_key: case wanted, key {
      True, Ok(k) -> Some(k)
      _, _ -> None
    },
  )
}

fn build_config(
  input: Input,
  loaded: scenario.Loaded,
  port: Int,
  token: String,
) -> Result(config.Config, String) {
  use provider_type <- result.try(
    config.provider_from_name(input.agent_provider_name)
    |> result.map_error(fn(_) {
      "unknown provider: " <> input.agent_provider_name
    }),
  )
  let base = config.default_config()
  let agent_record =
    config.ProviderConfig(
      provider: provider_type,
      api_key: input.agent.api_key,
      base_url: input.agent.base_url,
      model: Some(input.agent.default_model),
      models: [],
      timeout_ms: 120_000,
    )
  let members =
    loaded.scenario.personas
    |> list.map(fn(persona) { "sim:" <> persona.user_id })
  let allowed_chats =
    loaded.scenario.chats
    |> list.map(fn(chat) { "sim:" <> chat.id })
  Ok(
    config.Config(
      ..base,
      environment: "harness",
      data_dir: input.data_dir,
      providers: dict.from_list([#(input.agent_provider_name, agent_record)]),
      sim: config.SimConfig(
        enabled: True,
        bind: "127.0.0.1",
        port: port,
        token: Some(token),
        record_prompts: True,
      ),
      access: config.AccessConfig(
        mode: config.Allowlist,
        admins: [],
        members: members,
        denied_reply: "Esta instância é privada.",
        allowed_chats: allowed_chats,
      ),
      reflection: config.ReflectionConfig(
        ..base.reflection,
        every_turns: input.every_turns,
      ),
      instance_budget: config.InstanceBudgetConfig(
        ..base.instance_budget,
        daily_usd: input.instance_daily_usd,
      ),
      conversation: config.ConversationConfig(
        ..base.conversation,
        recall: scenario_recall(
          loaded.scenario.recall,
          envoy.get(config.recall_key_env(
            config.default_recall_config().provider,
          )),
        ),
      ),
    ),
  )
}

fn play(
  input: Input,
  loaded: scenario.Loaded,
  port: Int,
  token: String,
  state: State,
) -> Result(State, String) {
  let steps =
    list.index_map(loaded.scenario.steps, fn(step, index) { #(index, step) })
  list.try_fold(steps, state, fn(current, item) {
    let #(step_index, step) = item
    play_step(input, loaded, port, token, current, step_index, step)
  })
}

fn play_step(
  input: Input,
  loaded: scenario.Loaded,
  port: Int,
  token: String,
  state: State,
  step_index: Int,
  step: scenario.Step,
) -> Result(State, String) {
  case step {
    scenario.Say(persona: persona_id, chat: chat_id, content: content) ->
      say(
        input,
        loaded,
        port,
        token,
        state,
        step_index,
        persona_id,
        chat_id,
        content,
      )
    scenario.Talk(
      persona: persona_id,
      chat: chat_id,
      goal: goal,
      max_turns: max_turns,
    ) ->
      talk(
        input,
        loaded,
        port,
        token,
        state,
        step_index,
        persona_id,
        chat_id,
        goal,
        max_turns,
      )
    scenario.Secret(persona: persona_id, marker: marker) ->
      case
        list.find(loaded.scenario.personas, fn(item) { item.id == persona_id })
      {
        Error(_) -> Error("unknown persona: " <> persona_id)
        Ok(persona) ->
          Ok(
            State(
              ..state,
              events: list.append(state.events, [
                transcript.Secret(
                  persona: persona_id,
                  principal: "sim:" <> persona.user_id,
                  marker: marker,
                  at: clock.now(state.clock),
                ),
              ]),
            ),
          )
      }
    scenario.Advance(hours: hours) -> {
      let _ = clock.advance(state.clock, hours * 3_600_000)
      Ok(state)
    }
    scenario.Seed(persona: persona_id, chat: chat_id, file: file, days: days) ->
      seed(input, loaded, state, step_index, persona_id, chat_id, file, days)
    scenario.Sweep -> {
      reflection.sweep(input.data_dir, input.agent)
      Ok(state)
    }
    scenario.WaitTasks(timeout_seconds: seconds) ->
      wait_tasks(port, token, state, step_index, seconds * 1000)
    scenario.Mark(label: label) ->
      Ok(
        State(
          ..state,
          events: list.append(state.events, [
            transcript.Mark(
              label: label,
              at: clock.now(state.clock),
              step: step_index,
            ),
          ]),
        ),
      )
  }
}

/// Poll the tasks until none is open, then wait, chat by chat, for the
/// agent's answer to each result delivered there (the sim channel marks the
/// end of an injected turn as of any other). An answer may start new tasks,
/// so it goes round until a pass finds nothing new. A cancelled task sends
/// nothing, so it is reported and not waited for.
fn wait_tasks(
  port: Int,
  token: String,
  state: State,
  step_index: Int,
  budget_ms: Int,
) -> Result(State, String) {
  use registry <- result.try(
    tasks.registry()
    |> option.to_result("wait_tasks: the tasks registry is not running"),
  )
  use #(every, left) <- result.try(await_closed(registry, budget_ms))
  let fresh =
    every
    |> list.filter(fn(item) { !list.contains(state.tasks_seen, task_key(item)) })
    |> list.sort(fn(a, b) { int.compare({ a.1 }.id, { b.1 }.id) })
  case fresh {
    [] -> Ok(state)
    _ -> {
      let at = clock.now(state.clock)
      let marks =
        list.map(fresh, fn(item) {
          let task = item.1
          transcript.Mark(
            label: "tarefa:"
              <> int.to_string(task.id)
              <> ":"
              <> task.tool
              <> ":"
              <> tasks.status_name(task.status),
            at: at,
            step: step_index,
          )
        })
      let state =
        State(
          ..state,
          events: list.append(state.events, marks),
          tasks_seen: list.append(state.tasks_seen, list.map(fresh, task_key)),
        )
      let answered =
        fresh
        |> list.filter(fn(item) { { item.1 }.status != tasks.Cancelled })
        |> list.map(fn(item) { item.1 })
      use state <- result.try(
        list.try_fold(answered, state, fn(current, task) {
          await_answer(port, token, current, step_index, task, left)
        }),
      )
      wait_tasks(port, token, state, step_index, left)
    }
  }
}

fn task_key(item: #(String, tasks.Task)) -> String {
  item.0 <> ":" <> int.to_string({ item.1 }.id)
}

fn await_closed(
  registry: tasks.Registry,
  budget_ms: Int,
) -> Result(#(List(#(String, tasks.Task)), Int), String) {
  let every = tasks.list_all(registry)
  let open = list.count(every, fn(item) { tasks.is_open(item.1) })
  case open, budget_ms <= 0 {
    0, _ -> Ok(#(every, budget_ms))
    _, True ->
      Error(
        "wait_tasks: "
        <> int.to_string(open)
        <> " task(s) still open at the timeout",
      )
    _, False -> {
      sleeper(100)
      await_closed(registry, budget_ms - 100)
    }
  }
}

/// The agent's answer to one delivered result, as a turn in the task's chat.
fn await_answer(
  port: Int,
  token: String,
  state: State,
  step_index: Int,
  task: tasks.Task,
  budget_ms: Int,
) -> Result(State, String) {
  let chat_id = task.channel_id
  let after = dict_get(state.seq_by_chat, chat_id)
  use turn <- result.try(
    sim_client.await_turn(port, token, chat_id, after, budget_ms)
    |> result.map_error(fn(reason) {
      "wait_tasks: no answer to task "
      <> int.to_string(task.id)
      <> " in "
      <> chat_id
      <> ": "
      <> reason
    }),
  )
  let at = clock.now(state.clock)
  let outputs =
    list.map(turn.events, fn(event) {
      transcript.Output(
        chat: chat_id,
        seq: event.seq,
        at: at,
        step: step_index,
        principal: "sim:" <> task.user_id,
        content: event.content,
      )
    })
  let turn_end =
    transcript.TurnEnd(
      chat: chat_id,
      session: session.sim_session_id(chat_id, task.user_id),
      outcome: turn.outcome,
      at: at,
    )
  Ok(
    State(
      ..state,
      events: list.append(state.events, list.append(outputs, [turn_end])),
      seq_by_chat: dict.insert(state.seq_by_chat, chat_id, turn.last_seq),
    ),
  )
}

@external(erlang, "timer", "sleep")
fn sleeper(ms: Int) -> Nil

/// Write the seed's messages into the persona's history in `chat`, spread
/// evenly from `days` before now up to an hour ago, then end the session if
/// it is open, so the next message reloads the conversation from disk. The
/// transcript marks the step; the judge reads the seeded facts in the rubric.
fn seed(
  input: Input,
  loaded: scenario.Loaded,
  state: State,
  step_index: Int,
  persona_id: String,
  chat_id: String,
  file: String,
  days: Int,
) -> Result(State, String) {
  use persona <- result.try(
    list.find(loaded.scenario.personas, fn(item) { item.id == persona_id })
    |> result.replace_error("unknown persona: " <> persona_id),
  )
  use raw <- result.try(
    read_file(scenario.seeds_dir(input.root) <> "/" <> file)
    |> result.replace_error("cannot read seed file: " <> file),
  )
  use lines <- result.try(
    string.split(raw, "\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
    |> list.try_map(fn(line) {
      json.parse(line, seed_line_decoder())
      |> result.replace_error("invalid seed line in " <> file <> ": " <> line)
    }),
  )
  let now = clock.now(state.clock)
  let first = now - days * 86_400_000
  let span = now - 3_600_000 - first
  let count = list.length(lines)
  let messages =
    list.index_map(lines, fn(line, index) {
      let #(role, content) = line
      history_store.StoredMessage(
        role: role,
        content: content,
        at: first + span * index / int.max(count - 1, 1),
      )
    })
  let session_id = session.sim_session_id(chat_id, persona.user_id)
  // `limit` is only the window a session loads; append never prunes.
  use _ <- result.try(history_store.append(
    history_store.HistoryStore(data_dir: input.data_dir, limit: 1),
    session_id,
    messages,
  ))
  // Absent when the chat has not spoken yet; then there is nothing to reload.
  let _ = supervisor.stop_session(state.sessions, session_id)
  Ok(
    State(
      ..state,
      events: list.append(state.events, [
        transcript.Mark(
          label: "seed:"
            <> persona_id
            <> ":"
            <> chat_id
            <> ":"
            <> int.to_string(count),
          at: now,
          step: step_index,
        ),
      ]),
    ),
  )
}

fn seed_line_decoder() -> decode.Decoder(#(String, String)) {
  use role <- decode.field("role", decode.string)
  use content <- decode.field("content", decode.string)
  case role {
    "user" | "assistant" -> decode.success(#(role, content))
    _ -> decode.failure(#(role, content), "role must be user or assistant")
  }
}

fn say(
  input: Input,
  loaded: scenario.Loaded,
  port: Int,
  token: String,
  state: State,
  step_index: Int,
  persona_id: String,
  chat_id: String,
  content: String,
) -> Result(State, String) {
  case list.find(loaded.scenario.personas, fn(item) { item.id == persona_id }) {
    Error(_) -> Error("unknown persona: " <> persona_id)
    Ok(persona) ->
      case list.find(loaded.scenario.chats, fn(item) { item.id == chat_id }) {
        Error(_) -> Error("unknown chat: " <> chat_id)
        Ok(chat) -> {
          // A person takes a while between messages. A frozen clock put every
          // message in the same rate-limit minute and gave repeated model calls
          // the same call id (charged once).
          let at = clock.advance(state.clock, message_gap_ms)
          use _ <- result.try(sim_client.send(
            port,
            token,
            chat_id,
            persona.user_id,
            persona_id,
            content,
            chat.is_group,
          ))
          let input_event =
            transcript.Input(
              chat: chat_id,
              seq: next_seq(state, chat_id),
              at: at,
              step: step_index,
              persona: persona_id,
              content: content,
            )
          let after = dict_get(state.seq_by_chat, chat_id)
          use turn <- result.try(sim_client.await_turn(
            port,
            token,
            chat_id,
            after,
            input.turn_timeout_seconds * 1000,
          ))
          let outputs =
            turn.events
            |> list.map(fn(event) {
              transcript.Output(
                chat: chat_id,
                seq: event.seq,
                at: at,
                step: step_index,
                principal: "sim:" <> persona.user_id,
                content: event.content,
              )
            })
          let turn_end =
            transcript.TurnEnd(
              chat: chat_id,
              session: session.sim_session_id(chat_id, persona.user_id),
              outcome: turn.outcome,
              at: at,
            )
          Ok(
            State(
              ..state,
              events: list.append(
                state.events,
                list.append([input_event], list.append(outputs, [turn_end])),
              ),
              seq_by_chat: dict.insert(
                state.seq_by_chat,
                chat_id,
                turn.last_seq,
              ),
            ),
          )
        }
      }
  }
}

fn talk(
  input: Input,
  loaded: scenario.Loaded,
  port: Int,
  token: String,
  state: State,
  step_index: Int,
  persona_id: String,
  chat_id: String,
  goal: String,
  max_turns: Int,
) -> Result(State, String) {
  talk_loop(
    input,
    loaded,
    port,
    token,
    state,
    step_index,
    persona_id,
    chat_id,
    goal,
    max_turns,
    0,
  )
}

fn talk_loop(
  input: Input,
  loaded: scenario.Loaded,
  port: Int,
  token: String,
  state: State,
  step_index: Int,
  persona_id: String,
  chat_id: String,
  goal: String,
  max_turns: Int,
  turn: Int,
) -> Result(State, String) {
  case turn >= max_turns {
    True -> Ok(state)
    False -> {
      let view = chat_view(state.events, chat_id, persona_id)
      let template =
        read_file(input.root <> "/persona_prompt.md")
        |> result.unwrap(
          "# harness:persona\n{{sheet}}\n{{goal}}\n{{transcript}}",
        )
      let sheet =
        loaded.personas
        |> list.find(fn(item) { item.0 == persona_id })
        |> result.map(fn(item) { item.1 })
        |> result.unwrap("")
      // Single pass: text the persona or the agent wrote is never expanded.
      let system =
        prompt_template.render(template, [
          #("sheet", sheet),
          #("goal", goal),
          #("transcript", view),
        ])
      let driver = input.persona
      // The transcript is already in the system prompt; the turn itself only
      // asks for the next message.
      use generated <- result.try(driver(system, persona_instruction))
      let #(reply, cost) = generated
      let state = State(..state, persona_cost: state.persona_cost +. cost)
      case string.trim(reply) == "[FIM]" {
        True -> Ok(state)
        False -> {
          use next <- result.try(say(
            input,
            loaded,
            port,
            token,
            state,
            step_index,
            persona_id,
            chat_id,
            string.trim(reply),
          ))
          talk_loop(
            input,
            loaded,
            port,
            token,
            next,
            step_index,
            persona_id,
            chat_id,
            goal,
            max_turns,
            turn + 1,
          )
        }
      }
    }
  }
}

/// The chat as one persona sees it: her own messages and the replies that
/// followed them. Other personas' exchanges never enter this view.
pub fn chat_view(
  events: List(transcript.Event),
  chat_id: String,
  persona_id: String,
) -> String {
  let #(lines, _last) =
    events
    |> list.fold(#([], ""), fn(acc, event) {
      let #(lines, last_persona) = acc
      case event {
        transcript.Input(chat: chat, persona: persona, content: content, ..) ->
          case chat == chat_id && persona == persona_id {
            True -> #(list.append(lines, [persona <> ": " <> content]), persona)
            False -> acc
          }
        transcript.Output(chat: chat, content: content, ..) ->
          case chat == chat_id && last_persona == persona_id {
            True -> #(list.append(lines, ["agente: " <> content]), last_persona)
            False -> acc
          }
        transcript.Mark(label: label, ..) -> #(
          list.append(lines, ["--- " <> label <> " ---"]),
          last_persona,
        )
        _ -> acc
      }
    })
  string.join(lines, "\n")
}

fn next_seq(state: State, chat_id: String) -> Int {
  dict_get(state.seq_by_chat, chat_id) + 1
}

fn dict_get(dict: dict.Dict(String, Int), key: String) -> Int {
  case dict.get(dict, key) {
    Ok(value) -> value
    Error(_) -> 0
  }
}

@external(erlang, "supernova_harness_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "supernova_harness_ffi", "random_token")
fn random_token() -> String

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

fn prepare_data_dir(data_dir: String) -> Result(Nil, String) {
  let marker = data_dir <> "/" <> prompt_log.marker_file
  case file_exists(marker) {
    Ok(True) -> Ok(Nil)
    _ ->
      case dir_exists(data_dir) {
        True -> Error("refusing data_dir without .harness marker: " <> data_dir)
        False -> {
          use _ <- result.try(ensure_dir(data_dir))
          write_file(marker, "harness\n")
        }
      }
  }
}

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_harness_ffi", "dir_exists")
fn dir_exists(path: String) -> Bool
