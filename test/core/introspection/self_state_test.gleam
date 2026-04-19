import gleam/int
import gleam/string
import gleeunit/should
import supernova/core/introspection/mood
import supernova/core/introspection/self_state as introspection_self_state
import supernova/core/introspection/self_state.{
  default_preferences, from_workspace, prompt_block, save,
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

fn unique_workspace(prefix: String) -> String {
  "/tmp/supernova-self-state-" <> prefix <> "-" <> int.to_string(now_ms())
}

pub fn save_and_load_round_trip_test() {
  let workspace = unique_workspace("round-trip")
  let state =
    introspection_self_state.SelfState(
      mood: mood.Mood(valence: -0.2, arousal: 0.9),
      mood_cause: "tool_error",
      wakefulness: 0.8,
      concerns: ["timeout"],
      open_questions: ["confirmar deploy?"],
      last_reflection: "Errei por não validar argumentos.",
      preferences: default_preferences(),
    )

  let assert Ok(_) = save(workspace, state)
  let loaded = from_workspace(workspace)

  loaded.mood_cause |> should.equal("tool_error")
  loaded.concerns |> should.equal(["timeout"])
  loaded.open_questions |> should.equal(["confirmar deploy?"])
}

pub fn prompt_block_contains_portuguese_humor_label_test() {
  let state =
    introspection_self_state.SelfState(
      mood: mood.Mood(valence: -0.5, arousal: 0.8),
      mood_cause: "falha de ferramenta",
      wakefulness: 0.7,
      concerns: [],
      open_questions: [],
      last_reflection: "Preciso validar entradas.",
      preferences: default_preferences(),
    )

  let block = prompt_block(state)
  string.contains(block, "Humor: Frustrado")
  |> should.equal(True)
}
