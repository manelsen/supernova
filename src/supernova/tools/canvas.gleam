//// Canvas Tool — structured block canvas manipulation.
////
//// Scope definition for `US-013`:
//// - This tool manages a generic ordered canvas of blocks.
//// - It is not a pixel/graphics drawing API.
//// - It exists to let agents iteratively build, reorder, inspect, and prune
////   structured working surfaces such as plans, outlines, notes, or checklists.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/llm/provider

pub type CanvasDocument {
  CanvasDocument(title: String, blocks: List(CanvasBlock))
}

pub type CanvasBlock {
  CanvasBlock(id: String, kind: String, label: Option(String), content: String)
}

type CanvasArgs {
  CanvasArgs(
    action: String,
    canvas: Option(CanvasDocument),
    title: Option(String),
    block_id: Option(String),
    kind: Option(String),
    label: Option(String),
    content: Option(String),
    after_block_id: Option(String),
  )
}

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "canvas",
    description: "Manipulate a structured canvas of ordered blocks for notes, outlines, and plans",
    parameters: [
      provider.string_param(
        "action",
        "Canvas action: create, upsert_block, move_block, delete_block, render",
        True,
      ),
      provider.string_param("title", "Canvas title for create", False),
      provider.string_param("block_id", "Target block id", False),
      provider.string_param(
        "kind",
        "Block kind, for example note or checklist",
        False,
      ),
      provider.string_param("label", "Optional block label", False),
      provider.string_param("content", "Block content for upsert", False),
      provider.string_param(
        "after_block_id",
        "Optional anchor block id used for ordering",
        False,
      ),
    ],
  )
}

pub fn create_canvas(title: String) -> CanvasDocument {
  CanvasDocument(title: normalize_required_text(title), blocks: [])
}

pub fn decode_canvas(canvas_json: String) -> Result(CanvasDocument, String) {
  case json.parse(from: canvas_json, using: canvas_document_decoder()) {
    Ok(canvas) -> Ok(canvas)
    Error(error) -> Error("Invalid canvas JSON: " <> string.inspect(error))
  }
}

pub fn encode_canvas(canvas: CanvasDocument) -> String {
  json.object([
    #("title", json.string(canvas.title)),
    #("blocks", json.array(canvas.blocks, encode_block)),
  ])
  |> json.to_string
}

pub fn upsert_block(
  canvas: CanvasDocument,
  block: CanvasBlock,
  after_block_id: Option(String),
) -> Result(CanvasDocument, String) {
  let normalized = normalize_block(block)

  case after_block_id {
    Some(anchor_id) -> {
      let detached = remove_block_by_id(canvas.blocks, normalized.id)
      insert_after_id(detached, anchor_id, normalized)
      |> result.map(fn(blocks) {
        CanvasDocument(title: canvas.title, blocks: blocks)
      })
    }
    None ->
      Ok(CanvasDocument(
        title: canvas.title,
        blocks: upsert_in_place(canvas.blocks, normalized),
      ))
  }
}

pub fn delete_block(
  canvas: CanvasDocument,
  block_id: String,
) -> Result(CanvasDocument, String) {
  let normalized_id = normalize_required_text(block_id)

  case contains_block_id(canvas.blocks, normalized_id) {
    True ->
      Ok(CanvasDocument(
        title: canvas.title,
        blocks: remove_block_by_id(canvas.blocks, normalized_id),
      ))
    False -> Error("Unknown canvas block id: " <> normalized_id)
  }
}

pub fn move_block(
  canvas: CanvasDocument,
  block_id: String,
  after_block_id: Option(String),
) -> Result(CanvasDocument, String) {
  let normalized_id = normalize_required_text(block_id)
  use block <- result.try(find_block(canvas.blocks, normalized_id))
  let detached = remove_block_by_id(canvas.blocks, normalized_id)

  case after_block_id {
    None -> Ok(CanvasDocument(title: canvas.title, blocks: [block, ..detached]))
    Some(anchor_id) -> {
      let normalized_anchor = normalize_required_text(anchor_id)
      case normalized_anchor == normalized_id {
        True -> Ok(canvas)
        False ->
          insert_after_id(detached, normalized_anchor, block)
          |> result.map(fn(blocks) {
            CanvasDocument(title: canvas.title, blocks: blocks)
          })
      }
    }
  }
}

pub fn render_canvas(canvas: CanvasDocument) -> String {
  case canvas.blocks {
    [] -> "# " <> canvas.title <> "\n(empty canvas)"
    _ ->
      "# "
      <> canvas.title
      <> "\n"
      <> render_blocks(canvas.blocks, 1, [])
      |> string.trim
  }
}

pub fn execute(args_json: String) -> Result(String, String) {
  case json.parse(from: args_json, using: canvas_args_decoder()) {
    Ok(args) -> dispatch(args)
    Error(error) ->
      Error("Invalid arguments for canvas: " <> string.inspect(error))
  }
}

fn dispatch(args: CanvasArgs) -> Result(String, String) {
  let action = normalize_action(args.action)

  case action {
    "create" ->
      require_text(args.title, "title", action)
      |> result.map(create_canvas)
      |> result.map(encode_canvas)
    "upsert_block" -> {
      use canvas <- result.try(require_canvas(args.canvas, action))
      use block_id <- result.try(require_text(args.block_id, "block_id", action))
      use content <- result.try(require_text(args.content, "content", action))

      let block =
        CanvasBlock(
          id: block_id,
          kind: normalize_kind(args.kind),
          label: normalize_optional_text(args.label),
          content: content,
        )

      upsert_block(canvas, block, normalize_optional_text(args.after_block_id))
      |> result.map(encode_canvas)
    }
    "delete_block" -> {
      use canvas <- result.try(require_canvas(args.canvas, action))
      use block_id <- result.try(require_text(args.block_id, "block_id", action))

      delete_block(canvas, block_id)
      |> result.map(encode_canvas)
    }
    "move_block" -> {
      use canvas <- result.try(require_canvas(args.canvas, action))
      use block_id <- result.try(require_text(args.block_id, "block_id", action))

      move_block(canvas, block_id, normalize_optional_text(args.after_block_id))
      |> result.map(encode_canvas)
    }
    "render" ->
      require_canvas(args.canvas, action)
      |> result.map(render_canvas)
    _ -> Error("Invalid arguments for canvas: unknown action " <> action)
  }
}

fn canvas_args_decoder() -> decode.Decoder(CanvasArgs) {
  use action <- decode.field("action", decode.string)
  use canvas <- decode.optional_field(
    "canvas",
    None,
    canvas_document_decoder() |> decode.map(Some),
  )
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use block_id <- decode.optional_field(
    "block_id",
    None,
    decode.optional(decode.string),
  )
  use kind <- decode.optional_field(
    "kind",
    None,
    decode.optional(decode.string),
  )
  use label <- decode.optional_field(
    "label",
    None,
    decode.optional(decode.string),
  )
  use content <- decode.optional_field(
    "content",
    None,
    decode.optional(decode.string),
  )
  use after_block_id <- decode.optional_field(
    "after_block_id",
    None,
    decode.optional(decode.string),
  )

  decode.success(CanvasArgs(
    action: action,
    canvas: canvas,
    title: title,
    block_id: block_id,
    kind: kind,
    label: label,
    content: content,
    after_block_id: after_block_id,
  ))
}

fn canvas_document_decoder() -> decode.Decoder(CanvasDocument) {
  use title <- decode.field("title", decode.string)
  use blocks <- decode.field("blocks", decode.list(canvas_block_decoder()))
  decode.success(CanvasDocument(title: title, blocks: blocks))
}

fn canvas_block_decoder() -> decode.Decoder(CanvasBlock) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use label <- decode.field("label", decode.optional(decode.string))
  use content <- decode.field("content", decode.string)
  decode.success(CanvasBlock(id: id, kind: kind, label: label, content: content))
}

fn encode_block(block: CanvasBlock) -> json.Json {
  json.object([
    #("id", json.string(block.id)),
    #("kind", json.string(block.kind)),
    #("label", option_string_to_json(block.label)),
    #("content", json.string(block.content)),
  ])
}

fn option_string_to_json(value: Option(String)) -> json.Json {
  case value {
    Some(text) -> json.string(text)
    None -> json.null()
  }
}

fn require_canvas(
  canvas: Option(CanvasDocument),
  action: String,
) -> Result(CanvasDocument, String) {
  case canvas {
    Some(canvas) -> Ok(canvas)
    None -> Error("Invalid arguments for canvas: missing canvas for " <> action)
  }
}

fn require_text(
  value: Option(String),
  field_name: String,
  action: String,
) -> Result(String, String) {
  case value {
    Some(text) -> {
      let normalized = normalize_required_text(text)
      case normalized == "" {
        True ->
          Error(
            "Invalid arguments for canvas: missing "
            <> field_name
            <> " for "
            <> action,
          )
        False -> Ok(normalized)
      }
    }
    None ->
      Error(
        "Invalid arguments for canvas: missing "
        <> field_name
        <> " for "
        <> action,
      )
  }
}

fn normalize_block(block: CanvasBlock) -> CanvasBlock {
  CanvasBlock(
    id: normalize_required_text(block.id),
    kind: normalize_kind(Some(block.kind)),
    label: normalize_optional_text(block.label),
    content: normalize_required_text(block.content),
  )
}

fn normalize_kind(kind: Option(String)) -> String {
  case normalize_optional_text(kind) {
    Some(value) -> value
    None -> "note"
  }
}

fn normalize_optional_text(value: Option(String)) -> Option(String) {
  case value {
    Some(text) -> {
      let normalized = normalize_required_text(text)
      case normalized == "" {
        True -> None
        False -> Some(normalized)
      }
    }
    None -> None
  }
}

fn normalize_required_text(text: String) -> String {
  text |> string.trim
}

fn normalize_action(action: String) -> String {
  action |> normalize_required_text |> string.lowercase
}

fn contains_block_id(blocks: List(CanvasBlock), block_id: String) -> Bool {
  list.any(blocks, fn(block) { block.id == block_id })
}

fn find_block(
  blocks: List(CanvasBlock),
  block_id: String,
) -> Result(CanvasBlock, String) {
  case blocks {
    [] -> Error("Unknown canvas block id: " <> block_id)
    [block, ..rest] ->
      case block.id == block_id {
        True -> Ok(block)
        False -> find_block(rest, block_id)
      }
  }
}

fn remove_block_by_id(
  blocks: List(CanvasBlock),
  block_id: String,
) -> List(CanvasBlock) {
  list.filter(blocks, fn(block) { block.id != block_id })
}

fn upsert_in_place(
  blocks: List(CanvasBlock),
  block: CanvasBlock,
) -> List(CanvasBlock) {
  case blocks {
    [] -> [block]
    [current, ..rest] ->
      case current.id == block.id {
        True -> [block, ..rest]
        False -> [current, ..upsert_in_place(rest, block)]
      }
  }
}

fn insert_after_id(
  blocks: List(CanvasBlock),
  anchor_id: String,
  block: CanvasBlock,
) -> Result(List(CanvasBlock), String) {
  case blocks {
    [] -> Error("Unknown canvas anchor id: " <> anchor_id)
    [current, ..rest] ->
      case current.id == anchor_id {
        True -> Ok([current, block, ..rest])
        False ->
          insert_after_id(rest, anchor_id, block)
          |> result.map(fn(updated_rest) { [current, ..updated_rest] })
      }
  }
}

fn render_blocks(
  blocks: List(CanvasBlock),
  index: Int,
  acc: List(String),
) -> String {
  case blocks {
    [] -> acc |> list.reverse |> string.join("\n")
    [block, ..rest] ->
      render_blocks(rest, index + 1, [render_block(index, block), ..acc])
  }
}

fn render_block(index: Int, block: CanvasBlock) -> String {
  let prefix = int.to_string(index) <> ". [" <> block.kind <> "] "

  case block.label {
    Some(label) -> prefix <> label <> ": " <> block.content
    None -> prefix <> block.content
  }
}
