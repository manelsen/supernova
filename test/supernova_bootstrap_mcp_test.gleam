import gleam/list
import gleeunit/should
import supernova/adapters/mcp/config_loader

pub fn load_mcp_servers_from_file_test() {
  let servers = config_loader.parse_servers_from_file("supernova.yaml")
  servers
  |> list.length
  |> should.equal(0)
}
