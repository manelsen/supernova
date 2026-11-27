//// Web Fetch — HTTP GET for fetching web content.
////
//// Fetches content from URLs. Redirects are not followed: a redirect is an
//// error, so the URL guard sees every address the tool reaches.

import gleam/bit_array
import gleam/int
import gleam/result
import supernova/core/url_guard
import supernova/llm/provider

/// Largest body the tool reads (PRD-E, D2); a larger one is refused while
/// it arrives.
pub const max_body_bytes = 2_097_152

/// Why a download failed.
pub type GetError {
  TooLarge
  Network
  /// The name resolved to an internal address when the connection was
  /// about to open (Qwen 4, M7).
  Blocked
}

@external(erlang, "supernova_web_fetch_ffi", "get_public")
fn http_get(url: String, max_bytes: Int) -> Result(#(Int, BitArray), GetError)

/// Fetch content from a URL (with SSRF protection).
pub fn fetch(url: String) -> Result(String, String) {
  fetch_with(url, url_guard.validate_url, http_get)
}

/// `fetch` with the guard and the download injected (tests).
pub fn fetch_with(
  url: String,
  guard: fn(String) -> Result(String, String),
  get: fn(String, Int) -> Result(#(Int, BitArray), GetError),
) -> Result(String, String) {
  use validated_url <- result.try(guard(url))
  case get(validated_url, max_body_bytes) {
    Ok(#(200, body)) ->
      bit_array.to_string(body)
      |> result.replace_error("Response from " <> url <> " is not text")
    Ok(#(status, _)) ->
      Error("HTTP " <> int.to_string(status) <> " from " <> url)
    Error(TooLarge) -> Error("Page larger than 2 MB: " <> url)
    Error(Network) -> Error("Network error fetching " <> url)
    Error(Blocked) ->
      Error("Blocked URL targeting internal/reserved network: " <> url)
  }
}

/// Get the tool definition for Web Fetch.
pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "web_fetch",
    description: "Fetch content from a URL",
    parameters: [
      provider.string_param("url", "URL to fetch", True),
    ],
  )
}
