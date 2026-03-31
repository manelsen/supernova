//// Tool Call Benchmark Tests.
////
//// Measures tool registry and dispatch overhead.
////
//// Run with: gleam test

import supernova/core/tool_registry
import supernova/llm/provider

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn timestamp() -> Int

fn ms_since(ts: Int) -> Int {
  timestamp() - ts
}

fn make_tool(tool_name: String) -> provider.ToolDefinition {
  provider.new_tool(name: tool_name, description: "Test tool", parameters: [
    provider.string_param("input", "Test input", True),
  ])
}

pub fn tool_registry_actor_start_bench() {
  let start = timestamp()
  let assert Ok(_) = tool_registry.start()
  let elapsed = ms_since(start)

  elapsed < 50
}

pub fn tool_registry_list_bench() {
  let assert Ok(registry) = tool_registry.start()
  let _ =
    tool_registry.register(registry, make_tool("safe_shell"), fn(_) { Ok("ok") })
  let _ =
    tool_registry.register(registry, make_tool("file_system"), fn(_) {
      Ok("ok")
    })
  let _ =
    tool_registry.register(registry, make_tool("web_fetch"), fn(_) { Ok("ok") })

  let start = timestamp()
  let _tools = tool_registry.list_tools(registry)
  let elapsed = ms_since(start)

  elapsed < 5
}

pub fn tool_registry_execute_bench() {
  let assert Ok(registry) = tool_registry.start()
  let _ =
    tool_registry.register(registry, make_tool("safe_shell"), fn(_) { Ok("ok") })

  let start = timestamp()
  let _ = tool_registry.execute(registry, "safe_shell", "echo test")
  let elapsed = ms_since(start)

  elapsed < 10
}
