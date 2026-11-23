import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/core/session/history_store
import supernova/harness/engine
import supernova/harness/scenario
import supernova/harness/transcript
import supernova/llm/client
import supernova/llm/provider
import test_workspace

const start = 1_700_000_000_000

fn mock_agent() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

fn mock_persona(
  system: String,
  transcript: String,
) -> Result(#(String, Float), String) {
  case
    client.chat(
      [provider.system_message(system), provider.user_message(transcript)],
      mock_agent(),
      [],
    )
  {
    Ok(response) -> Ok(#(response.content, 0.0))
    Error(error) -> Error(string.inspect(error))
  }
}

fn input(_root: String, data_dir: String) -> engine.Input {
  engine.Input(
    root: "priv/harness",
    data_dir: data_dir,
    transcript_path: data_dir <> "/transcripts.jsonl",
    agent: mock_agent(),
    agent_provider_name: "mock",
    persona: mock_persona,
    turn_timeout_seconds: 20,
    start_ms: start,
    instance_daily_usd: 5.0,
    member_daily_usd: 1.0,
    every_turns: 1,
  )
}

fn run(root: String, id: String) -> engine.Output {
  let assert Ok(loaded) = scenario.load("priv/harness", id)
  let assert Ok(output) =
    engine.run(input("priv/harness", root <> "/data"), loaded)
  output
}

fn count(
  events: List(transcript.Event),
  predicate: fn(transcript.Event) -> Bool,
) -> Int {
  events |> list.filter(predicate) |> list.length
}

pub fn say_and_three_talk_turns_produce_four_messages_test() {
  test_workspace.with_isolated_workspace("harness-engine-tres", fn(root) {
    let output = run(root, "provisorio_tres")
    count(output.events, fn(event) {
      case event {
        transcript.Input(..) -> True
        _ -> False
      }
    })
    |> should.equal(6)
    count(output.events, fn(event) {
      case event {
        transcript.Output(..) -> True
        _ -> False
      }
    })
    |> should.equal(6)
  })
}

pub fn persona_stops_on_fim_test() {
  test_workspace.with_isolated_workspace("harness-engine-fim", fn(root) {
    let output = run(root, "provisorio")
    count(output.events, fn(event) {
      case event {
        transcript.Input(..) -> True
        _ -> False
      }
    })
    |> should.equal(5)
  })
}

pub fn each_persona_sees_only_her_own_exchange_test() {
  test_workspace.with_isolated_workspace("harness-engine-group", fn(root) {
    let recorder = process.new_subject()
    let driver = fn(system: String, transcript_text: String) {
      let name = case string.contains(system, "Você é Bia") {
        True -> "bia"
        False -> "caio"
      }
      // The persona's view of the chat lives in the system prompt; the turn
      // itself is a fixed instruction.
      transcript_text |> should.equal(engine.persona_instruction)
      process.send(recorder, #(name, system))
      mock_persona(system, transcript_text)
    }
    let assert Ok(loaded) = scenario.load("priv/harness", "provisorio_grupo")
    let assert Ok(_output) =
      engine.run(
        engine.Input(..input("priv/harness", root <> "/data"), persona: driver),
        loaded,
      )
    let first = process.receive(recorder, within: 1000)
    let second = process.receive(recorder, within: 1000)
    let assert Ok(#(first_name, first_view)) = first
    let assert Ok(#(_second_name, second_view)) = second
    case first_name {
      "bia" -> {
        string.contains(first_view, "bia:") |> should.be_true()
        string.contains(first_view, "caio:") |> should.equal(False)
      }
      _ -> {
        string.contains(second_view, "caio:") |> should.be_true()
        string.contains(second_view, "bia:") |> should.equal(False)
      }
    }
  })
}

pub fn advance_and_sweep_step_runs_test() {
  test_workspace.with_isolated_workspace("harness-engine-sweep", fn(root) {
    let assert Ok(loaded) = scenario.load("priv/harness", "provisorio_sweep")
    let assert Ok(_) =
      engine.run(
        engine.Input(..input("priv/harness", root <> "/data"), every_turns: 6),
        loaded,
      )
    file_exists(root <> "/data/.harness") |> should.equal(Ok(True))
    // The turns reached the agent (no kernel refusal) and the daily sweep
    // reflected them into experience.
    let assert Ok(transcript) = read_file(root <> "/data/transcripts.jsonl")
    string.contains(transcript, "\"outcome\":\"denied\"")
    |> should.be_false()
    string.contains(transcript, "\"outcome\":\"ok\"")
    |> should.be_true()
    let assert Ok(experience) =
      read_file(root <> "/data/agents/sim_bia/self/experience.jsonl")
    string.contains(experience, "\"text\":") |> should.be_true()
  })
}

/// A seeded conversation lands in the persona's history, dated before now,
/// and reaches the agent on the next message (the open session reloads).
pub fn seed_step_writes_the_history_and_reaches_the_agent_test() {
  test_workspace.with_isolated_workspace("harness-engine-seed", fn(root) {
    let output = run(root, "provisorio_seed")
    count(output.events, fn(event) {
      case event {
        transcript.Mark(label: "seed:bia:dm-bia:4", ..) -> True
        _ -> False
      }
    })
    |> should.equal(1)
    list.any(output.prompts, fn(prompt) {
      string.contains(prompt.content, "SEMENTE-7781")
    })
    |> should.be_true()
    let store =
      history_store.HistoryStore(data_dir: root <> "/data", limit: 100)
    let history = history_store.load(store, "sim:dm-bia:bia")
    let assert Ok(seeded) =
      list.find(history, fn(m) { string.contains(m.content, "SEMENTE-7781") })
    { seeded.at < start } |> should.be_true()
  })
}

/// A seed names an existing file and a positive number of days.
pub fn seed_step_is_validated_test() {
  test_workspace.with_isolated_workspace("harness-seed-validation", fn(root) {
    let assert Ok(base) = scenario.load("priv/harness", "provisorio_seed")
    let check = fn(step) {
      scenario.validate(
        "priv/harness",
        scenario.Scenario(..base.scenario, steps: [step]),
        base.personas,
      )
    }
    check(scenario.Seed("bia", "dm-bia", "provisorio_seed.jsonl", 3))
    |> should.equal(Ok(Nil))
    check(scenario.Seed("bia", "dm-bia", "nao_existe.jsonl", 3))
    |> should.be_error()
    check(scenario.Seed("bia", "dm-bia", "provisorio_seed.jsonl", 0))
    |> should.be_error()
    check(scenario.Seed("bia", "outro-chat", "provisorio_seed.jsonl", 3))
    |> should.be_error()
    let _ = root
    Nil
  })
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)
