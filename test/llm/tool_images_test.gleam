import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import supernova/core/executor
import supernova/llm/provider
import supernova/llm/providers/openai
import supernova/llm/tool_images

const png = "data:image/png;base64,iVBORw0KGgo="

pub fn plain_text_has_no_images_test() {
  tool_images.split("só texto") |> should.equal(#("só texto", []))
}

pub fn attach_then_split_round_trips_test() {
  tool_images.attach("tela", png)
  |> tool_images.split
  |> should.equal(#("tela", [png]))
}

pub fn only_image_data_urls_survive_test() {
  let content = tool_images.attach(tool_images.attach("t", "javascript:x"), png)
  tool_images.split(content) |> should.equal(#("t", [png]))
}

pub fn no_images_no_message_test() {
  tool_images.message([]) |> should.equal([])
}

pub fn keep_recent_drops_older_images_test() {
  let shots =
    list.map([1, 2, 3], fn(_) {
      provider.user_message_with_images(tool_images.caption, [png])
    })
  let history = [provider.user_message("oi"), ..shots]
  let kept = tool_images.keep_recent(history, 2)

  kept
  |> list.map(fn(message) { list.length(message.images) })
  |> should.equal([0, 0, 1, 1])
  let assert [_, oldest, ..] = kept
  oldest.content |> string.contains("imagem antiga removida") |> should.be_true
}

pub fn tool_round_keeps_two_images_test() {
  let shot = provider.user_message_with_images(tool_images.caption, [png])
  executor.append_tool_round_for_test([shot, shot], [shot])
  |> list.map(fn(message) { list.length(message.images) })
  |> should.equal([0, 1, 1])
}

pub fn text_messages_encode_as_a_string_test() {
  openai.encode_content(provider.user_message("oi"))
  |> json.to_string
  |> should.equal("\"oi\"")
}

pub fn image_messages_encode_as_content_parts_test() {
  openai.encode_content(provider.user_message_with_images("veja", [png]))
  |> json.to_string
  |> should.equal(
    "[{\"type\":\"text\",\"text\":\"veja\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\""
    <> png
    <> "\"}}]",
  )
}

pub fn request_body_carries_the_image_test() {
  openai.build_request_body(
    [provider.user_message_with_images("veja", [png])],
    "m",
    [],
  )
  |> string.contains("\"image_url\":{\"url\":\"" <> png)
  |> should.be_true
}
