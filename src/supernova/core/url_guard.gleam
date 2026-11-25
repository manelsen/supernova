//// URL Guard — validates URLs to prevent SSRF attacks.
////
//// Only http and https. The host is checked as an address: a literal is
//// checked directly; a name is resolved (A and AAAA) and blocked when any
//// address is loopback, private, CGNAT, link-local, unique-local,
//// multicast, reserved, or an IPv4 address embedded in IPv6. Numeric
//// forms other than canonical ones (decimal, octal, hex, short dotted) and
//// single-label names (Docker service names) are blocked outright.
////
//// Residual risk: the name may resolve differently between this check and
//// the connection (DNS rebinding). The network layout is the defence
//// against that (PRD-E, risks).

import gleam/list
import gleam/string

type HostKind {
  Literal
  Ambiguous
  Name
}

@external(erlang, "supernova_url_guard_ffi", "host_kind")
fn host_kind(host: String) -> HostKind

@external(erlang, "supernova_url_guard_ffi", "resolve")
fn resolve(host: String) -> Result(List(String), Nil)

@external(erlang, "supernova_url_guard_ffi", "address_blocked")
fn address_blocked(address: String) -> Bool

/// Validate that a URL is safe to fetch (no SSRF).
pub fn validate_url(url: String) -> Result(String, String) {
  check(url, False, resolve)
}

/// Validate URL with optional data: scheme support (for browser tool).
pub fn validate_url_allow_data(url: String) -> Result(String, String) {
  check(url, True, resolve)
}

/// `validate_url` with the name resolution injected (tests).
pub fn validate_url_with_resolver(
  url: String,
  resolver: fn(String) -> Result(List(String), Nil),
) -> Result(String, String) {
  check(url, False, resolver)
}

fn check(
  url: String,
  allow_data: Bool,
  resolver: fn(String) -> Result(List(String), Nil),
) -> Result(String, String) {
  let lower = string.lowercase(url)
  case allow_data && string.starts_with(lower, "data:") {
    // data: URLs make no network request.
    True -> Ok(url)
    False ->
      case
        string.starts_with(lower, "http://")
        || string.starts_with(lower, "https://")
      {
        False -> Error("Blocked URL scheme (only http/https allowed): " <> url)
        True ->
          case host_allowed(extract_host(lower), resolver) {
            True -> Ok(url)
            False ->
              Error("Blocked URL targeting internal/reserved network: " <> url)
          }
      }
  }
}

fn host_allowed(
  host: String,
  resolver: fn(String) -> Result(List(String), Nil),
) -> Bool {
  case host {
    "" -> False
    _ ->
      case host_kind(host) {
        Literal -> !address_blocked(host)
        Ambiguous -> False
        Name ->
          case named_internal(host) {
            True -> False
            False ->
              case resolver(host) {
                Ok([_, ..] as addresses) ->
                  !list.any(addresses, address_blocked)
                _ -> False
              }
          }
      }
  }
}

/// Names that are internal whatever they resolve to.
fn named_internal(host: String) -> Bool {
  let host = case string.ends_with(host, ".") {
    True -> string.drop_end(host, 1)
    False -> host
  }
  !string.contains(host, ".")
  || host == "localhost"
  || string.ends_with(host, ".localhost")
  || string.ends_with(host, ".internal")
  || string.ends_with(host, ".local")
  || host == "metadata.google"
}

/// The host of an http(s) URL: after the scheme and userinfo, before the
/// port, path, query or fragment; IPv6 literals lose their brackets.
fn extract_host(url: String) -> String {
  let rest = case string.split_once(url, "://") {
    Ok(#(_, rest)) -> rest
    Error(_) -> url
  }
  let authority = take_until(rest, ["/", "?", "#", "\\"])
  let hostport = case string.split_once(reverse(authority), "@") {
    Ok(#(after_at, _)) -> reverse(after_at)
    Error(_) -> authority
  }
  case string.starts_with(hostport, "[") {
    True ->
      case string.split_once(string.drop_start(hostport, 1), "]") {
        Ok(#(inside, _)) -> inside
        Error(_) -> ""
      }
    False -> take_until(hostport, [":"]) |> string.trim
  }
}

fn reverse(s: String) -> String {
  string.reverse(s)
}

fn take_until(s: String, separators: List(String)) -> String {
  do_take_until(string.to_graphemes(s), separators, [])
}

fn do_take_until(
  chars: List(String),
  separators: List(String),
  acc: List(String),
) -> String {
  case chars {
    [c, ..rest] ->
      case list.contains(separators, c) {
        True -> string.concat(list.reverse(acc))
        False -> do_take_until(rest, separators, [c, ..acc])
      }
    [] -> string.concat(list.reverse(acc))
  }
}
