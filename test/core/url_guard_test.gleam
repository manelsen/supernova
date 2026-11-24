import gleam/list
import gleeunit
import gleeunit/should
import supernova/core/url_guard

pub fn main() {
  gleeunit.main()
}

pub fn allows_public_http_and_https_urls_test() {
  let public = fn(_) { Ok(["93.184.215.14"]) }
  url_guard.validate_url_with_resolver("https://example.com/path?q=1", public)
  |> should.equal(Ok("https://example.com/path?q=1"))

  url_guard.validate_url_with_resolver("http://sub.domain.com:8080/a", public)
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

// PRD-E, E-02: the guard resolves the name and checks every address.

fn resolves_to(
  addresses: List(String),
) -> fn(String) -> Result(List(String), Nil) {
  fn(_) { Ok(addresses) }
}

pub fn a_name_resolving_to_an_internal_address_is_blocked_test() {
  [
    ["127.0.0.1"],
    ["10.0.0.5"],
    ["172.18.0.3"],
    ["192.168.0.1"],
    ["100.64.1.1"],
    ["169.254.169.254"],
    ["0.1.2.3"],
    ["224.0.0.1"],
    ["::1"],
    ["fe80::1"],
    ["fd12:3456::1"],
    ["::ffff:10.0.0.1"],
    ["64:ff9b::a00:1"],
    ["2002:a00:1::1"],
    ["8.8.8.8", "10.0.0.1"],
  ]
  |> list.each(fn(addresses) {
    url_guard.validate_url_with_resolver(
      "https://rebind.example.com/x",
      resolves_to(addresses),
    )
    |> should.be_error
  })
}

pub fn a_name_resolving_to_public_addresses_passes_test() {
  url_guard.validate_url_with_resolver(
    "https://example.com/x",
    resolves_to(["93.184.215.14", "2606:2800:21f:cb07:6820:80da:af6b:8b2c"]),
  )
  |> should.equal(Ok("https://example.com/x"))
}

pub fn a_name_that_does_not_resolve_is_blocked_test() {
  url_guard.validate_url_with_resolver("https://nowhere.example/x", fn(_) {
    Error(Nil)
  })
  |> should.be_error
  url_guard.validate_url_with_resolver(
    "https://nowhere.example/x",
    resolves_to([]),
  )
  |> should.be_error
}

pub fn ambiguous_numeric_hosts_are_blocked_test() {
  ["http://0177.0.0.1", "http://0x7f.1", "http://127.1", "http://2130706433"]
  |> list.each(fn(url) {
    url_guard.validate_url_with_resolver(url, resolves_to(["8.8.8.8"]))
    |> should.be_error
  })
}

pub fn single_label_names_are_internal_test() {
  ["http://grafana:3000", "http://prometheus:9090/api", "http://computador"]
  |> list.each(fn(url) {
    url_guard.validate_url_with_resolver(url, resolves_to(["8.8.8.8"]))
    |> should.be_error
  })
}

pub fn bracketed_ipv6_literals_are_checked_test() {
  url_guard.validate_url_with_resolver("http://[::1]:8080/", resolves_to([]))
  |> should.be_error
  url_guard.validate_url_with_resolver(
    "http://[::ffff:127.0.0.1]/",
    resolves_to([]),
  )
  |> should.be_error
  url_guard.validate_url_with_resolver(
    "http://[2606:4700::1111]/",
    resolves_to([]),
  )
  |> should.equal(Ok("http://[2606:4700::1111]/"))
}

pub fn a_public_ip_literal_needs_no_resolution_test() {
  url_guard.validate_url_with_resolver("https://8.8.8.8/dns", fn(_) {
    panic as "a literal is not resolved"
  })
  |> should.equal(Ok("https://8.8.8.8/dns"))
}

pub fn malformed_and_reserved_hosts_are_blocked_test() {
  [
    "http:///x",
    "http://[::1",
    "http://app.localhost./",
    "http://db.internal/",
    "http://printer.local/",
    "http://user@[fe80::1]/",
  ]
  |> list.each(fn(url) {
    url_guard.validate_url_with_resolver(url, resolves_to(["8.8.8.8"]))
    |> should.be_error
  })
}
