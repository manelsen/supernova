import envoy
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/string
import gleeunit/should
import supernova/tools/browser
import test_env

pub fn browser_evaluate_disabled_by_default_without_ffi_test() {
  use <- test_env.without_env("SUPERNOVA_BROWSER_ALLOW_EVALUATE")
  browser.set_evaluate_allowed(False)

  browser.evaluate("nonexistent-session", "1 + 1", 5000)
  |> should.equal(Error("browser evaluate is disabled by configuration"))

  browser.execute(
    "{\"operation\":\"evaluate\",\"session_id\":\"nonexistent-session\",\"script\":\"1 + 1\"}",
  )
  |> should.equal(Error("browser evaluate is disabled by configuration"))
}

pub fn browser_evaluate_enabled_via_config_reaches_runner_test() {
  use <- test_env.without_env("SUPERNOVA_BROWSER_ALLOW_EVALUATE")
  browser.set_evaluate_allowed(True)

  let assert Error(reason) =
    browser.evaluate("nonexistent-session", "1 + 1", 5000)
  let _ =
    reason |> should.not_equal("browser evaluate is disabled by configuration")

  let assert Error(exec_reason) =
    browser.execute_with_config(
      "{\"operation\":\"evaluate\",\"session_id\":\"nonexistent-session\",\"script\":\"1 + 1\"}",
      True,
    )
  exec_reason
  |> should.not_equal("browser evaluate is disabled by configuration")

  browser.set_evaluate_allowed(False)
}

pub fn browser_evaluate_enabled_via_env_reaches_runner_test() {
  browser.set_evaluate_allowed(False)
  use <- test_env.with_env("SUPERNOVA_BROWSER_ALLOW_EVALUATE", "true")

  let assert Error(reason) =
    browser.evaluate("nonexistent-session", "1 + 1", 5000)
  reason |> should.not_equal("browser evaluate is disabled by configuration")

  let assert Error(exec_reason) =
    browser.execute(
      "{\"operation\":\"evaluate\",\"session_id\":\"nonexistent-session\",\"script\":\"1 + 1\"}",
    )
  exec_reason
  |> should.not_equal("browser evaluate is disabled by configuration")
}

pub fn browser_open_blocks_ssrf_urls_before_ffi_test() {
  browser.open("http://169.254.169.254/latest/meta-data", 5000)
  |> should.be_error

  browser.open("http://127.0.0.1:8080/admin", 5000)
  |> should.be_error

  browser.open("file:///etc/passwd", 5000)
  |> should.be_error
}

pub fn browser_decoders_and_validation_test() {
  decode_open_result("{\"session_id\":\"s-1\",\"title\":\"Page\"}")
  |> should.equal("s-1")

  decode_readable_result("{\"title\":\"Browser Test\",\"text\":\"Hello\"}")
  |> should.equal(#("Browser Test", "Hello"))

  decode_screenshot_mime_type("{\"mime_type\":\"image/png\"}")
  |> should.equal("image/png")

  decode_screenshot_data("{\"data_base64\":\"abc123\"}")
  |> should.equal("abc123")

  decode_closed_result("{\"closed\":true}")
  |> should.equal(True)

  browser.execute("{\"operation\":\"unknown_op\"}")
  |> should.equal(Error(
    "Invalid arguments for browser: unknown operation unknown_op",
  ))

  let tool = browser.tool()
  tool.name |> should.equal("browser")
}

fn real_browser_tests_enabled() -> Bool {
  case envoy.get("SUPERNOVA_BROWSER_TESTS") {
    Ok("1") -> True
    _ -> False
  }
}

pub fn browser_session_round_trip_test() {
  case real_browser_tests_enabled() {
    False -> io.println("skipped: set SUPERNOVA_BROWSER_TESTS=1")
    True -> {
      let assert Ok(open_result) =
        browser.open(fixture_browser_page_url(), 5000)
      let session_id = decode_open_result(open_result)

      let assert Ok(readable_result) =
        browser.extract_readable(session_id, 5000)
      let #(readable_title, readable_text) =
        decode_readable_result(readable_result)
      readable_title |> should.equal("Browser Test")
      string.contains(readable_text, "Readable Title") |> should.equal(True)
      string.contains(readable_text, "Readable body text.")
      |> should.equal(True)

      let assert Ok(screenshot_result) = browser.screenshot(session_id, 5000)
      should.equal(decode_screenshot_mime_type(screenshot_result), "image/png")
      should.equal(
        string.length(decode_screenshot_data(screenshot_result)) > 100,
        True,
      )

      let assert Ok(close_result) = browser.close(session_id)
      decode_closed_result(close_result) |> should.equal(True)
    }
  }
}

pub fn browser_timeout_cleans_up_session_test() {
  case real_browser_tests_enabled() {
    False -> io.println("skipped: set SUPERNOVA_BROWSER_TESTS=1")
    True -> {
      let assert Ok(open_result) =
        browser.open(fixture_browser_page_url(), 5000)
      let session_id = decode_open_result(open_result)

      browser.evaluate_with_config(
        session_id,
        "new Promise(resolve => setTimeout(() => resolve('done'), 200))",
        10,
        True,
      )
      |> should.be_error

      case browser.close(session_id) {
        Ok(_) -> should.fail()
        Error(reason) ->
          string.contains(reason, "Unknown browser session")
          |> should.equal(True)
      }
    }
  }
}

fn fixture_browser_page_url() -> String {
  "data:text/html;base64,PCFkb2N0eXBlIGh0bWw+PGh0bWw+PGhlYWQ+PG1ldGEgY2hhcnNldD0idXRmLTgiPjx0aXRsZT5Ccm93c2VyIFRlc3Q8L3RpdGxlPjwvaGVhZD48Ym9keT48bWFpbj48YXJ0aWNsZT48aDE+UmVhZGFibGUgVGl0bGU8L2gxPjxwIGlkPSJjb3B5Ij5SZWFkYWJsZSBib2R5IHRleHQuPC9wPjwvYXJ0aWNsZT48aW5wdXQgaWQ9Im5hbWUiIHZhbHVlPSIiPjxidXR0b24gaWQ9InNhdmUiIG9uY2xpY2s9ImRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJyNzdGF0dXMnKS50ZXh0Q29udGVudD1kb2N1bWVudC5xdWVyeVNlbGVjdG9yKCcjbmFtZScpLnZhbHVlIj5TYXZlPC9idXR0b24+PGRpdiBpZD0ic3RhdHVzIj5pZGxlPC9kaXY+PC9tYWluPjwvYm9keT48L2h0bWw+"
}

fn decode_open_result(json_str: String) -> String {
  let decoder = {
    use session_id <- decode.field("session_id", decode.string)
    decode.success(session_id)
  }

  let assert Ok(result) = json.parse(from: json_str, using: decoder)
  result
}

fn decode_readable_result(json_str: String) -> #(String, String) {
  let decoder = {
    use title <- decode.field("title", decode.string)
    use text <- decode.field("text", decode.string)
    decode.success(#(title, text))
  }

  let assert Ok(result) = json.parse(from: json_str, using: decoder)
  result
}

fn decode_screenshot_mime_type(json_str: String) -> String {
  let decoder = {
    use mime_type <- decode.field("mime_type", decode.string)
    decode.success(mime_type)
  }

  let assert Ok(result) = json.parse(from: json_str, using: decoder)
  result
}

fn decode_screenshot_data(json_str: String) -> String {
  let decoder = {
    use data_base64 <- decode.field("data_base64", decode.string)
    decode.success(data_base64)
  }

  let assert Ok(result) = json.parse(from: json_str, using: decoder)
  result
}

fn decode_closed_result(json_str: String) -> Bool {
  let decoder = {
    use closed <- decode.field("closed", decode.bool)
    decode.success(closed)
  }

  let assert Ok(result) = json.parse(from: json_str, using: decoder)
  result
}
