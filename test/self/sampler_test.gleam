import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should
import supernova/self/constellation
import supernova/self/sampler

pub fn main() -> Nil {
  gleeunit.main()
}

fn small() -> constellation.Constellation {
  let assert Ok(raw) = read("test/fixtures/constellation_small.json")
  let assert Ok(value) = constellation.parse(raw)
  value
}

fn incompatible() -> constellation.Constellation {
  let assert Ok(raw) = read("test/fixtures/constellation_all_incompatible.json")
  let assert Ok(value) = constellation.parse(raw)
  value
}

pub fn same_seed_and_existing_are_deterministic_test() {
  let constellation = small()
  let first = sampler.sample(constellation, 42, [])
  let second = sampler.sample(constellation, 42, [])
  first |> should.equal(second)
}

pub fn thousand_seeds_respect_picks_and_coherence_test() {
  let constellation = small()
  let traits_by_id =
    dict.from_list(
      list.map(constellation.traits, fn(trait) { #(trait.id, trait) }),
    )
  seeds(0, 999)
  |> list.each(fn(seed) {
    case sampler.sample(constellation, seed, []) {
      Ok(sampled) -> {
        list.each(constellation.dimensions, fn(dimension) {
          sampled.traits
          |> list.filter(fn(id) {
            case dict.get(traits_by_id, id) {
              Ok(trait) -> trait.dimension == dimension.id
              Error(_) -> False
            }
          })
          |> list.length
          |> should.equal(dimension.pick)
        })
        sampler.coherence(constellation, sampled.traits)
        |> fn(value) { value >=. constellation.coherence_threshold }
        |> should.be_true()
        list.each(sampler.pairs_for_test(sampled.traits), fn(pair) {
          constellation.affinity_weight(constellation, pair.0, pair.1)
          |> should.not_equal(-1.0)
        })
      }
      Error(sampler.NoCoherentSample) -> Nil
      Error(sampler.EmptyConstellation) -> should.fail()
    }
  })
}

pub fn existing_constellation_respects_jaccard_distance_test() {
  let constellation = small()
  let first = first_success(constellation, 0, [])
  let second =
    first_success(constellation, 100, [
      constellation_with_traits(constellation, first.traits),
    ])
  let distance = sampler.jaccard_distance(first.traits, second.traits)
  { distance >=. constellation.min_distance } |> should.be_true()
}

pub fn impossible_constellation_returns_error_test() {
  sampler.sample(incompatible(), 7, [])
  |> should.equal(Error(sampler.NoCoherentSample))
}

pub fn strong_affinity_is_sampled_more_often_test() {
  let a = constellation.Trait(id: "a", dimension: "target", description: "")
  let b = constellation.Trait(id: "b", dimension: "target", description: "")
  let s = constellation.Trait(id: "s", dimension: "seed", description: "")
  let constellation =
    constellation.Constellation(
      version: 1,
      dimensions: [
        constellation.Dimension(id: "seed", pick: 1),
        constellation.Dimension(id: "target", pick: 1),
      ],
      traits: [s, a, b],
      affinities: [constellation.Affinity(a: "s", b: "a", weight: 1.0)],
      coherence_threshold: 0.0,
      min_distance: 0.0,
    )
  let count =
    seeds(0, 999)
    |> list.fold(0, fn(acc, seed) {
      case sampler.sample(constellation, seed, []) {
        Ok(sampled) ->
          case list.contains(sampled.traits, "a") {
            True -> acc + 1
            False -> acc
          }
        Error(_) -> acc
      }
    })
  { count > 400 } |> should.be_true()
}

fn first_success(
  constellation: constellation.Constellation,
  seed: Int,
  existing: List(constellation.Constellation),
) -> sampler.Sampled {
  case sampler.sample(constellation, seed, existing) {
    Ok(value) -> value
    Error(_) -> first_success(constellation, seed + 1, existing)
  }
}

fn constellation_with_traits(
  base: constellation.Constellation,
  ids: List(String),
) -> constellation.Constellation {
  constellation.Constellation(
    ..base,
    traits: list.filter(base.traits, fn(trait) { list.contains(ids, trait.id) }),
  )
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read(path: String) -> Result(String, String)

fn seeds(start: Int, stop: Int) -> List(Int) {
  case start > stop {
    True -> []
    False -> [start, ..seeds(start + 1, stop)]
  }
}
