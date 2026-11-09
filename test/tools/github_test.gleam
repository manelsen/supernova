//// GitHub tool tests

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/tools/github

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn resolve_runtime_config_uses_yaml_values_without_env_overrides_test() {
  let config =
    github.resolve_runtime_config(
      "
github:
  token: \"ghp_yaml_token\"
  base_url: \"https://ghe.example.com/api/v3\"
",
      None,
      None,
    )

  config.token
  |> should.equal(Some("ghp_yaml_token"))
  config.base_url
  |> should.equal("https://ghe.example.com/api/v3")
}

pub fn resolve_runtime_config_prefers_environment_overrides_test() {
  let config =
    github.resolve_runtime_config(
      "
github:
  token: ghp_yaml_token
  base_url: https://ghe.example.com/api/v3
",
      Some("ghp_env_token"),
      Some("https://api.github.example/env"),
    )

  config.token
  |> should.equal(Some("ghp_env_token"))
  config.base_url
  |> should.equal("https://api.github.example/env")
}

pub fn decode_and_filter_repositories_test() {
  let body =
    "
[
  {
    \"full_name\": \"acme/supernova\",
    \"language\": \"Gleam\",
    \"topics\": [\"agents\", \"beam\"],
    \"updated_at\": \"2026-03-20T10:15:00Z\",
    \"html_url\": \"https://github.com/acme/supernova\",
    \"description\": \"AI OS\"
  },
  {
    \"full_name\": \"acme/legacy\",
    \"language\": \"Elixir\",
    \"topics\": [\"phoenix\"],
    \"updated_at\": \"2026-02-10T08:00:00Z\",
    \"html_url\": \"https://github.com/acme/legacy\",
    \"description\": \"Legacy app\"
  },
  {
    \"full_name\": \"acme/misc\",
    \"language\": null,
    \"topics\": [],
    \"updated_at\": \"2026-03-25T08:00:00Z\",
    \"html_url\": \"https://github.com/acme/misc\",
    \"description\": null
  }
]
"

  let assert Ok(repositories) = github.decode_repositories(body)
  repositories
  |> list.length
  |> should.equal(3)

  let filtered =
    github.filter_repositories(
      repositories,
      Some("gleam"),
      Some("agents"),
      Some("2026-03-01"),
    )

  let assert [repository] = filtered
  repository.full_name
  |> should.equal("acme/supernova")
}

pub fn render_repositories_includes_metadata_test() {
  let repositories = [
    github.Repository(
      full_name: "acme/supernova",
      language: Some("Gleam"),
      topics: ["agents", "beam"],
      updated_at: "2026-03-20T10:15:00Z",
      html_url: "https://github.com/acme/supernova",
      description: Some("AI OS"),
    ),
  ]

  let rendered = github.render_repositories(repositories)

  string.contains(rendered, "acme/supernova")
  |> should.equal(True)
  string.contains(rendered, "language=Gleam")
  |> should.equal(True)
  string.contains(rendered, "topics=agents,beam")
  |> should.equal(True)
}

pub fn render_repositories_empty_state_test() {
  github.render_repositories([])
  |> should.equal("No GitHub repositories matched the requested filters.")
}

pub fn tool_definition_exposes_expected_contract_test() {
  let tool = github.tool()

  tool.name |> should.equal("github")
  list.length(tool.parameters) |> should.equal(4)
}

pub fn execute_invalid_json_returns_error_test() {
  case github.execute("{") {
    Error(message) ->
      string.contains(message, "Invalid arguments for github")
      |> should.equal(True)
    Ok(_) -> should.fail()
  }
}

pub fn execute_rejects_unknown_action_test() {
  case github.execute("{\"action\":\"  LIST_REPOS  \"}") {
    Error(message) -> {
      string.contains(message, "action must be get_my_repos")
      |> should.equal(True)
      string.contains(message, "got list_repos")
      |> should.equal(True)
    }
    Ok(_) -> should.fail()
  }
}

pub fn decode_repositories_invalid_payload_returns_error_test() {
  case github.decode_repositories("{\"not\":\"an-array\"}") {
    Error(message) ->
      string.contains(message, "Invalid GitHub response")
      |> should.equal(True)
    Ok(_) -> should.fail()
  }
}

pub fn resolve_runtime_config_defaults_when_yaml_invalid_test() {
  let config =
    github.resolve_runtime_config("github: [", None, None)

  config.token |> should.equal(None)
  config.base_url |> should.equal("https://api.github.com")
}

pub fn filter_repositories_normalizes_language_topic_and_date_test() {
  let repositories = [
    github.Repository(
      full_name: "acme/matching",
      language: Some("Gleam"),
      topics: ["Agents", "Beam"],
      updated_at: "2026-03-01T00:00:00Z",
      html_url: "https://github.com/acme/matching",
      description: None,
    ),
    github.Repository(
      full_name: "acme/old",
      language: Some("Gleam"),
      topics: ["agents"],
      updated_at: "2026-02-28T23:59:59Z",
      html_url: "https://github.com/acme/old",
      description: None,
    ),
  ]

  let filtered =
    github.filter_repositories(
      repositories,
      Some("  GLEAM  "),
      Some("  agents "),
      Some("2026-03-01"),
    )

  let assert [repository] = filtered
  repository.full_name |> should.equal("acme/matching")
}

pub fn filter_repositories_rejects_missing_language_when_filtered_test() {
  let repositories = [
    github.Repository(
      full_name: "acme/no-language",
      language: None,
      topics: ["agents"],
      updated_at: "2026-03-20T10:15:00Z",
      html_url: "https://github.com/acme/no-language",
      description: None,
    ),
  ]

  github.filter_repositories(repositories, Some("gleam"), None, None)
  |> should.equal([])
}

pub fn render_repositories_uses_placeholders_for_missing_metadata_test() {
  let rendered =
    github.render_repositories([
      github.Repository(
        full_name: "acme/minimal",
        language: None,
        topics: [],
        updated_at: "2026-03-20T10:15:00Z",
        html_url: "https://github.com/acme/minimal",
        description: None,
      ),
    ])

  string.contains(rendered, "language=-") |> should.equal(True)
  string.contains(rendered, "topics=-") |> should.equal(True)
}
