import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/core/introspection/mood

pub type ResponseLength {
  Short
  Normal
  Verbose
}

pub type SessionPreferences {
  SessionPreferences(
    model_override: Option(String),
    thinking_enabled: Bool,
    reasoning_visible: Bool,
    language: String,
    response_length: ResponseLength,
  )
}

pub type SelfState {
  SelfState(
    mood: mood.Mood,
    mood_cause: String,
    wakefulness: Float,
    concerns: List(String),
    open_questions: List(String),
    last_reflection: String,
    preferences: SessionPreferences,
  )
}

pub fn default_preferences() -> SessionPreferences {
  SessionPreferences(
    model_override: None,
    thinking_enabled: False,
    reasoning_visible: False,
    language: "pt-BR",
    response_length: Normal,
  )
}

pub fn default() -> SelfState {
  SelfState(
    mood: mood.neutral(),
    mood_cause: "inicial",
    wakefulness: 0.6,
    concerns: [],
    open_questions: [],
    last_reflection: "Sem reflexão registrada.",
    preferences: default_preferences(),
  )
}

pub fn self_state_path(workspace_path: String) -> String {
  workspace_path <> "/.supernova/SELF_STATE.json"
}

pub fn from_workspace(workspace_path: String) -> SelfState {
  let path = self_state_path(workspace_path)
  case ffi_read_file(path) {
    Error(_) -> default()
    Ok(content) ->
      case json.parse(from: content, using: self_state_decoder()) {
        Ok(state) -> state
        Error(_) -> default()
      }
  }
}

pub fn save(workspace_path: String, state: SelfState) -> Result(Nil, String) {
  let dir = workspace_path <> "/.supernova"
  use _ <- result.try(ffi_ensure_dir(dir))
  ffi_write_file(self_state_path(workspace_path), encode(state))
}

pub fn apply_outcome(
  state: SelfState,
  outcome: mood.Outcome,
  cause: String,
  suggestion: Option(mood.Mood),
) -> SelfState {
  let shifted = mood.shift(state.mood, outcome)
  let next_mood = case suggestion {
    Some(s) -> mood.blend_with_suggestion(shifted, s)
    None -> shifted
  }

  SelfState(
    ..state,
    mood: next_mood,
    mood_cause: cause,
    wakefulness: next_mood.arousal,
  )
}

pub fn apply_session_decay(state: SelfState) -> SelfState {
  SelfState(..state, mood: mood.decay_toward_neutral(state.mood))
}

pub fn set_model_override(
  state: SelfState,
  model_override: Option(String),
) -> SelfState {
  let preferences =
    SessionPreferences(..state.preferences, model_override: model_override)
  SelfState(..state, preferences: preferences)
}

pub fn set_thinking_enabled(state: SelfState, enabled: Bool) -> SelfState {
  let preferences =
    SessionPreferences(..state.preferences, thinking_enabled: enabled)
  SelfState(..state, preferences: preferences)
}

pub fn set_reasoning_visible(state: SelfState, visible: Bool) -> SelfState {
  let preferences =
    SessionPreferences(..state.preferences, reasoning_visible: visible)
  SelfState(..state, preferences: preferences)
}

pub fn prompt_block(state: SelfState) -> String {
  "Humor: "
  <> mood.label_pt(state.mood)
  <> " (valência: "
  <> float_to_2dp(state.mood.valence)
  <> ", arousal: "
  <> float_to_2dp(state.mood.arousal)
  <> ")\n"
  <> "Causa: "
  <> state.mood_cause
  <> "\n"
  <> "Disposição: "
  <> wakefulness_label(state.wakefulness)
  <> "\n"
  <> "Preocupações ativas: "
  <> list_or_none(state.concerns)
  <> "\n"
  <> "Questões em aberto: "
  <> list_or_none(state.open_questions)
  <> "\n"
  <> "Última reflexão: "
  <> state.last_reflection
}

fn list_or_none(items: List(String)) -> String {
  case items {
    [] -> "nenhuma"
    _ -> string.join(items, ", ")
  }
}

fn wakefulness_label(wakefulness: Float) -> String {
  case wakefulness {
    x if x <. 0.3 -> "Baixa"
    x if x <. 0.7 -> "Normal"
    _ -> "Alta"
  }
}

fn float_to_2dp(value: Float) -> String {
  let scaled = value *. 100.0
  let rounded = float.round(scaled)
  let remainder = rounded % 100
  let decimals = case remainder < 0 {
    True -> remainder * -1
    False -> remainder
  }
  let decimals_text = int.to_string(decimals)
  let padded_decimals = case string.length(decimals_text) {
    0 -> "00"
    1 -> "0" <> decimals_text
    _ -> decimals_text
  }
  int.to_string(rounded / 100) <> "." <> padded_decimals
}

fn encode(state: SelfState) -> String {
  "{"
  <> "\"mood\":{"
  <> "\"valence\":"
  <> float.to_string(state.mood.valence)
  <> ",\"arousal\":"
  <> float.to_string(state.mood.arousal)
  <> "},"
  <> "\"mood_cause\":\""
  <> escape(state.mood_cause)
  <> "\","
  <> "\"wakefulness\":"
  <> float.to_string(state.wakefulness)
  <> ",\"concerns\":"
  <> encode_string_list(state.concerns)
  <> ",\"open_questions\":"
  <> encode_string_list(state.open_questions)
  <> ",\"last_reflection\":\""
  <> escape(state.last_reflection)
  <> "\","
  <> "\"preferences\":"
  <> encode_preferences(state.preferences)
  <> "}"
}

fn encode_preferences(preferences: SessionPreferences) -> String {
  "{"
  <> "\"model_override\":"
  <> encode_optional_string(preferences.model_override)
  <> ",\"thinking_enabled\":"
  <> bool_to_json(preferences.thinking_enabled)
  <> ",\"reasoning_visible\":"
  <> bool_to_json(preferences.reasoning_visible)
  <> ",\"language\":\""
  <> escape(preferences.language)
  <> "\",\"response_length\":\""
  <> response_length_text(preferences.response_length)
  <> "\"}"
}

fn response_length_text(length: ResponseLength) -> String {
  case length {
    Short -> "short"
    Normal -> "normal"
    Verbose -> "verbose"
  }
}

fn decode_response_length(value: String) -> ResponseLength {
  case string.lowercase(value) {
    "short" -> Short
    "verbose" -> Verbose
    _ -> Normal
  }
}

fn encode_optional_string(value: Option(String)) -> String {
  case value {
    Some(content) -> "\"" <> escape(content) <> "\""
    None -> "null"
  }
}

fn encode_string_list(items: List(String)) -> String {
  "["
  <> string.join(
    list.map(items, fn(item) { "\"" <> escape(item) <> "\"" }),
    ",",
  )
  <> "]"
}

fn bool_to_json(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

fn escape(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

fn self_state_decoder() -> decode.Decoder(SelfState) {
  use mood_value <- decode.field("mood", mood_decoder())
  use mood_cause <- decode.optional_field(
    "mood_cause",
    "inicial",
    decode.string,
  )
  use wakefulness <- decode.optional_field("wakefulness", 0.6, decode.float)
  use concerns <- decode.optional_field(
    "concerns",
    [],
    decode.list(decode.string),
  )
  use open_questions <- decode.optional_field(
    "open_questions",
    [],
    decode.list(decode.string),
  )
  use last_reflection <- decode.optional_field(
    "last_reflection",
    "Sem reflexão registrada.",
    decode.string,
  )
  use preferences <- decode.optional_field(
    "preferences",
    default_preferences(),
    preferences_decoder(),
  )

  decode.success(SelfState(
    mood: mood_value,
    mood_cause: mood_cause,
    wakefulness: wakefulness,
    concerns: list.take(concerns, 3),
    open_questions: list.take(open_questions, 3),
    last_reflection: last_reflection,
    preferences: preferences,
  ))
}

fn mood_decoder() -> decode.Decoder(mood.Mood) {
  use valence <- decode.optional_field("valence", 0.0, decode.float)
  use arousal <- decode.optional_field("arousal", 0.3, decode.float)
  decode.success(mood.Mood(valence: valence, arousal: arousal))
}

fn preferences_decoder() -> decode.Decoder(SessionPreferences) {
  use model_override <- decode.optional_field(
    "model_override",
    None,
    decode.optional(decode.string),
  )
  use thinking_enabled <- decode.optional_field(
    "thinking_enabled",
    False,
    decode.bool,
  )
  use reasoning_visible <- decode.optional_field(
    "reasoning_visible",
    False,
    decode.bool,
  )
  use language <- decode.optional_field("language", "pt-BR", decode.string)
  use response_length <- decode.optional_field(
    "response_length",
    "normal",
    decode.string,
  )

  decode.success(SessionPreferences(
    model_override: model_override,
    thinking_enabled: thinking_enabled,
    reasoning_visible: reasoning_visible,
    language: language,
    response_length: decode_response_length(response_length),
  ))
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn ffi_write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ffi_ensure_dir(path: String) -> Result(Nil, String)
