//// Environment variables override supernova.yaml: what the compose file
//// passes from .env is what the pilot runs with.

import envoy
import exception
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/config

/// Set variables for the body and put back what was there before.
fn with_env(pairs: List(#(String, String)), body: fn() -> a) -> a {
  let previous = list.map(pairs, fn(pair) { #(pair.0, envoy.get(pair.0)) })
  use <- exception.defer(fn() {
    list.each(previous, fn(pair) {
      case pair.1 {
        Ok(value) -> envoy.set(pair.0, value)
        Error(_) -> envoy.unset(pair.0)
      }
    })
  })
  list.each(pairs, fn(pair) { envoy.set(pair.0, pair.1) })
  body()
}

fn yaml(text: String) -> config.Config {
  let assert Ok(cfg) = config.parse_yaml(text)
  cfg
}

pub fn every_channel_takes_its_settings_from_the_environment_test() {
  use <- with_env([
    #("SUPERNOVA_APP_NAME", "piloto"),
    #("SUPERNOVA_ENVIRONMENT", "production"),
    #("SUPERNOVA_LOG_LEVEL", "debug"),
    #("SUPERNOVA_DATA_DIR", "/data"),
    #("SUPERNOVA_DISCORD_TOKEN", "d-token"),
    #("SUPERNOVA_DISCORD_APP_ID", "d-app"),
    #("SUPERNOVA_DISCORD_ENABLED", "true"),
    #("SUPERNOVA_MATRIX_HOMESERVER_URL", "https://matrix.example"),
    #("SUPERNOVA_MATRIX_TOKEN", "m-token"),
    #("SUPERNOVA_MATRIX_ENABLED", "true"),
    #("SUPERNOVA_LARK_TOKEN", "l-token"),
    #("SUPERNOVA_LARK_BASE_URL", "https://lark.example"),
    #("SUPERNOVA_LARK_ENABLED", "true"),
    #("SUPERNOVA_GOOGLE_CHAT_WEBHOOK_URL", "https://chat.example/hook"),
    #("SUPERNOVA_GOOGLE_CHAT_ENABLED", "true"),
    #("SUPERNOVA_SLACK_TOKEN", "s-token"),
    #("SUPERNOVA_SLACK_ENABLED", "true"),
    #("SUPERNOVA_MATTERMOST_TOKEN", "mm-token"),
    #("SUPERNOVA_MATTERMOST_BASE_URL", "https://mm.example"),
    #("SUPERNOVA_MATTERMOST_ENABLED", "true"),
    #("SUPERNOVA_WECHAT_WORK_WEBHOOK_URL", "https://wechat.example/hook"),
    #("SUPERNOVA_WECHAT_WORK_ENABLED", "true"),
    #("SUPERNOVA_WHATSAPP_BRIDGE_URL", "http://bridge:8080"),
    #("SUPERNOVA_WHATSAPP_DEVICE_ID", "device-1"),
    #("SUPERNOVA_WHATSAPP_ENABLED", "true"),
  ])
  let cfg = config.apply_env_overrides(yaml("data_dir: data\n"))
  cfg.app_name |> should.equal("piloto")
  cfg.environment |> should.equal("production")
  cfg.log_level |> should.equal("debug")
  cfg.data_dir |> should.equal("/data")
  cfg.discord.token |> should.equal(Some("d-token"))
  cfg.discord.app_id |> should.equal(Some("d-app"))
  cfg.discord.enabled |> should.equal(True)
  cfg.matrix.homeserver_url |> should.equal(Some("https://matrix.example"))
  cfg.matrix.token |> should.equal(Some("m-token"))
  cfg.matrix.enabled |> should.equal(True)
  cfg.lark.token |> should.equal(Some("l-token"))
  cfg.lark.base_url |> should.equal(Some("https://lark.example"))
  cfg.lark.enabled |> should.equal(True)
  cfg.google_chat.webhook_url |> should.equal(Some("https://chat.example/hook"))
  cfg.google_chat.enabled |> should.equal(True)
  cfg.slack.token |> should.equal(Some("s-token"))
  cfg.slack.enabled |> should.equal(True)
  cfg.mattermost.token |> should.equal(Some("mm-token"))
  cfg.mattermost.base_url |> should.equal(Some("https://mm.example"))
  cfg.mattermost.enabled |> should.equal(True)
  cfg.wechat_work.webhook_url
  |> should.equal(Some("https://wechat.example/hook"))
  cfg.wechat_work.enabled |> should.equal(True)
  cfg.whatsapp.bridge_url |> should.equal(Some("http://bridge:8080"))
  cfg.whatsapp.device_id |> should.equal(Some("device-1"))
  cfg.whatsapp.enabled |> should.equal(True)
}

pub fn false_turns_off_what_the_yaml_turned_on_test() {
  let base =
    yaml(
      "telegram:\n  enabled: true\n  token: t\nslack:\n  enabled: true\n  token: s\nmatrix:\n  enabled: true\n",
    )
  use <- with_env([
    #("SUPERNOVA_TELEGRAM_ENABLED", "false"),
    #("SUPERNOVA_SLACK_ENABLED", "false"),
    // Anything but true/false keeps what the YAML says.
    #("SUPERNOVA_MATRIX_ENABLED", "sim"),
  ])
  let cfg = config.apply_env_overrides(base)
  cfg.telegram.enabled |> should.equal(False)
  cfg.slack.enabled |> should.equal(False)
  cfg.matrix.enabled |> should.equal(True)
  // The token from the YAML stays when the environment has none.
  cfg.telegram.token |> should.equal(Some("t"))
}

pub fn a_blank_variable_does_not_override_test() {
  use <- with_env([
    #("SUPERNOVA_DATA_DIR", "   "),
    #("SUPERNOVA_SLACK_TOKEN", ""),
  ])
  let cfg =
    config.apply_env_overrides(yaml(
      "data_dir: meus-dados\nslack:\n  token: s\n",
    ))
  cfg.data_dir |> should.equal("meus-dados")
  cfg.slack.token |> should.equal(Some("s"))
}

pub fn access_lists_come_as_comma_separated_values_test() {
  use <- with_env([
    #("SUPERNOVA_ACCESS_MODE", "OPEN"),
    #("SUPERNOVA_ACCESS_ADMINS", " telegram:1 , discord:2,,"),
    #("SUPERNOVA_ACCESS_MEMBERS", "telegram:3"),
    #("SUPERNOVA_ACCESS_ALLOWED_CHATS", "telegram:-100, discord:guild:9"),
  ])
  let cfg = config.apply_env_overrides(yaml("data_dir: d\n"))
  cfg.access.mode |> should.equal(config.Open)
  cfg.access.admins |> should.equal(["telegram:1", "discord:2"])
  cfg.access.members |> should.equal(["telegram:3"])
  cfg.access.allowed_chats |> should.equal(["telegram:-100", "discord:guild:9"])
}

pub fn an_unknown_access_mode_keeps_the_yaml_test() {
  use <- with_env([#("SUPERNOVA_ACCESS_MODE", "everyone")])
  let cfg = config.apply_env_overrides(yaml("access:\n  mode: allowlist\n"))
  cfg.access.mode |> should.equal(config.Allowlist)
}

pub fn without_variables_the_yaml_stands_test() {
  let base = yaml("data_dir: d\ndiscord:\n  enabled: false\n")
  use <- with_env([#("SUPERNOVA_DISCORD_ENABLED", "")])
  let cfg = config.apply_env_overrides(base)
  cfg.discord.enabled |> should.equal(False)
  cfg.discord.token |> should.equal(None)
}

/// Model prices are what spending, and so the daily ceiling, is computed
/// from: a model listed with only one price takes the other from the
/// default.
pub fn model_prices_come_from_the_yaml_test() {
  let cfg =
    yaml(
      "pricing:\n  default:\n    input_per_mtok: 1.0\n    output_per_mtok: 4.0\n  models:\n    \"deepseek-v4-1-flash-1017\":\n      input_per_mtok: 0.3\n      output_per_mtok: 0.5\n    \"so-entrada\":\n      input_per_mtok: 2.0\n",
    )
  let assert Ok(flash) =
    dict.get(cfg.pricing.models, "deepseek-v4-1-flash-1017")
  flash
  |> should.equal(config.PricingEntry(input_per_mtok: 0.3, output_per_mtok: 0.5))
  let assert Ok(half) = dict.get(cfg.pricing.models, "so-entrada")
  half
  |> should.equal(config.PricingEntry(input_per_mtok: 2.0, output_per_mtok: 4.0))
  cfg.pricing.default
  |> should.equal(config.PricingEntry(input_per_mtok: 1.0, output_per_mtok: 4.0))
}

pub fn per_agent_budgets_override_the_default_test() {
  let cfg =
    yaml(
      "budgets:\n  inheritance_ratio: 30\n  agents:\n    pesquisadora:\n      tokens_per_hour: 5000\n      tool_calls_per_minute: 3\n      max_recursion_depth: 2\n      max_sub_agents: 1\n",
    )
  cfg.budgets.inheritance_ratio |> should.equal(30)
  // No `default` section: the built-in default stays.
  cfg.budgets.default.tokens_per_hour |> should.equal(100_000)
  let assert Ok(agent) = dict.get(cfg.budgets.agents, "pesquisadora")
  agent.tokens_per_hour |> should.equal(5000)
  agent.tool_calls_per_minute |> should.equal(3)
  agent.max_recursion_depth |> should.equal(2)
  agent.max_sub_agents |> should.equal(1)
}
