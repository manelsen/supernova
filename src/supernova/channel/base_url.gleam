//// The base URL of a channel's API carries its secrets (a bot token in the
//// path, basic auth): it must be https, or plain http only to loopback or
//// to an internal host the operator lists in `channels.internal_hosts`
//// (a bridge in the same compose network). PRD-C, C-03.
////
//// This is not the SSRF guard of `core/url_guard`: these URLs come from
//// the operator and may well be internal on purpose.

import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/uri

pub fn check(
  field: String,
  base_url: String,
  internal_hosts: List(String),
) -> Result(Nil, String) {
  let inside = [
    "localhost",
    "127.0.0.1",
    ..list.map(internal_hosts, string.lowercase)
  ]
  let allowed = case uri.parse(string.trim(base_url)) {
    Ok(parsed) -> {
      let scheme = option.map(parsed.scheme, string.lowercase)
      let host = option.map(parsed.host, string.lowercase)
      case scheme, host {
        // The HTTP client cannot reach IPv6 literals: the brackets are lost
        // on the way to it.
        _, Some("") -> False
        Some("https"), Some(host) -> !string.contains(host, ":")
        Some("http"), Some(host) -> list.contains(inside, host)
        _, _ -> False
      }
    }
    Error(_) -> False
  }
  case allowed {
    True -> Ok(Nil)
    False ->
      Error(
        field
        <> " must be https, or http on localhost, 127.0.0.1 or a host listed in channels.internal_hosts; IPv6 literals are not supported, use a host name",
      )
  }
}
