import gleam/float
import gleeunit/should
import supernova/core/introspection/mood

pub fn shift_applies_tool_error_delta_test() {
  let initial = mood.Mood(valence: 0.0, arousal: 0.3)
  let shifted = mood.shift(initial, mood.ToolCallError)

  float.round(shifted.valence *. 100.0)
  |> should.equal(-15)
  float.round(shifted.arousal *. 100.0)
  |> should.equal(50)
}

pub fn decay_moves_toward_neutral_test() {
  let initial = mood.Mood(valence: 1.0, arousal: 1.0)
  let decayed = mood.decay_toward_neutral(initial)

  // 30% towards neutral (0.0, 0.3) -> (0.7, 0.79)
  float.round(decayed.valence *. 100.0)
  |> should.equal(70)
  float.round(decayed.arousal *. 100.0)
  |> should.equal(79)
}

pub fn blend_with_suggestion_uses_70_30_rule_test() {
  let current = mood.Mood(valence: 0.0, arousal: 0.3)
  let suggestion = mood.Mood(valence: 1.0, arousal: 1.0)

  let blended = mood.blend_with_suggestion(current, suggestion)
  float.round(blended.valence *. 100.0)
  |> should.equal(30)
  float.round(blended.arousal *. 100.0)
  |> should.equal(51)
}

pub fn labels_are_in_portuguese_test() {
  mood.label_pt(mood.Mood(valence: 0.8, arousal: 0.8))
  |> should.equal("Energizado")

  mood.label_pt(mood.Mood(valence: -0.5, arousal: 0.8))
  |> should.equal("Frustrado")

  mood.label_pt(mood.Mood(valence: 0.0, arousal: 0.2))
  |> should.equal("Neutro")
}
