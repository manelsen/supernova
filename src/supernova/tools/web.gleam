//// Web Fetch — HTTP GET for fetching web content.
////
//// Fetches content from URLs with redirect following.

import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/result
import gleam/string
import supernova/core/url_guard
import supernova/llm/provider

/// Fetch content from a URL (with SSRF protection).
pub fn fetch(url: String) -> Result(String, String) {
  use validated_url <- result.try(url_guard.validate_url(url))
  case request.to(validated_url) {
    Ok(req) -> {
      let req = req |> request.set_method(http.Get)
      case hackney.send(req) {
        Ok(response) -> {
          case response.status {
            200 -> Ok(response.body)
            status ->
              Error("HTTP " <> string.inspect(status) <> " from " <> url)
          }
        }
        Error(_) -> Error("Network error fetching " <> url)
      }
    }
    Error(_) -> Error("Invalid URL: " <> url)
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
