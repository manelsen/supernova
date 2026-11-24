//// PRD-C, C-03: a channel's base URL carries its secrets (a token in the
//// URL, basic auth): https, or http only to loopback and to the internal
//// hosts the operator lists.

import gleeunit/should
import supernova/channel/base_url

pub fn https_anywhere_http_only_inside_test() {
  base_url.check("x.base_url", "https://bots.example.org", [])
  |> should.equal(Ok(Nil))
  base_url.check("x.base_url", "http://localhost:8081", [])
  |> should.equal(Ok(Nil))
  base_url.check("x.base_url", "http://127.0.0.1:8081", [])
  |> should.equal(Ok(Nil))
  base_url.check("x.base_url", "http://gowa:3000", ["gowa"])
  |> should.equal(Ok(Nil))
  base_url.check("x.base_url", "http://GOWA:3000", ["gowa"])
  |> should.equal(Ok(Nil))
}

pub fn everything_else_is_refused_naming_the_field_test() {
  let assert Error(reason) =
    base_url.check("whatsapp.bridge_url", "http://gowa:3000", [])
  reason
  |> should.equal(
    "whatsapp.bridge_url must be https, or http on localhost, 127.0.0.1 or a host listed in channels.internal_hosts; IPv6 literals are not supported, use a host name",
  )
  let assert Error(_) = base_url.check("f", "http://10.0.0.5:8081", ["gowa"])
  let assert Error(_) =
    base_url.check("f", "http://gowa:3000@remote.example", ["gowa"])
  let assert Error(_) = base_url.check("f", "ftp://localhost", [])
  let assert Error(_) = base_url.check("f", "not a url", [])
  let assert Error(_) = base_url.check("f", "http://[::1]:8081", [])
  let assert Error(_) = base_url.check("f", "https://[2001:db8::1]", [])
  let assert Error(_) = base_url.check("f", "https://", [])
}
