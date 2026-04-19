import gleam/string
import gleeunit/should
import supernova/core/error_ux
import supernova/core/executor
import supernova/llm/provider

pub fn friendly_translates_max_depth_test() {
  let text = error_ux.friendly(executor.MaxDepthExceeded(depth: 10))
  string.contains(text, "complexa demais") |> should.equal(True)
}

pub fn friendly_translates_rate_limit_test() {
  let text =
    error_ux.friendly(
      executor.LLMError(reason: provider.APIError(status: 429, message: "busy")),
    )
  string.contains(text, "sobrecarregado") |> should.equal(True)
}

pub fn friendly_translates_tool_error_test() {
  let text =
    error_ux.friendly(executor.ToolError(
      name: "shell",
      reason: "permission denied",
    ))
  string.contains(text, "ferramenta 'shell'") |> should.equal(True)
}
