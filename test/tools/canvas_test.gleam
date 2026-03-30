//// Canvas tool tests

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/tools/canvas

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn create_upsert_move_delete_round_trip_test() {
  let base = canvas.create_canvas("Planning")

  let assert Ok(with_goal) =
    canvas.upsert_block(
      base,
      canvas.CanvasBlock(
        id: "goal",
        kind: "note",
        label: Some("Goal"),
        content: "Ship the canvas tool",
      ),
      None,
    )

  let assert Ok(with_tasks) =
    canvas.upsert_block(
      with_goal,
      canvas.CanvasBlock(
        id: "tasks",
        kind: "checklist",
        label: Some("Tasks"),
        content: "Write tests first",
      ),
      None,
    )

  let assert Ok(moved) = canvas.move_block(with_tasks, "tasks", None)
  let assert Ok(pruned) = canvas.delete_block(moved, "goal")

  pruned.blocks
  |> list.length
  |> should.equal(1)

  let assert [block] = pruned.blocks
  block.id
  |> should.equal("tasks")
}

pub fn render_and_execute_round_trip_test() {
  let created = canvas.create_canvas("Planning")

  let args =
    "{\"action\":\"upsert_block\",\"canvas\":"
    <> canvas.encode_canvas(created)
    <> ",\"block_id\":\"goal\",\"kind\":\"note\",\"label\":\"Goal\",\"content\":\"Ship the canvas tool\"}"

  let assert Ok(updated_json) = canvas.execute(args)

  let render_args = "{\"action\":\"render\",\"canvas\":" <> updated_json <> "}"

  let assert Ok(rendered) = canvas.execute(render_args)

  string.contains(rendered, "# Planning")
  |> should.equal(True)
  string.contains(rendered, "[note] Goal: Ship the canvas tool")
  |> should.equal(True)
}

pub fn move_block_requires_existing_anchor_test() {
  let base = canvas.create_canvas("Planning")

  let assert Ok(with_goal) =
    canvas.upsert_block(
      base,
      canvas.CanvasBlock(
        id: "goal",
        kind: "note",
        label: Some("Goal"),
        content: "Ship the canvas tool",
      ),
      None,
    )

  canvas.move_block(with_goal, "goal", Some("missing"))
  |> should.be_error()
}
