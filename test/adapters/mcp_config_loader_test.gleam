//// Tests for MCP config loader.

import gleam/list
import gleam/string
import gleeunit/should
import supernova/adapters/mcp/config_loader

pub fn parse_servers_empty_test() {
  let servers = config_loader.parse_servers("")
  servers
  |> should.equal([])
}

pub fn parse_servers_with_mcp_servers_test() {
  let yaml =
    "
mcp_servers:
  filesystem:
    command: npx
    args: [\"-y\", \"@modelcontextprotocol/server-filesystem\"]
    env:
      NODE_ENV: production
  github:
    command: python3
    args: [\"server.py\"]
"

  let servers = config_loader.parse_servers(yaml)
  servers
  |> list.length
  |> should.equal(2)

  let names =
    servers
    |> list.map(fn(server) { server.name })
    |> list.sort(string.compare)

  names
  |> should.equal(["filesystem", "github"])
}

pub fn parse_servers_ignores_invalid_entries_test() {
  let yaml =
    "
mcp_servers:
  invalid:
    args: [\"-y\"]
  valid:
    command: npx
"

  let servers = config_loader.parse_servers(yaml)
  servers
  |> list.length
  |> should.equal(1)

  let assert [server] = servers
  server.name
  |> should.equal("valid")
}
