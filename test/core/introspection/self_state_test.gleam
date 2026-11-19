import gleam/int
import gleam/string
import gleeunit/should
import supernova/core/introspection/mood
import supernova/core/introspection/self_state.{
  SelfState, default_preferences, from_workspace, prompt_block, save,
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

fn unique_workspace(prefix: String) -> String {
  "/tmp/supernova-self-state-" <> prefix <> "-" <> int.to_string(now_ms())
}

pub fn save_and_load_round_trip_test() {
  let workspace = unique_workspace("round-trip")
  let state =
    SelfState(
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
    SelfState(
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

pub fn base_dir_paths_and_round_trip_test() {
  let state_dir = unique_workspace("state-dir") <> "/self"
  self_state.state_path_in(state_dir)
  |> should.equal(state_dir <> "/state.json")

  let state =
    SelfState(
      mood: mood.Mood(valence: 0.1, arousal: 0.5),
      mood_cause: "self_dir",
      wakefulness: 0.7,
      concerns: ["self_dir"],
      open_questions: [],
      last_reflection: "Estado no diretorio self.",
      preferences: default_preferences(),
    )

  let assert Ok(_) = self_state.save_in(state_dir, state)
  let loaded = self_state.from_dir(state_dir)
  loaded.mood_cause |> should.equal("self_dir")
  loaded.concerns |> should.equal(["self_dir"])
}

pub fn workspace_path_is_unchanged_test() {
  self_state.self_state_path("/tmp/ws")
  |> should.equal("/tmp/ws/.supernova/SELF_STATE.json")
}
