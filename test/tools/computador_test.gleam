import envoy
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import supernova/config
import supernova/config_check
import supernova/core/executor
import supernova/core/tool_dispatch
import supernova/llm/provider
import supernova/llm/tool_images
import supernova/tools/computador

@external(erlang, "computer_test_ffi", "serve_once")
fn serve_once(status: Int, body: String) -> Int

@external(erlang, "computer_test_ffi", "last_request")
fn last_request() -> String

const image = "data:image/jpeg;base64,/9j/AAAA"

fn with_url(url: String, run: fn() -> a) -> a {
  envoy.set("SUPERNOVA_COMPUTER_URL", url)
  let result = run()
  envoy.unset("SUPERNOVA_COMPUTER_URL")
  result
}

// --------------------------------------------------------------- requests

pub fn unknown_action_is_refused_test() {
  let assert Error(reason) =
    computador.build_request("{\"action\":\"formatar\"}")
  reason |> string.contains("Unknown computador action") |> should.be_true
}

pub fn missing_action_is_refused_test() {
  computador.build_request("{}") |> should.be_error
}

pub fn exec_needs_a_command_test() {
  let assert Error(reason) = computador.build_request("{\"action\":\"exec\"}")
  reason |> should.equal("computador exec needs command")
}

pub fn exec_timeout_is_clamped_and_waited_for_test() {
  let assert Ok(request) =
    computador.build_request(
      "{\"action\":\"exec\",\"command\":\"ls | wc -l\",\"timeout_s\":9999}",
    )
  request.body |> string.contains("\"op\":\"exec\"") |> should.be_true
  request.body
  |> string.contains("\"command\":\"ls | wc -l\"")
  |> should.be_true
  request.body |> string.contains("\"timeout_s\":300") |> should.be_true
  request.timeout_ms |> should.equal(315_000)
}

pub fn browser_request_carries_only_its_fields_test() {
  let assert Ok(request) =
    computador.build_request(
      "{\"action\":\"goto\",\"url\":\"https://example.com\",\"command\":null}",
    )
  request.body
  |> should.equal("{\"op\":\"goto\",\"url\":\"https://example.com\"}")
  request.timeout_ms |> should.equal(60_000)
}

pub fn click_needs_a_selector_or_a_point_test() {
  computador.build_request("{\"action\":\"click\"}") |> should.be_error
  computador.build_request("{\"action\":\"click\",\"x\":10}") |> should.be_error
  computador.build_request("{\"action\":\"click\",\"x\":10,\"y\":20}")
  |> should.be_ok
  computador.build_request("{\"action\":\"click\",\"selector\":\"#ok\"}")
  |> should.be_ok
}

// ---------------------------------------------------------------- answers

pub fn exec_answer_reads_as_data_test() {
  let assert Ok(text) =
    computador.render(
      200,
      "{\"ok\":true,\"exit_code\":2,\"timed_out\":false,\"truncated\":false,\"stdout\":\"oi\\n\",\"stderr\":\"aviso\"}",
      "",
    )
  text |> string.starts_with(computador.header) |> should.be_true
  text |> string.contains("código de saída 2") |> should.be_true
  text |> string.contains("--- stdout ---\noi\n") |> should.be_true
  text |> string.contains("--- stderr ---\naviso") |> should.be_true
}

pub fn exec_timeout_is_explained_test() {
  let assert Ok(text) =
    computador.render(
      200,
      "{\"ok\":true,\"exit_code\":-1,\"timed_out\":true,\"truncated\":true,\"stdout\":\"\",\"stderr\":\"\"}",
      "",
    )
  text |> string.contains("tempo esgotado") |> should.be_true
  text |> string.contains("saída cortada") |> should.be_true
}

pub fn refusal_by_the_service_is_an_answer_not_a_failure_test() {
  let assert Ok(text) =
    computador.render(200, "{\"ok\":false,\"error\":\"ENOENT: x\"}", "")
  text |> string.contains("Não deu certo: ENOENT: x") |> should.be_true
}

pub fn broken_service_is_a_tool_error_test() {
  computador.render(502, "<html>bad gateway</html>", "") |> should.be_error
  computador.render(401, "{\"ok\":false,\"error\":\"unauthorized\"}", "")
  |> should.be_error
}

pub fn screenshot_travels_as_an_attached_image_test() {
  let assert Ok(text) =
    computador.render(
      200,
      "{\"ok\":true,\"url\":\"https://a.b/\",\"title\":\"A\"}",
      image,
    )
  let #(shown, images) = tool_images.split(text)
  images |> should.equal([image])
  shown |> string.contains("\"title\":\"A\"") |> should.be_true
  shown |> string.contains("base64") |> should.be_false
}

// ------------------------------------------------------------- end to end

pub fn execute_without_a_computer_is_an_error_test() {
  envoy.unset("SUPERNOVA_COMPUTER_URL")
  let assert Error(reason) =
    computador.execute("telegram:1", "{\"action\":\"list\"}")
  reason |> string.contains("SUPERNOVA_COMPUTER_URL") |> should.be_true
}

pub fn execute_reports_an_unreachable_computer_test() {
  let assert Error(reason) =
    with_url("http://127.0.0.1:1", fn() {
      computador.execute("telegram:1", "{\"action\":\"list\"}")
    })
  reason |> string.starts_with("computador unreachable") |> should.be_true
}

pub fn execute_posts_to_the_service_and_splits_the_image_test() {
  let port =
    serve_once(
      200,
      "{\"ok\":true,\"url\":\"https://a.b/\",\"title\":\"A\",\"image\":\""
        <> image
        <> "\"}",
    )
  envoy.set("SUPERNOVA_COMPUTER_TOKEN", "t0k")
  let assert Ok(text) =
    with_url("http://127.0.0.1:" <> int.to_string(port) <> "/", fn() {
      computador.execute("telegram:1", "{\"action\":\"screenshot\"}")
    })
  envoy.unset("SUPERNOVA_COMPUTER_TOKEN")

  let request = last_request()
  request |> string.starts_with("POST /v1/run ") |> should.be_true
  request
  |> string.lowercase
  |> string.contains("authorization: bearer t0k")
  |> should.be_true
  request |> string.contains("{\"op\":\"screenshot\"}") |> should.be_true

  let #(shown, images) = tool_images.split(text)
  images |> should.equal([image])
  shown |> string.contains("\"title\":\"A\"") |> should.be_true
}

// ----------------------------------------------------------------- wiring

pub fn computer_is_offered_only_when_configured_test() {
  envoy.unset("SUPERNOVA_COMPUTER_URL")
  tool_dispatch.builtin_tools()
  |> list.any(fn(tool) { tool.name == "computador" })
  |> should.be_false

  with_url("http://computador:7070", fn() {
    tool_dispatch.builtin_tools()
    |> list.any(fn(tool) { tool.name == "computador" })
  })
  |> should.be_true
}

pub fn computer_needs_the_callers_identity_test() {
  tool_dispatch.execute("computador", "{\"action\":\"list\"}")
  |> should.equal(Error("computador needs the caller's identity"))
}

pub fn members_are_denied_the_computer_by_default_test() {
  config.default_capabilities_config().member.denied
  |> list.contains("computador")
  |> should.be_true
}

pub fn computer_is_a_known_capability_test() {
  config_check.known_tool_names()
  |> list.contains("computador")
  |> should.be_true
}

pub fn executor_moves_tool_images_into_a_user_message_test() {
  let context =
    executor.RunContext(
      ..executor.empty_run_context(),
      invoke_tool: Some(fn(_name, _args) {
        Ok(tool_images.attach("tela aberta", image))
      }),
    )
  let calls = [
    provider.ToolCall(
      id: "c1",
      name: "computador",
      arguments: "{\"action\":\"screenshot\"}",
    ),
  ]
  let messages =
    executor.execute_tool_calls_with_context_for_test(
      calls,
      [computador.tool()],
      context,
    )
  let assert [tool_message, image_message] = messages
  tool_message.role |> should.equal("tool")
  tool_message.content |> should.equal("tela aberta")
  tool_message.images |> should.equal([])
  image_message.role |> should.equal("user")
  image_message.content |> should.equal(tool_images.caption)
  image_message.images |> should.equal([image])
}

// Review of the computer PR: the service answers 200 or 400; anything else
// means it is not working, even with a JSON body.
pub fn unexpected_status_is_a_tool_error_test() {
  computador.render(503, "{\"ok\":false,\"error\":\"maintenance\"}", "")
  |> should.be_error
  computador.render(500, "{\"ok\":true}", "") |> should.be_error
  computador.render(400, "{\"ok\":false,\"error\":\"path is required\"}", "")
  |> should.equal(Ok(computador.header <> "\nNão deu certo: path is required"))
}

// Review of the computer PR: a blank selector would win over x/y in the
// service, so it is not sent.
pub fn blank_selector_is_not_sent_with_a_point_test() {
  let assert Ok(request) =
    computador.build_request(
      "{\"action\":\"click\",\"selector\":\" \",\"x\":10,\"y\":20}",
    )
  request.body |> should.equal("{\"op\":\"click\",\"x\":10,\"y\":20}")
}
