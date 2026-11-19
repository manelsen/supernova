import gleam/list
import gleeunit/should
import supernova/self/constellation
import supernova/self/reflection

fn constellation() -> constellation.Constellation {
  constellation.Constellation(
    version: 1,
    dimensions: [
      constellation.Dimension(id: "d", pick: 1),
      constellation.Dimension(id: "e", pick: 1),
    ],
    traits: [
      constellation.Trait(id: "a", dimension: "d", description: "a"),
      constellation.Trait(id: "b", dimension: "d", description: "b"),
      constellation.Trait(id: "c", dimension: "d", description: "c"),
      constellation.Trait(id: "x", dimension: "e", description: "x"),
      constellation.Trait(id: "y", dimension: "e", description: "y"),
    ],
    affinities: [
      constellation.Affinity(a: "b", b: "x", weight: 0.5),
      constellation.Affinity(a: "a", b: "x", weight: 0.2),
      constellation.Affinity(a: "a", b: "y", weight: -1.0),
    ],
    coherence_threshold: 0.0,
    min_distance: 0.0,
  )
}

fn pressure(
  from: String,
  to: String,
  strength: Float,
) -> reflection.RawPressure {
  reflection.RawPressure(
    from: from,
    to: to,
    strength: strength,
    reason: "teste",
  )
}

pub fn invalid_pressures_are_discarded_and_valid_kept_test() {
  let traits = ["a", "x"]
  let items = [
    pressure("a", "b", 0.5),
    pressure("a", "c", 0.5),
    pressure("a", "x", 0.5),
    pressure("z", "b", 0.5),
    pressure("x", "y", 0.5),
    pressure("a", "b", 2.0),
  ]
  reflection.valid_pressures(items, traits, constellation())
  |> should.equal([pressure("a", "b", 0.5)])
}

pub fn at_most_two_pressures_are_accepted_test() {
  let traits = ["a", "x"]
  let items = [
    pressure("a", "b", 0.5),
    pressure("a", "b", 0.4),
    pressure("a", "b", 0.3),
  ]
  reflection.valid_pressures(items, traits, constellation())
  |> list.length
  |> should.equal(2)
}
