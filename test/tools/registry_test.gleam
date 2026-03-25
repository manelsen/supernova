//// Tests for the Tool Registry.

import gleeunit/should
import supernova/core/tool_registry
import supernova/llm/provider

pub fn register_and_list_test() {
  let assert Ok(reg) = tool_registry.start()

  let tool =
    provider.new_tool(name: "echo", description: "Echo input", parameters: [
      provider.string_param("text", "Text to echo", True),
    ])

  let assert Ok(Nil) =
    tool_registry.register(reg, tool, fn(_args) { Ok("echoed") })

  let tools = tool_registry.list_tools(reg)
  tools
  |> should.equal(["echo"])
}

pub fn register_multiple_tools_test() {
  let assert Ok(reg) = tool_registry.start()

  let t1 = provider.new_tool(name: "a", description: "A", parameters: [])
  let t2 = provider.new_tool(name: "b", description: "B", parameters: [])

  let assert Ok(Nil) = tool_registry.register(reg, t1, fn(_) { Ok("a") })
  let assert Ok(Nil) = tool_registry.register(reg, t2, fn(_) { Ok("b") })

  let tools = tool_registry.list_tools(reg)
  tools
  |> should.equal(["a", "b"])
}

pub fn execute_tool_test() {
  let assert Ok(reg) = tool_registry.start()

  let tool =
    provider.new_tool(name: "add", description: "Add numbers", parameters: [
      provider.integer_param("a", "First", True),
      provider.integer_param("b", "Second", True),
    ])

  let assert Ok(Nil) =
    tool_registry.register(reg, tool, fn(args) { Ok("result: " <> args) })

  let result = tool_registry.execute(reg, "add", "{\"a\":1,\"b\":2}")
  result
  |> should.be_ok
}

pub fn execute_nonexistent_tool_test() {
  let assert Ok(reg) = tool_registry.start()

  let result = tool_registry.execute(reg, "nope", "{}")
  result
  |> should.be_error
}

pub fn get_tool_spec_test() {
  let assert Ok(reg) = tool_registry.start()

  let tool =
    provider.new_tool(name: "test", description: "Test tool", parameters: [
      provider.string_param("x", "X", True),
    ])

  let assert Ok(Nil) = tool_registry.register(reg, tool, fn(_) { Ok("ok") })

  let result = tool_registry.get_tool(reg, "test")
  case result {
    Ok(spec) -> {
      spec.name
      |> should.equal("test")
    }
    Error(_) -> should.fail()
  }
}

pub fn get_nonexistent_tool_test() {
  let assert Ok(reg) = tool_registry.start()

  let result = tool_registry.get_tool(reg, "ghost")
  result
  |> should.be_error
}
