//// URL Guard — validates URLs to prevent SSRF attacks.
////
//// Blocks requests to internal networks, cloud metadata endpoints,
//// and non-HTTP schemes.

import gleam/string

/// Validate that a URL is safe to fetch (no SSRF).
/// Only allows http:// and https:// schemes to non-internal hosts.
pub fn validate_url(url: String) -> Result(String, String) {
  validate_url_with_schemes(url, False)
}

/// Validate URL with optional data: scheme support (for browser tool).
pub fn validate_url_allow_data(url: String) -> Result(String, String) {
  validate_url_with_schemes(url, True)
}

fn validate_url_with_schemes(
  url: String,
  allow_data: Bool,
) -> Result(String, String) {
  let lower = string.lowercase(url)

  // data: URLs don't make network requests — safe from SSRF
  case allow_data && string.starts_with(lower, "data:") {
    True -> Ok(url)
    False -> {
      // Block non-HTTP schemes
      case
        string.starts_with(lower, "http://")
        || string.starts_with(lower, "https://")
      {
        False -> Error("Blocked URL scheme (only http/https allowed): " <> url)
        True -> {
          // Extract host portion from URL
          let host = extract_host(lower)
          case is_blocked_host(host) {
            True ->
              Error("Blocked URL targeting internal/reserved network: " <> url)
            False -> Ok(url)
          }
        }
      }
    }
  }
}

/// Extract the host from a URL (after scheme, before port/path).
fn extract_host(url: String) -> String {
  url
  |> string.replace("https://", "")
  |> string.replace("http://", "")
  |> strip_userinfo
  |> take_until_port_or_path
  |> string.trim
}

fn strip_userinfo(host_and_path: String) -> String {
  case string.split_once(host_and_path, "@") {
    Ok(#(_, after_at)) -> after_at
    Error(_) -> host_and_path
  }
}

fn take_until_port_or_path(host_and_rest: String) -> String {
  host_and_rest
  |> split_first_of(":/")
}

fn split_first_of(s: String, separators: String) -> String {
  let chars = string.to_graphemes(s)
  let sep_chars = string.to_graphemes(separators)
  take_until_any(chars, sep_chars, "")
}

fn take_until_any(
  chars: List(String),
  seps: List(String),
  acc: String,
) -> String {
  case chars {
    [] -> acc
    [c, ..rest] ->
      case list_contains(seps, c) {
        True -> acc
        False -> take_until_any(rest, seps, acc <> c)
      }
  }
}

fn list_contains(items: List(String), target: String) -> Bool {
  case items {
    [] -> False
    [item, ..rest] ->
      case item == target {
        True -> True
        False -> list_contains(rest, target)
      }
  }
}

/// Check if a host is in the SSRF blocklist.
fn is_blocked_host(host: String) -> Bool {
  // Loopback
  host == "localhost"
  || host == "127.0.0.1"
  || string.starts_with(host, "127.")
  || host == "[::1]"
  || host == "0.0.0.0"
  // Private networks (RFC 1918)
  || string.starts_with(host, "10.")
  || starts_with_172_private(host)
  || string.starts_with(host, "192.168.")
  // Link-local
  || string.starts_with(host, "169.254.")
  // Cloud metadata endpoints
  || host == "metadata.google.internal"
  || host == "metadata.google"
  // Decimal IP for 169.254.169.254
  || host == "2852039166"
  // Common metadata alias
  || host == "instance-data"
}

/// Check for 172.16.0.0/12 range (172.16.x - 172.31.x)
fn starts_with_172_private(host: String) -> Bool {
  string.starts_with(host, "172.16.")
  || string.starts_with(host, "172.17.")
  || string.starts_with(host, "172.18.")
  || string.starts_with(host, "172.19.")
  || string.starts_with(host, "172.20.")
  || string.starts_with(host, "172.21.")
  || string.starts_with(host, "172.22.")
  || string.starts_with(host, "172.23.")
  || string.starts_with(host, "172.24.")
  || string.starts_with(host, "172.25.")
  || string.starts_with(host, "172.26.")
  || string.starts_with(host, "172.27.")
  || string.starts_with(host, "172.28.")
  || string.starts_with(host, "172.29.")
  || string.starts_with(host, "172.30.")
  || string.starts_with(host, "172.31.")
}
