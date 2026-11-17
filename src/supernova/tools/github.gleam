//// GitHub Tool — authenticated repository listing for the current user.

import envoy
import gleam/dynamic/decode
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some, or, unwrap}
import gleam/order
import gleam/result
import gleam/string
import supernova/llm/provider
import yay

const default_api_base_url = "https://api.github.com"

const default_config_path = "supernova.yaml"

pub type Repository {
  Repository(
    full_name: String,
    language: Option(String),
    topics: List(String),
    updated_at: String,
    html_url: String,
    description: Option(String),
  )
}

pub type RuntimeConfig {
  RuntimeConfig(token: Option(String), base_url: String)
}

type GitHubArgs {
  GitHubArgs(
    action: String,
    language: Option(String),
    topic: Option(String),
    updated_since: Option(String),
  )
}

pub fn tool() -> provider.ToolDefinition {
  provider.new_tool(
    name: "github",
    description: "List repositories for the authenticated GitHub user",
    parameters: [
      provider.string_param("action", "Action: get_my_repos", True),
      provider.string_param(
        "language",
        "Optional language filter, for example Gleam or Rust",
        False,
      ),
      provider.string_param(
        "topic",
        "Optional repository topic/theme filter",
        False,
      ),
      provider.string_param(
        "updated_since",
        "Optional ISO date or timestamp filter, for example 2026-03-01",
        False,
      ),
    ],
  )
}

pub fn execute(args_json: String) -> Result(String, String) {
  case json.parse(from: args_json, using: github_args_decoder()) {
    Error(error) ->
      Error("Invalid arguments for github: " <> string.inspect(error))
    Ok(args) -> execute_args(args)
  }
}

pub fn decode_repositories(body: String) -> Result(List(Repository), String) {
  case json.parse(from: body, using: decode.list(repository_decoder())) {
    Ok(repositories) -> Ok(repositories)
    Error(error) -> Error("Invalid GitHub response: " <> string.inspect(error))
  }
}

pub fn filter_repositories(
  repositories: List(Repository),
  language_filter: Option(String),
  topic_filter: Option(String),
  updated_since_filter: Option(String),
) -> List(Repository) {
  let normalized_language = normalize_filter(language_filter)
  let normalized_topic = normalize_filter(topic_filter)
  let normalized_updated_since = normalize_since_filter(updated_since_filter)

  repositories
  |> list.filter(fn(repository) {
    matches_language(repository, normalized_language)
    && matches_topic(repository, normalized_topic)
    && matches_updated_since(repository, normalized_updated_since)
  })
}

pub fn render_repositories(repositories: List(Repository)) -> String {
  case repositories {
    [] -> "No GitHub repositories matched the requested filters."
    _ ->
      repositories
      |> list.map(render_repository)
      |> string.join("\n")
  }
}

pub fn resolve_runtime_config(
  yaml_string: String,
  env_token: Option(String),
  env_base_url: Option(String),
) -> RuntimeConfig {
  let #(yaml_token, yaml_base_url) = parse_runtime_config_from_yaml(yaml_string)

  RuntimeConfig(
    token: or(env_token, yaml_token),
    base_url: unwrap(env_base_url, unwrap(yaml_base_url, default_api_base_url)),
  )
}

fn execute_args(args: GitHubArgs) -> Result(String, String) {
  case normalize_action(args.action) {
    "get_my_repos" -> {
      use runtime_config <- result.try(load_runtime_config())
      use token <- result.try(require_token(runtime_config))
      use body <- result.try(fetch_my_repositories(
        token,
        runtime_config.base_url,
      ))
      use repositories <- result.try(decode_repositories(body))

      repositories
      |> filter_repositories(args.language, args.topic, args.updated_since)
      |> render_repositories
      |> Ok
    }
    other ->
      Error(
        "Invalid arguments for github: action must be get_my_repos (got "
        <> other
        <> ")",
      )
  }
}

fn github_args_decoder() -> decode.Decoder(GitHubArgs) {
  use action <- decode.field("action", decode.string)
  use language <- decode.optional_field(
    "language",
    None,
    decode.string |> decode.map(Some),
  )
  use topic <- decode.optional_field(
    "topic",
    None,
    decode.string |> decode.map(Some),
  )
  use updated_since <- decode.optional_field(
    "updated_since",
    None,
    decode.string |> decode.map(Some),
  )

  decode.success(GitHubArgs(
    action: action,
    language: language,
    topic: topic,
    updated_since: updated_since,
  ))
}

fn repository_decoder() -> decode.Decoder(Repository) {
  use full_name <- decode.field("full_name", decode.string)
  use language <- decode.optional_field(
    "language",
    None,
    decode.optional(decode.string),
  )
  use topics <- decode.optional_field("topics", [], decode.list(decode.string))
  use updated_at <- decode.field("updated_at", decode.string)
  use html_url <- decode.field("html_url", decode.string)
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )

  decode.success(Repository(
    full_name: full_name,
    language: language,
    topics: topics,
    updated_at: updated_at,
    html_url: html_url,
    description: description,
  ))
}

fn load_runtime_config() -> Result(RuntimeConfig, String) {
  let env_token = get_env("SUPERNOVA_GITHUB_TOKEN")
  let env_base_url = get_env("SUPERNOVA_GITHUB_BASE_URL")

  case yay.parse_file(default_config_path) {
    Ok([document]) -> {
      let #(yaml_token, yaml_base_url) =
        parse_runtime_config_root(yay.document_root(document))

      Ok(combine_runtime_config(
        yaml_token: yaml_token,
        yaml_base_url: yaml_base_url,
        env_token: env_token,
        env_base_url: env_base_url,
      ))
    }
    Ok(_) ->
      Ok(combine_runtime_config(
        yaml_token: None,
        yaml_base_url: None,
        env_token: env_token,
        env_base_url: env_base_url,
      ))
    Error(_) ->
      Ok(combine_runtime_config(
        yaml_token: None,
        yaml_base_url: None,
        env_token: env_token,
        env_base_url: env_base_url,
      ))
  }
}

fn get_env(key: String) -> Option(String) {
  case envoy.get(key) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn parse_runtime_config_from_yaml(
  yaml_string: String,
) -> #(Option(String), Option(String)) {
  case yay.parse_string(string.trim(yaml_string)) {
    Ok([document]) -> parse_runtime_config_root(yay.document_root(document))
    _ -> #(None, None)
  }
}

fn parse_runtime_config_root(
  root: yay.Node,
) -> #(Option(String), Option(String)) {
  case yay.select_sugar(root, "github") {
    Ok(node) -> #(
      extract_optional_string(node, "token"),
      extract_optional_string(node, "base_url"),
    )
    Error(_) -> #(None, None)
  }
}

fn combine_runtime_config(
  yaml_token yaml_token: Option(String),
  yaml_base_url yaml_base_url: Option(String),
  env_token env_token: Option(String),
  env_base_url env_base_url: Option(String),
) -> RuntimeConfig {
  RuntimeConfig(
    token: or(env_token, yaml_token),
    base_url: unwrap(env_base_url, unwrap(yaml_base_url, default_api_base_url)),
  )
}

fn extract_optional_string(node: yay.Node, key: String) -> Option(String) {
  case yay.extract_optional_string(node, key) {
    Ok(Some(value)) -> Some(value)
    _ -> None
  }
}

fn require_token(runtime_config: RuntimeConfig) -> Result(String, String) {
  case runtime_config.token {
    Some(token) -> Ok(token)
    None ->
      Error(
        "GitHub token not configured in supernova.yaml or SUPERNOVA_GITHUB_TOKEN",
      )
  }
}

fn fetch_my_repositories(
  token: String,
  base_url: String,
) -> Result(String, String) {
  let url = join_url(base_url, "/user/repos?per_page=100&sort=updated")

  case request.to(url) {
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Get)
        |> request.set_header("Authorization", "Bearer " <> token)
        |> request.set_header("Accept", "application/vnd.github+json")
        |> request.set_header("X-GitHub-Api-Version", "2022-11-28")
        |> request.set_header("User-Agent", "supernova/1.0")

      case hackney.send(req) {
        Ok(response) ->
          case response.status {
            200 -> Ok(response.body)
            status -> Error(format_api_error(status, response.body))
          }
        Error(_) -> Error("Network error connecting to GitHub")
      }
    }
    Error(_) -> Error("Invalid GitHub API URL: " <> url)
  }
}

fn format_api_error(status: Int, body: String) -> String {
  case json.parse(from: body, using: api_error_decoder()) {
    Ok(message) ->
      "GitHub API returned " <> string.inspect(status) <> ": " <> message
    Error(_) -> "GitHub API returned " <> string.inspect(status)
  }
}

fn api_error_decoder() -> decode.Decoder(String) {
  decode.field("message", decode.string, fn(message) { decode.success(message) })
}

fn normalize_action(action: String) -> String {
  action
  |> string.trim
  |> string.lowercase
}

fn normalize_filter(filter: Option(String)) -> Option(String) {
  case filter {
    Some(value) -> {
      let normalized = value |> string.trim |> string.lowercase
      case normalized == "" {
        True -> None
        False -> Some(normalized)
      }
    }
    None -> None
  }
}

fn normalize_since_filter(filter: Option(String)) -> Option(String) {
  case normalize_filter(filter) {
    Some(value) ->
      case string.length(value) {
        10 -> Some(value <> "t00:00:00z")
        _ -> Some(value)
      }
    None -> None
  }
}

fn matches_language(repository: Repository, filter: Option(String)) -> Bool {
  case filter {
    None -> True
    Some(expected) ->
      case repository.language {
        Some(language) -> string.lowercase(language) == expected
        None -> False
      }
  }
}

fn matches_topic(repository: Repository, filter: Option(String)) -> Bool {
  case filter {
    None -> True
    Some(expected) ->
      list.any(repository.topics, fn(topic) {
        string.lowercase(topic) == expected
      })
  }
}

fn matches_updated_since(
  repository: Repository,
  filter: Option(String),
) -> Bool {
  case filter {
    None -> True
    Some(expected) ->
      case string.compare(string.lowercase(repository.updated_at), expected) {
        order.Lt -> False
        order.Eq | order.Gt -> True
      }
  }
}

fn render_repository(repository: Repository) -> String {
  let language = unwrap(repository.language, "-")
  let topics = case repository.topics {
    [] -> "-"
    _ -> repository.topics |> string.join(",")
  }

  repository.full_name
  <> " | language="
  <> language
  <> " | updated="
  <> repository.updated_at
  <> " | topics="
  <> topics
  <> " | url="
  <> repository.html_url
}

fn join_url(base_url: String, path: String) -> String {
  case string.ends_with(base_url, "/") {
    True -> string.drop_end(base_url, 1) <> path
    False -> base_url <> path
  }
}
