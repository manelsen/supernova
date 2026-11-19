import gleam/int
import gleam/string
import gleeunit/should
import supernova/core/introspection/relationship.{load, prompt_block, save}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

fn unique_workspace(prefix: String) -> String {
  "/tmp/supernova-relationship-" <> prefix <> "-" <> int.to_string(now_ms())
}

pub fn save_and_load_round_trip_test() {
  let workspace = unique_workspace("event")
  let initial = load(workspace, "telegram:123")
  let assert Ok(_) = save(workspace, initial)
  let loaded = load(workspace, "telegram:123")

  should.equal(loaded.user_id, "telegram:123")
  should.equal(loaded.warmth >=. 0.0, True)
}

pub fn prompt_block_contains_label_test() {
  let workspace = unique_workspace("prompt")
  let initial = load(workspace, "telegram:456")
  let text = prompt_block(initial)

  should.equal(string.contains(text, "Proximidade atual:"), True)
}

pub fn base_dir_paths_and_round_trip_test() {
  let state_dir = unique_workspace("state-dir") <> "/self"
  relationship.relationship_path_in(state_dir)
  |> should.equal(state_dir <> "/relationship.json")

  let initial = relationship.load_in(state_dir, "telegram:789")
  let assert Ok(_) = relationship.save_in(state_dir, initial)
  let loaded = relationship.load_in(state_dir, "telegram:789")

  loaded.user_id |> should.equal("telegram:789")
  loaded.warmth |> should.equal(initial.warmth)
}

pub fn workspace_path_is_unchanged_test() {
  relationship.relationship_path("/tmp/ws")
  |> should.equal("/tmp/ws/.supernova/RELATIONSHIP.json")
}
