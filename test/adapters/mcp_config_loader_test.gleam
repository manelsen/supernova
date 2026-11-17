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

pub fn parse_servers_supports_scalar_coercions_and_env_values_test() {
  let yaml =
    "
mcp_servers:
  123:
    command: 42
    args: [\"-y\", 7, true, false, null]
    env:
      ENABLED: true
      RETRIES: 3
      EMPTY: null
"

  let servers = config_loader.parse_servers(yaml)
  servers
  |> list.length
  |> should.equal(1)

  let assert [server] = servers
  server.name |> should.equal("123")
  server.command |> should.equal("42")
  server.args |> should.equal(["-y", "7", "true", "false", ""])
  server.env
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> should.equal([#("EMPTY", ""), #("ENABLED", "true"), #("RETRIES", "3")])
}

pub fn parse_servers_returns_empty_for_invalid_shapes_test() {
  let yaml_without_map =
    "
mcp_servers:
  - name: nope
"
  config_loader.parse_servers(yaml_without_map) |> should.equal([])

  let yaml_with_invalid_args =
    "
mcp_servers:
  test:
    command: run
    args:
      nested: value
"
  let servers = config_loader.parse_servers(yaml_with_invalid_args)
  let assert [server] = servers
  server.args |> should.equal([])
}

pub fn parse_servers_from_file_handles_missing_file_test() {
  config_loader.parse_servers_from_file("/tmp/definitely-not-existing-supernova.yaml")
  |> should.equal([])
}

pub fn tool_definition_name_test() {
  config_loader.tool().name
  |> should.equal("mcp_config")
}
