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
