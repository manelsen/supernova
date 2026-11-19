//// Execution transcript shared by the engine, the checks and the judge.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Event {
  Input(
    chat: String,
    seq: Int,
    at: Int,
    step: Int,
    persona: String,
    content: String,
  )
  Output(
    chat: String,
    seq: Int,
    at: Int,
    step: Int,
    principal: String,
    content: String,
  )
  Mark(label: String, at: Int, step: Int)
  Secret(persona: String, principal: String, marker: String, at: Int)
  TurnEnd(chat: String, session: String, outcome: String, at: Int)
}

pub fn encode(event: Event) -> String {
  json.to_string(case event {
    Input(chat, seq, at, step, persona, content) ->
      json.object([
        #("type", json.string("input")),
        #("chat", json.string(chat)),
        #("seq", json.int(seq)),
        #("at", json.int(at)),
        #("step", json.int(step)),
        #("persona", json.string(persona)),
        #("content", json.string(content)),
      ])
    Output(chat, seq, at, step, principal, content) ->
      json.object([
        #("type", json.string("output")),
        #("chat", json.string(chat)),
        #("seq", json.int(seq)),
        #("at", json.int(at)),
        #("step", json.int(step)),
        #("principal_id", json.string(principal)),
        #("content", json.string(content)),
      ])
    Mark(label, at, step) ->
      json.object([
        #("type", json.string("mark")),
        #("label", json.string(label)),
        #("at", json.int(at)),
        #("step", json.int(step)),
      ])
    Secret(persona, principal, marker, at) ->
      json.object([
        #("type", json.string("secret")),
        #("persona", json.string(persona)),
        #("principal_id", json.string(principal)),
        #("marker", json.string(marker)),
        #("at", json.int(at)),
      ])
    TurnEnd(chat, session, outcome, at) ->
      json.object([
        #("type", json.string("turn_end")),
        #("chat", json.string(chat)),
        #("session", json.string(session)),
        #("outcome", json.string(outcome)),
        #("at", json.int(at)),
      ])
  })
}

pub fn decode_line(line: String) -> Option(Event) {
  json.parse(from: line, using: event_decoder())
  |> result.unwrap(None)
}

fn event_decoder() -> decode.Decoder(Option(Event)) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "input" -> {
      use chat <- decode.optional_field("chat", "", decode.string)
      use seq <- decode.optional_field("seq", 0, decode.int)
      use at <- decode.optional_field("at", 0, decode.int)
      use step <- decode.optional_field("step", 0, decode.int)
      use persona <- decode.field("persona", decode.string)
      use content <- decode.field("content", decode.string)
      decode.success(Some(Input(chat, seq, at, step, persona, content)))
    }
    "output" -> {
      use chat <- decode.optional_field("chat", "", decode.string)
      use seq <- decode.optional_field("seq", 0, decode.int)
      use at <- decode.optional_field("at", 0, decode.int)
      use step <- decode.optional_field("step", 0, decode.int)
      use principal <- decode.field("principal_id", decode.string)
      use content <- decode.field("content", decode.string)
      decode.success(Some(Output(chat, seq, at, step, principal, content)))
    }
    "mark" -> {
      use label <- decode.field("label", decode.string)
      use at <- decode.optional_field("at", 0, decode.int)
      use step <- decode.optional_field("step", 0, decode.int)
      decode.success(Some(Mark(label, at, step)))
    }
    "secret" -> {
      use persona <- decode.field("persona", decode.string)
      use principal <- decode.field("principal_id", decode.string)
      use marker <- decode.field("marker", decode.string)
      use at <- decode.optional_field("at", 0, decode.int)
      decode.success(Some(Secret(persona, principal, marker, at)))
    }
    "turn_end" -> {
      use chat <- decode.optional_field("chat", "", decode.string)
      use session <- decode.optional_field("session", "", decode.string)
      use outcome <- decode.optional_field("outcome", "", decode.string)
      use at <- decode.optional_field("at", 0, decode.int)
      decode.success(Some(TurnEnd(chat, session, outcome, at)))
    }
    _ -> decode.success(None)
  }
}

/// Numbered transcript lines for the judge: `[12] bia: ...`.
pub fn numbered(events: List(Event)) -> List(String) {
  lines(events)
  |> list.index_map(fn(line, index) {
    "[" <> int.to_string(index + 1) <> "] " <> line
  })
}

pub fn lines(events: List(Event)) -> List(String) {
  events
  |> list.filter(fn(event) {
    case event {
      TurnEnd(..) -> False
      _ -> True
    }
  })
  |> list.map(render)
}

pub fn render(event: Event) -> String {
  case event {
    Input(_chat, _seq, _at, _step, persona, content) ->
      persona <> ": " <> content
    Output(_chat, _seq, _at, _step, principal, content) ->
      principal <> ": " <> content
    Mark(label, _at, _step) -> "--- " <> label <> " ---"
    Secret(persona, _principal, _marker, _at) ->
      persona <> " (segredo declarado)"
    TurnEnd(_chat, _session, _outcome, _at) -> ""
  }
}

pub fn numbered_lines_from(lines: List(String)) -> List(String) {
  list.index_map(lines, fn(line, index) {
    "[" <> int.to_string(index + 1) <> "] " <> line
  })
}
