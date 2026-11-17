import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/url_guard

pub fn main() {
  gleeunit.main()
}

pub fn allows_public_http_and_https_urls_test() {
  url_guard.validate_url("https://example.com/path?q=1")
  |> should.equal(Ok("https://example.com/path?q=1"))

  url_guard.validate_url("http://sub.domain.com:8080/a")
  |> should.equal(Ok("http://sub.domain.com:8080/a"))
}

pub fn blocks_non_http_schemes_test() {
  case url_guard.validate_url("file:///etc/passwd") {
    Ok(_) -> panic as "Expected non-http scheme to be blocked"
    Error(_) -> Nil
  }
}

pub fn blocks_internal_hosts_and_metadata_endpoints_test() {
  let blocked = [
    "http://localhost/admin",
    "http://127.0.0.1:3000",
    "http://127.10.1.1",
    "http://0.0.0.0",
    "http://10.1.2.3",
    "http://172.20.1.1",
    "http://192.168.1.10",
    "http://169.254.169.254",
    "http://metadata.google.internal",
    "http://metadata.google",
    "http://instance-data",
    "http://2852039166",
  ]

  blocked
  |> list.each(fn(url) { url_guard.validate_url(url) |> should.be_error })
}

pub fn strips_userinfo_before_blocklist_check_test() {
  case url_guard.validate_url("http://user:pass@127.0.0.1:8080/secret") {
    Ok(_) -> panic as "Expected userinfo URL to be blocked by host check"
    Error(_) -> Nil
  }
}

pub fn data_urls_are_allowed_only_in_allow_data_mode_test() {
  case url_guard.validate_url("data:text/plain,hello") {
    Ok(_) -> panic as "Expected data URL to be blocked in strict mode"
    Error(_) -> Nil
  }

  url_guard.validate_url_allow_data("data:text/plain,hello")
  |> should.equal(Ok("data:text/plain,hello"))
}
