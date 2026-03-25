import gleeunit/should
import supernova/adapters
import supernova/adapters/mcp_manager

pub fn adapters_facade_lists_mcp_tools_test() {
  let assert Ok(manager) = mcp_manager.start()

  adapters.list_mcp_tools(manager)
  |> should.equal([])

  mcp_manager.stop(manager)
}
