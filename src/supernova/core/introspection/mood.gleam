import gleam/float
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Mood {
  Mood(valence: Float, arousal: Float)
}

pub type Outcome {
  ToolCallSuccess
  ToolCallError
  LLMFailure
  LongResponseGenerated
  SessionEndedNormally
}

pub fn neutral() -> Mood {
  Mood(valence: 0.0, arousal: 0.3)
}

pub fn shift(current: Mood, outcome: Outcome) -> Mood {
  let #(dv, da) = case outcome {
    ToolCallSuccess -> #(0.1, 0.0)
    ToolCallError -> #(-0.15, 0.2)
    LLMFailure -> #(-0.1, 0.1)
    LongResponseGenerated -> #(0.05, 0.1)
    SessionEndedNormally -> #(0.05, -0.1)
  }

  Mood(
    valence: clamp(current.valence +. dv, -1.0, 1.0),
    arousal: clamp(current.arousal +. da, 0.0, 1.0),
  )
}

/// Applies a 30% decay towards neutral mood at session start.
pub fn decay_toward_neutral(current: Mood) -> Mood {
  let target = neutral()
  Mood(
    valence: current.valence +. { target.valence -. current.valence } *. 0.3,
    arousal: current.arousal +. { target.arousal -. current.arousal } *. 0.3,
  )
}

/// Applies blend rule: new = 0.7 * current + 0.3 * suggestion.
pub fn blend_with_suggestion(current: Mood, suggestion: Mood) -> Mood {
  Mood(
    valence: clamp(
      current.valence *. 0.7 +. suggestion.valence *. 0.3,
      -1.0,
      1.0,
    ),
    arousal: clamp(
      current.arousal *. 0.7 +. suggestion.arousal *. 0.3,
      0.0,
      1.0,
    ),
  )
}

/// Friendly Portuguese label for current mood.
pub fn label_pt(current: Mood) -> String {
  case current {
    Mood(valence: v, arousal: a) if v >. 0.5 && a >. 0.5 -> "Energizado"
    Mood(valence: v, arousal: a) if v >. 0.5 && a <=. 0.5 -> "Satisfeito"
    Mood(valence: v, arousal: a) if v >=. -0.2 && v <=. 0.2 && a >. 0.5 ->
      "Alerta"
    Mood(valence: v, arousal: a) if v <. -0.2 && a <. 0.3 -> "Contido"
    Mood(valence: v, arousal: a) if v <. -0.2 && a >. 0.5 -> "Frustrado"
    _ -> "Neutro"
  }
}

/// Parses optional model hint: `[mood: valence=X, arousal=Y]`.
pub fn parse_suggestion(content: String) -> Option(Mood) {
  case string.split_once(content, "[mood:") {
    Error(_) -> None
    Ok(#(_, after_marker)) ->
      case string.split_once(after_marker, "]") {
        Error(_) -> None
        Ok(#(payload, _)) -> parse_payload(payload)
      }
  }
}

fn parse_payload(payload: String) -> Option(Mood) {
  let cleaned = string.trim(payload)
  case string.split(cleaned, ",") {
    [left, right] -> {
      let left_value = parse_key_value(left, "valence=")
      let right_value = parse_key_value(right, "arousal=")
      case left_value, right_value {
        Some(v), Some(a) ->
          Some(Mood(valence: clamp(v, -1.0, 1.0), arousal: clamp(a, 0.0, 1.0)))
        _, _ -> None
      }
    }
    _ -> None
  }
}

fn parse_key_value(value: String, prefix: String) -> Option(Float) {
  let trimmed = string.trim(value)
  case string.starts_with(trimmed, prefix) {
    False -> None
    True ->
      case
        trimmed
        |> string.drop_start(string.length(prefix))
        |> string.trim
        |> float.parse
      {
        Ok(value) -> Some(value)
        Error(_) -> None
      }
  }
}

fn clamp(value: Float, min_value: Float, max_value: Float) -> Float {
  case value <. min_value {
    True -> min_value
    False ->
      case value >. max_value {
        True -> max_value
        False -> value
      }
  }
}
