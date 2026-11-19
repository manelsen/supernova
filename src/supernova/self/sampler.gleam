//// Coherent, deterministic constellation sampling.

import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import supernova/self/constellation.{
  type Constellation, type Dimension, type Trait,
}

pub type Sampled {
  Sampled(traits: List(String), seed: Int, attempts: Int)
}

pub type SampleError {
  NoCoherentSample
  EmptyConstellation
}

const max_attempts = 50

pub fn sample(
  constellation: Constellation,
  seed: Int,
  existing: List(Constellation),
) -> Result(Sampled, SampleError) {
  case constellation.traits {
    [] -> Error(EmptyConstellation)
    _ -> attempt(constellation, seed, existing, 0)
  }
}

fn attempt(
  constellation: Constellation,
  base_seed: Int,
  existing: List(Constellation),
  attempt_no: Int,
) -> Result(Sampled, SampleError) {
  case attempt_no >= max_attempts {
    True -> Error(NoCoherentSample)
    False -> {
      let seed = base_seed + attempt_no
      let #(_state, traits) = draw(constellation, seed)
      let picks_ok = pick_counts_ok(constellation, traits)
      let coherent =
        coherence(constellation, traits) >=. constellation.coherence_threshold
      let distant =
        list.all(existing, fn(other) {
          jaccard_distance(
            traits,
            list.map(other.traits, fn(trait) { trait.id }),
          )
          >=. constellation.min_distance
        })
      case picks_ok && coherent && distant {
        True ->
          Ok(Sampled(traits: traits, seed: seed, attempts: attempt_no + 1))
        False -> attempt(constellation, base_seed, existing, attempt_no + 1)
      }
    }
  }
}

fn draw(constellation: Constellation, seed: Int) -> #(Int, List(String)) {
  let all_ids = list.map(constellation.traits, fn(trait) { trait.id })
  let #(rng, index) = uniform_index(seed, list.length(all_ids))
  let seed_trait = nth(all_ids, index)
  let seed_dimension = case
    list.find(constellation.traits, fn(trait) { trait.id == seed_trait })
  {
    Ok(trait) -> trait.dimension
    Error(_) -> ""
  }
  list.fold(constellation.dimensions, #(rng, [seed_trait]), fn(acc, dimension) {
    let #(rng, chosen) = acc
    fill_dimension(
      constellation,
      dimension,
      seed_dimension,
      seed_trait,
      rng,
      chosen,
    )
  })
  |> fn(pair) {
    let #(rng, chosen) = pair
    #(rng, list.reverse(chosen) |> list.unique)
  }
}

fn fill_dimension(
  constellation: Constellation,
  dimension: Dimension,
  seed_dimension: String,
  seed_trait: String,
  rng: Int,
  chosen: List(String),
) -> #(Int, List(String)) {
  let already =
    list.any(chosen, fn(id) {
      list.any(constellation.traits, fn(trait) {
        trait.id == id && trait.dimension == dimension.id
      })
    })
  let seed_here = dimension.id == seed_dimension
  let initial = case seed_here && !already {
    True -> [seed_trait]
    False -> []
  }
  let accounted = case seed_here {
    True -> 1
    False -> 0
  }
  let remaining = dimension.pick - accounted
  fill_remaining(
    constellation,
    dimension.id,
    remaining,
    rng,
    list.append(chosen, initial),
  )
}

fn fill_remaining(
  constellation: Constellation,
  dimension: String,
  remaining: Int,
  rng: Int,
  chosen: List(String),
) -> #(Int, List(String)) {
  case remaining <= 0 {
    True -> #(rng, chosen)
    False -> {
      let candidates =
        constellation.traits
        |> list.filter(fn(trait) {
          trait.dimension == dimension && !list.contains(chosen, trait.id)
        })
      let #(next_rng, trait) =
        weighted_pick(constellation, candidates, rng, chosen)
      case trait {
        "" -> #(next_rng, chosen)
        id ->
          fill_remaining(constellation, dimension, remaining - 1, next_rng, [
            id,
            ..chosen
          ])
      }
    }
  }
}

fn weighted_pick(
  constellation: Constellation,
  candidates: List(Trait),
  rng: Int,
  chosen: List(String),
) -> #(Int, String) {
  let weights =
    list.map(candidates, fn(trait) {
      let affinities =
        list.map(chosen, fn(other) {
          constellation.affinity_weight(constellation, trait.id, other)
        })
      case list.any(affinities, fn(weight) { weight == -1.0 }) {
        True -> 0.0
        False ->
          float.exponential(
            2.0 *. list.fold(affinities, 0.0, fn(a, b) { a +. b }),
          )
      }
    })
  let total = list.fold(weights, 0.0, fn(a, b) { a +. b })
  case total <=. 0.0 || candidates == [] {
    True -> #(rng, "")
    False -> {
      let #(next_rng, roll) = uniform_float(rng)
      weighted_at(candidates, weights, roll *. total, next_rng)
    }
  }
}

fn weighted_at(
  candidates: List(Trait),
  weights: List(Float),
  target: Float,
  rng: Int,
) -> #(Int, String) {
  case candidates, weights {
    [], _ -> #(rng, "")
    [trait, ..rest], [weight, ..rest_weights] -> {
      case weight >. 0.0 && target <=. weight {
        True -> #(rng, trait.id)
        False -> weighted_at(rest, rest_weights, target -. weight, rng)
      }
    }
    _, _ -> #(rng, "")
  }
}

pub fn coherence(constellation: Constellation, ids: List(String)) -> Float {
  let pairs = pairs(ids)
  case pairs {
    [] -> 0.0
    _ ->
      list.fold(pairs, 0.0, fn(sum, pair) {
        let #(a, b) = pair
        sum +. constellation.affinity_weight(constellation, a, b)
      })
      /. int.to_float(list.length(pairs))
  }
}

pub fn pairs_for_test(ids: List(String)) -> List(#(String, String)) {
  pairs(ids)
}

fn pairs(ids: List(String)) -> List(#(String, String)) {
  case ids {
    [] -> []
    [first, ..rest] -> {
      let with_first = list.map(rest, fn(id) { #(first, id) })
      list.append(with_first, pairs(rest))
    }
  }
}

pub fn jaccard_distance(a: List(String), b: List(String)) -> Float {
  let a_set = dict.from_list(list.map(a, fn(id) { #(id, True) }))
  let b_set = dict.from_list(list.map(b, fn(id) { #(id, True) }))
  let intersection =
    dict.to_list(a_set)
    |> list.filter(fn(entry) { dict.has_key(b_set, entry.0) })
    |> list.length
  let union = dict.size(a_set) + dict.size(b_set) - intersection
  case union {
    0 -> 1.0
    _ -> 1.0 -. int.to_float(intersection) /. int.to_float(union)
  }
}

fn uniform_index(seed: Int, count: Int) -> #(Int, Int) {
  let #(next, value) = uniform_float(seed)
  case count <= 0 {
    True -> #(next, 0)
    False -> #(
      next,
      int.min(float.truncate(value *. int.to_float(count)), count - 1),
    )
  }
}

pub fn uniform_index_for_test(seed: Int, count: Int) -> Int {
  uniform_index(seed, count).1
}

fn uniform_float(seed: Int) -> #(Int, Float) {
  let next = rng_next(seed)
  #(next, int.to_float(next) /. int.to_float(2_147_483_647))
}

fn rng_next(seed: Int) -> Int {
  // SplitMix32-style finalizer over a 32-bit state: the seed is offset so it is
  // never 0 before the first step, and xor-shifts prevent the linear lattice
  // structure of a pure multiplicative mix.
  let z = int.modulo(seed + 0x9E3779B9, 4_294_967_296) |> result.unwrap(0)
  let z =
    int.modulo(bitwise_xor(z, z / 65_536) * 0x21F0AAAD, 4_294_967_296)
    |> result.unwrap(0)
  let z =
    int.modulo(bitwise_xor(z, z / 32_768) * 0x735A2D97, 4_294_967_296)
    |> result.unwrap(0)
  let z = bitwise_xor(z, z / 32_768)
  let mixed = int.modulo(z, 2_147_483_647) |> result.unwrap(0)
  case mixed {
    0 -> 1
    _ -> mixed
  }
}

@external(erlang, "erlang", "bxor")
fn bitwise_xor(a: Int, b: Int) -> Int

pub fn rng_next_for_test(seed: Int) -> Int {
  rng_next(seed)
}

fn nth(items: List(a), index: Int) -> a {
  let assert Ok(value) = nth_result(items, index)
  value
}

fn nth_result(items: List(a), index: Int) -> Result(a, Nil) {
  case items {
    [] -> Error(Nil)
    [first, ..rest] ->
      case index <= 0 {
        True -> Ok(first)
        False -> nth_result(rest, index - 1)
      }
  }
}

fn pick_counts_ok(constellation: Constellation, ids: List(String)) -> Bool {
  list.all(constellation.dimensions, fn(dimension) {
    let count =
      ids
      |> list.filter(fn(id) {
        list.any(constellation.traits, fn(trait) {
          trait.id == id && trait.dimension == dimension.id
        })
      })
      |> list.length
    count == dimension.pick
  })
}

pub fn has_absolute_incompatibility(
  constellation: constellation.Constellation,
  ids: List(String),
) -> Bool {
  case ids {
    [] -> False
    [first, ..rest] ->
      list.any(rest, fn(other) {
        constellation.affinity_weight(constellation, first, other) == -1.0
      })
      || has_absolute_incompatibility(constellation, rest)
  }
}
