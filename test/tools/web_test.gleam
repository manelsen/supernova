import gleeunit/should
import supernova/tools/web

pub fn web_fetch_blocks_metadata_endpoint_test() {
  web.fetch("http://169.254.169.254/latest/meta-data")
  |> should.be_error
}

pub fn web_fetch_blocks_localhost_test() {
  web.fetch("http://127.0.0.1:8080/admin")
  |> should.be_error
}

pub fn web_fetch_blocks_file_scheme_test() {
  web.fetch("file:///etc/passwd")
  |> should.be_error
}

pub fn web_tool_definition_test() {
  let tool = web.tool()
  tool.name |> should.equal("web_fetch")
}

fn allow(url: String) -> Result(String, String) {
  Ok(url)
}

pub fn a_page_comes_back_as_text_test() {
  web.fetch_with("https://example.com/", allow, fn(_, max) {
    max |> should.equal(web.max_body_bytes)
    Ok(#(200, <<"olá":utf8>>))
  })
  |> should.equal(Ok("olá"))
}

pub fn other_statuses_and_failures_are_errors_test() {
  web.fetch_with("https://example.com/", allow, fn(_, _) { Ok(#(302, <<>>)) })
  |> should.equal(Error("HTTP 302 from https://example.com/"))
  web.fetch_with("https://example.com/", allow, fn(_, _) { Error(web.TooLarge) })
  |> should.equal(Error("Page larger than 2 MB: https://example.com/"))
  web.fetch_with("https://example.com/", allow, fn(_, _) { Error(web.Network) })
  |> should.be_error
  web.fetch_with("https://example.com/", allow, fn(_, _) {
    Ok(#(200, <<0xff, 0xfe>>))
  })
  |> should.be_error
}

pub fn the_guard_runs_before_any_download_test() {
  web.fetch_with("http://10.0.0.1/", fn(_) { Error("blocked") }, fn(_, _) {
    panic as "no download for a blocked URL"
  })
  |> should.equal(Error("blocked"))
}
