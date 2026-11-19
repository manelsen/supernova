import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/result
import gleam/string

pub type RelationshipState {
  RelationshipState(
    user_id: String,
    warmth: Float,
    interaction_count: Int,
    last_interaction: Int,
    notes: String,
  )
}

pub type RelationshipEvent {
  TurnSuccess
  UserFrustrated
}

/// Legacy workspace location, still used in open mode.
pub fn relationship_path(workspace_path: String) -> String {
  workspace_path <> "/.supernova/RELATIONSHIP.json"
}

/// Relationship file inside a caller-supplied state directory.
pub fn relationship_path_in(state_dir: String) -> String {
  state_dir <> "/relationship.json"
}

pub fn load(workspace_path: String, user_id: String) -> RelationshipState {
  load_from_path(relationship_path(workspace_path), user_id)
}

/// Load the relationship from a caller-supplied state directory.
pub fn load_in(state_dir: String, user_id: String) -> RelationshipState {
  load_from_path(relationship_path_in(state_dir), user_id)
}

fn load_from_path(file_path: String, user_id: String) -> RelationshipState {
  let now = now_ms()
  let base = case ffi_read_file(file_path) {
    Error(_) -> default(user_id, now)
    Ok(content) ->
      case json.parse(from: content, using: relationship_decoder()) {
        Ok(loaded) -> loaded
        Error(_) -> default(user_id, now)
      }
  }

  apply_inactivity_decay(base, now)
}

pub fn save(
  workspace_path: String,
  state: RelationshipState,
) -> Result(Nil, String) {
  save_at(
    workspace_path <> "/.supernova",
    relationship_path(workspace_path),
    state,
  )
}

/// Save to a caller-supplied state directory.
pub fn save_in(
  state_dir: String,
  state: RelationshipState,
) -> Result(Nil, String) {
  save_at(state_dir, relationship_path_in(state_dir), state)
}

fn save_at(
  directory: String,
  file_path: String,
  state: RelationshipState,
) -> Result(Nil, String) {
  use _ <- result.try(ffi_ensure_dir(directory))
  ffi_write_file(file_path, encode(state))
}

pub fn apply_event(
  state: RelationshipState,
  event: RelationshipEvent,
) -> RelationshipState {
  let delta = case event {
    TurnSuccess -> 0.02
    UserFrustrated -> -0.1
  }
  let now = now_ms()
  RelationshipState(
    ..state,
    warmth: clamp(state.warmth +. delta),
    interaction_count: state.interaction_count + 1,
    last_interaction: now,
  )
}

pub fn should_refresh_user_markdown(
  previous: RelationshipState,
  updated: RelationshipState,
) -> Bool {
  let diff = float.absolute_value(updated.warmth -. previous.warmth)
  diff >. 0.1 || updated.interaction_count % 10 == 0
}

pub fn prompt_block(state: RelationshipState) -> String {
  "Proximidade atual: "
  <> warmth_label(state.warmth)
  <> " ("
  <> to_2dp(state.warmth)
  <> ")"
}

pub fn update_user_history(
  workspace_path: String,
  state: RelationshipState,
) -> Nil {
  let user_md_path = workspace_path <> "/.supernova/USER.md"
  let summary =
    "\n\n## HISTÓRICO RELACIONAL\n"
    <> "- Interações: "
    <> int.to_string(state.interaction_count)
    <> "\n- Warmth: "
    <> to_2dp(state.warmth)
    <> "\n- Último contato: "
    <> int.to_string(state.last_interaction)
    <> "\n- Notas: "
    <> default_note(state.notes)
    <> "\n"
  case ffi_read_file(user_md_path) {
    Ok(existing) -> {
      let _ = ffi_write_file(user_md_path, existing <> summary)
      Nil
    }
    Error(_) -> {
      let _ = ffi_write_file(user_md_path, "# Perfil do Usuário\n" <> summary)
      Nil
    }
  }
}

fn default(user_id: String, now: Int) -> RelationshipState {
  RelationshipState(
    user_id: user_id,
    warmth: 0.5,
    interaction_count: 0,
    last_interaction: now,
    notes: "",
  )
}

fn apply_inactivity_decay(
  state: RelationshipState,
  now: Int,
) -> RelationshipState {
  let days_since_last = { now - state.last_interaction } / 86_400_000
  case days_since_last <= 7 {
    True -> state
    False -> {
      let decay_days = days_since_last - 7
      let decayed = clamp(state.warmth -. int.to_float(decay_days) *. 0.05)
      RelationshipState(..state, warmth: decayed)
    }
  }
}

fn warmth_label(value: Float) -> String {
  case value {
    x if x <=. 0.2 -> "Desconhecido"
    x if x <=. 0.5 -> "Familiar"
    x if x <=. 0.8 -> "Próximo"
    _ -> "Muito próximo"
  }
}

fn clamp(value: Float) -> Float {
  case value <. 0.0 {
    True -> 0.0
    False ->
      case value >. 1.0 {
        True -> 1.0
        False -> value
      }
  }
}

fn to_2dp(value: Float) -> String {
  let scaled = value *. 100.0
  let rounded = float.round(scaled)
  let remainder = rounded % 100
  let decimals = case remainder < 0 {
    True -> remainder * -1
    False -> remainder
  }
  let decimals_text = int.to_string(decimals)
  let padded = case string.length(decimals_text) {
    0 -> "00"
    1 -> "0" <> decimals_text
    _ -> decimals_text
  }
  int.to_string(rounded / 100) <> "." <> padded
}

fn default_note(value: String) -> String {
  case string.trim(value) {
    "" -> "Sem notas."
    content -> content
  }
}

fn relationship_decoder() -> decode.Decoder(RelationshipState) {
  use user_id <- decode.field("user_id", decode.string)
  use warmth <- decode.optional_field("warmth", 0.5, decode.float)
  use interaction_count <- decode.optional_field(
    "interaction_count",
    0,
    decode.int,
  )
  use last_interaction <- decode.optional_field(
    "last_interaction",
    now_ms(),
    decode.int,
  )
  use notes <- decode.optional_field("notes", "", decode.string)
  decode.success(RelationshipState(
    user_id: user_id,
    warmth: clamp(warmth),
    interaction_count: interaction_count,
    last_interaction: last_interaction,
    notes: notes,
  ))
}

fn encode(state: RelationshipState) -> String {
  "{"
  <> "\"user_id\":\""
  <> escape(state.user_id)
  <> "\","
  <> "\"warmth\":"
  <> float.to_string(state.warmth)
  <> ","
  <> "\"interaction_count\":"
  <> int.to_string(state.interaction_count)
  <> ","
  <> "\"last_interaction\":"
  <> int.to_string(state.last_interaction)
  <> ","
  <> "\"notes\":\""
  <> escape(state.notes)
  <> "\"}"
}

fn escape(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

@external(erlang, "supernova_file_system_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn ffi_write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ffi_ensure_dir(path: String) -> Result(Nil, String)
