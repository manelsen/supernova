import gleam/dynamic/decode
import gleam/json
import gleam/string
import gleeunit/should
import supernova/tools/browser

pub fn browser_session_round_trip_test() {
  let assert Ok(open_result) = browser.open(fixture_browser_page_url(), 5000)
  let #(session_id, title) = decode_open_result(open_result)
  title |> should.equal("Browser Test")

  let assert Ok(_) =
    browser.type_text(session_id, "#name", "Ada Lovelace", 5000)
  let assert Ok(_) = browser.click(session_id, "#save", 5000)

  let assert Ok(eval_result) =
    browser.evaluate(
      session_id,
      "document.querySelector('#status').textContent",
      5000,
    )
  decode_value_result(eval_result) |> should.equal("Ada Lovelace")

  let assert Ok(readable_result) = browser.extract_readable(session_id, 5000)
  let #(readable_title, readable_text) = decode_readable_result(readable_result)
  readable_title |> should.equal("Browser Test")
  string.contains(readable_text, "Readable Title") |> should.equal(True)
  string.contains(readable_text, "Readable body text.") |> should.equal(True)

  let assert Ok(screenshot_result) = browser.screenshot(session_id, 5000)
  should.equal(decode_screenshot_mime_type(screenshot_result), "image/png")
  should.equal(
    string.length(decode_screenshot_data(screenshot_result)) > 100,
    True,
  )

  let assert Ok(close_result) = browser.close(session_id)
  decode_closed_result(close_result) |> should.equal(True)
}

pub fn browser_timeout_cleans_up_session_test() {
  let assert Ok(open_result) = browser.open(fixture_browser_page_url(), 5000)
  let #(session_id, _) = decode_open_result(open_result)

  browser.evaluate(
    session_id,
    "new Promise(resolve => setTimeout(() => resolve('done'), 200))",
    10,
  )
  |> should.be_error

  case browser.close(session_id) {
    Ok(_) -> should.fail()
    Error(reason) ->
      string.contains(reason, "Unknown browser session") |> should.equal(True)
  }
}

fn fixture_browser_page_url() -> String {
  "data:text/html;base64,PCFkb2N0eXBlIGh0bWw+PGh0bWw+PGhlYWQ+PG1ldGEgY2hhcnNldD0idXRmLTgiPjx0aXRsZT5Ccm93c2VyIFRlc3Q8L3RpdGxlPjwvaGVhZD48Ym9keT48bWFpbj48YXJ0aWNsZT48aDE+UmVhZGFibGUgVGl0bGU8L2gxPjxwIGlkPSJjb3B5Ij5SZWFkYWJsZSBib2R5IHRleHQuPC9wPjwvYXJ0aWNsZT48aW5wdXQgaWQ9Im5hbWUiIHZhbHVlPSIiPjxidXR0b24gaWQ9InNhdmUiIG9uY2xpY2s9ImRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJyNzdGF0dXMnKS50ZXh0Q29udGVudD1kb2N1bWVudC5xdWVyeVNlbGVjdG9yKCcjbmFtZScpLnZhbHVlIj5TYXZlPC9idXR0b24+PGRpdiBpZD0ic3RhdHVzIj5pZGxlPC9kaXY+PC9tYWluPjwvYm9keT48L2h0bWw+"
}

fn decode_open_result(json_str: String) -> #(String, String) {
  let decoder = {
    use session_id <- decode.field("session_id", decode.string)
    use title <- decode.field("title", decode.string)
    decode.success(#(session_id, title))
  }

  let assert Ok(result) = json.parse(from: json_str, using: decoder)
  result
}

fn decode_value_result(json_str: String) -> String {
  let decoder = {
    use value <- decode.field("value", decode.string)
    decode.success(value)
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
