//// Constellation format: dimensions, traits and affinity gravity.

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result

pub type Dimension {
  Dimension(id: String, pick: Int)
}

pub type Trait {
  Trait(id: String, dimension: String, description: String)
}

pub type Affinity {
  Affinity(a: String, b: String, weight: Float)
}

pub type Constellation {
  Constellation(
    version: Int,
    dimensions: List(Dimension),
    traits: List(Trait),
    affinities: List(Affinity),
    coherence_threshold: Float,
    min_distance: Float,
  )
}

pub type LoadError {
  ReadError(String)
  ParseError(String)
  ValidationError(String)
}

pub fn load(path: String) -> Result(Constellation, String) {
  case ffi_read_file(path) {
    Ok(raw) -> parse(raw)
    Error(reason) -> Error("cannot read constellation: " <> reason)
  }
}

pub fn parse(raw: String) -> Result(Constellation, String) {
  let decoder = {
    use version <- decode.field("version", decode.int)
    use dimensions <- decode.field(
      "dimensions",
      decode.list(dimension_decoder()),
    )
    use traits <- decode.field("traits", decode.list(trait_decoder()))
    use affinities <- decode.field(
      "affinities",
      decode.list(affinity_decoder()),
    )
    use coherence_threshold <- decode.field("coherence_threshold", decode.float)
    use min_distance <- decode.field("min_distance", decode.float)
    decode.success(Constellation(
      version: version,
      dimensions: dimensions,
      traits: traits,
      affinities: affinities,
      coherence_threshold: coherence_threshold,
      min_distance: min_distance,
    ))
  }
  case json.parse(from: raw, using: decoder) {
    Error(_) -> Error("invalid constellation JSON")
    Ok(constellation) ->
      case validate(constellation) {
        Ok(_) -> Ok(constellation)
        Error(reason) -> Error(reason)
      }
  }
}

fn dimension_decoder() -> decode.Decoder(Dimension) {
  use id <- decode.field("id", decode.string)
  use pick <- decode.field("pick", decode.int)
  decode.success(Dimension(id: id, pick: pick))
}

fn trait_decoder() -> decode.Decoder(Trait) {
  use id <- decode.field("id", decode.string)
  use dimension <- decode.field("dimension", decode.string)
  use description <- decode.field("description", decode.string)
  decode.success(Trait(id: id, dimension: dimension, description: description))
}

fn affinity_decoder() -> decode.Decoder(Affinity) {
  use a <- decode.field("a", decode.string)
  use b <- decode.field("b", decode.string)
  use weight <- decode.field("weight", decode.float)
  decode.success(Affinity(a: a, b: b, weight: weight))
}

pub fn validate(constellation: Constellation) -> Result(Nil, String) {
  let dimensions =
    constellation.dimensions
    |> list.map(fn(dimension) { #(dimension.id, dimension) })
    |> dict.from_list
  case dict.size(dimensions) == list.length(constellation.dimensions) {
    False -> Error("duplicate dimension id")
    True -> {
      let traits =
        constellation.traits
        |> list.map(fn(trait) { #(trait.id, trait) })
        |> dict.from_list
      case dict.size(traits) == list.length(constellation.traits) {
        False -> Error("duplicate trait id")
        True -> {
          use _ <- result.try(validate_trait_dimensions(
            constellation.traits,
            dimensions,
          ))
          use _ <- result.try(validate_picks(constellation, dimensions))
          validate_affinities(constellation.affinities, traits)
        }
      }
    }
  }
}

fn validate_trait_dimensions(
  traits: List(Trait),
  dimensions: Dict(String, Dimension),
) -> Result(Nil, String) {
  case
    list.find(traits, fn(trait) { !dict.has_key(dimensions, trait.dimension) })
  {
    Ok(trait) -> Error("unknown dimension: " <> trait.dimension)
    Error(_) -> Ok(Nil)
  }
}

fn validate_picks(
  constellation: Constellation,
  _dimensions: Dict(String, Dimension),
) -> Result(Nil, String) {
  list.fold(constellation.dimensions, Ok(Nil), fn(acc, dimension) {
    use _ <- result.try(acc)
    let count =
      constellation.traits
      |> list.filter(fn(trait) { trait.dimension == dimension.id })
      |> list.length
    case dimension.pick > count {
      True -> Error("pick exceeds traits in dimension: " <> dimension.id)
      False -> Ok(Nil)
    }
  })
}

fn validate_affinities(
  affinities: List(Affinity),
  traits: Dict(String, Trait),
) -> Result(Nil, String) {
  use _ <- result.try(
    list.try_each(affinities, fn(affinity) {
      case
        dict.has_key(traits, affinity.a) && dict.has_key(traits, affinity.b)
      {
        False -> Error("affinity references unknown trait")
        True -> Ok(Nil)
      }
    }),
  )
  use _ <- result.try(
    list.try_each(affinities, fn(affinity) {
      case affinity.weight >=. -1.0 && affinity.weight <=. 1.0 {
        True -> Ok(Nil)
        False -> Error("affinity weight out of range")
      }
    }),
  )
  validate_symmetric(affinities, 0)
}

fn validate_symmetric(
  affinities: List(Affinity),
  index: Int,
) -> Result(Nil, String) {
  case list.drop(affinities, index) {
    [] -> Ok(Nil)
    [current, ..rest] -> {
      let conflicting =
        list.find(rest, fn(other) {
          let mirrored = current.a == other.b && current.b == other.a
          mirrored && current.weight != other.weight
        })
      case conflicting {
        Ok(_) -> Error("affinity weights are not symmetric")
        Error(_) -> validate_symmetric(affinities, index + 1)
      }
    }
  }
}

/// Symmetric lookup; undeclared pairs have weight 0.
pub fn affinity_weight(
  constellation: Constellation,
  a: String,
  b: String,
) -> Float {
  case
    list.find(constellation.affinities, fn(affinity) {
      let direct = affinity.a == a && affinity.b == b
      let reverse = affinity.a == b && affinity.b == a
      direct || reverse
    })
  {
    Ok(affinity) -> affinity.weight
    Error(_) -> 0.0
  }
}

pub fn traits_for(
  constellation: Constellation,
  dimension: String,
) -> List(Trait) {
  constellation.traits
  |> list.filter(fn(trait) { trait.dimension == dimension })
}

pub fn has_trait(constellation: Constellation, trait_id: String) -> Bool {
  constellation.traits
  |> list.any(fn(trait) { trait.id == trait_id })
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)
