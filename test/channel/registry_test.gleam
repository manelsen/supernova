import catalog_support
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import supernova/adapters/discord_gateway
import supernova/adapters/discord_router
import supernova/adapters/matrix_router
import supernova/adapters/slack_router
import supernova/adapters/telegram
import supernova/adapters/telegram_router
import supernova/channel/channel_kit
import supernova/channel/health as channel_health
import supernova/channel/port
import supernova/channel/registry
import supernova/config
import supernova/core/session/supervisor
import supernova/llm/provider
import test_workspace

fn enabled_discord_and_telegram_config() -> config.Config {
  let base = config.default_config()

  config.Config(
    ..base,
    discord: config.DiscordConfig(
      token: Some("discord-token"),
      app_id: None,
      guild_id: None,
      enabled: True,
    ),
    telegram: config.TelegramConfig(
      token: Some("telegram-token"),
      enabled: True,
      base_url: None,
    ),
  )
}

fn mock_provider_config() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

fn runtime_handler_with_supervisor() -> #(
  port.ChannelHandler,
  supervisor.SessionSupervisor,
) {
  let assert Ok(session_sup) = supervisor.start()
  let llm_config = mock_provider_config()
  let assert Ok(discord_channel_router) =
    discord_router.start_with_session_supervisor(session_sup, llm_config)
  let assert Ok(telegram_channel_router) =
    telegram_router.start_with_session_supervisor(session_sup, llm_config)
  let assert Ok(slack_channel_router) =
    slack_router.start_with_session_supervisor(session_sup, llm_config)
  let assert Ok(matrix_channel_router) =
    matrix_router.start_with_session_supervisor(session_sup, llm_config)

  #(
    fn(inbound, stream_events) {
      case inbound_channel_name(inbound) {
        "discord" ->
          discord_router.route_inbound_for_handler(
            discord_channel_router,
            inbound,
            stream_events,
          )
        "telegram" ->
          telegram_router.route_inbound_for_handler(
            telegram_channel_router,
            inbound,
            stream_events,
          )
        "slack" ->
          slack_router.route_inbound_for_handler(
            slack_channel_router,
            inbound,
            stream_events,
          )
        "matrix" ->
          matrix_router.route_inbound_for_handler(
            matrix_channel_router,
            inbound,
            stream_events,
          )
        channel -> Error(port.Ignored("channel not configured: " <> channel))
      }
    },
    session_sup,
  )
}

fn inbound_channel_name(inbound: port.ChannelInbound) -> String {
  case inbound {
    port.InboundMessage(message) -> message.channel
    port.InboundInteraction(interaction) -> interaction.channel
  }
}

fn start_runtime_registry_with_recorder(
  discord_events: List(discord_gateway.DiscordEvent),
  telegram_updates: List(telegram.Update),
  recorder: process.Subject(channel_kit.OutboundRecord),
) -> #(registry.ChannelRegistry, supervisor.SessionSupervisor) {
  start_runtime_registry_with_recorder_and_keepalive(
    discord_events,
    telegram_updates,
    recorder,
    4000,
  )
}

fn start_slack_runtime_registry_with_recorder(
  slack_events: List(port.ChannelInbound),
  recorder: process.Subject(channel_kit.OutboundRecord),
) -> #(registry.ChannelRegistry, supervisor.SessionSupervisor) {
  let #(handler, session_sup) = runtime_handler_with_supervisor()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_slack_and_matrix_config(),
      handler,
      test_hooks_with_slack_inbound(slack_events, recorder),
    )
  #(channel_registry, session_sup)
}

fn start_matrix_runtime_registry_with_recorder(
  matrix_events: List(port.ChannelInbound),
  recorder: process.Subject(channel_kit.OutboundRecord),
) -> #(registry.ChannelRegistry, supervisor.SessionSupervisor) {
  let #(handler, session_sup) = runtime_handler_with_supervisor()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_slack_and_matrix_config(),
      handler,
      test_hooks_with_matrix_inbound(matrix_events, recorder),
    )
  #(channel_registry, session_sup)
}

fn start_runtime_registry_with_recorder_and_keepalive(
  discord_events: List(discord_gateway.DiscordEvent),
  telegram_updates: List(telegram.Update),
  recorder: process.Subject(channel_kit.OutboundRecord),
  typing_keepalive_ms: Int,
) -> #(registry.ChannelRegistry, supervisor.SessionSupervisor) {
  let #(handler, session_sup) = runtime_handler_with_supervisor()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      handler,
      test_hooks_with_recorder_and_keepalive(
        discord_events,
        telegram_updates,
        recorder,
        typing_keepalive_ms,
      ),
    )

  #(channel_registry, session_sup)
}

fn enabled_whatsapp_config() -> config.Config {
  let base = config.default_config()

  config.Config(
    ..base,
    whatsapp: config.WhatsAppConfig(
      bridge_url: Some("http://localhost:3000"),
      device_id: Some("device-1"),
      enabled: True,
      basic_auth: Some("supernova:senha"),
      webhook_secret: Some("segredo"),
      allow_groups: False,
    ),
  )
}

fn enabled_slack_config() -> config.Config {
  let base = config.default_config()

  config.Config(
    ..base,
    slack: config.SlackConfig(token: Some("slack-token"), enabled: True),
  )
}

fn enabled_matrix_config() -> config.Config {
  let base = config.default_config()

  config.Config(
    ..base,
    matrix: config.MatrixConfig(
      homeserver_url: Some("https://matrix.example.org"),
      token: Some("matrix-token"),
      enabled: True,
    ),
  )
}

fn enabled_slack_and_matrix_config() -> config.Config {
  let base = config.default_config()

  config.Config(
    ..base,
    slack: config.SlackConfig(token: Some("slack-token"), enabled: True),
    matrix: config.MatrixConfig(
      homeserver_url: Some("https://matrix.example.org"),
      token: Some("matrix-token"),
      enabled: True,
    ),
  )
}

fn enabled_remaining_native_channels_config() -> config.Config {
  let base = config.default_config()

  config.Config(
    ..base,
    lark: config.LarkConfig(
      token: Some("lark-token"),
      base_url: Some("https://open.larksuite.com"),
      enabled: True,
    ),
    google_chat: config.GoogleChatConfig(
      webhook_url: Some(
        "https://chat.googleapis.com/v1/spaces/xyz789/messages?key=test&token=test",
      ),
      enabled: True,
    ),
    mattermost: config.MattermostConfig(
      token: Some("mattermost-token"),
      base_url: Some("https://mattermost.example.com"),
      enabled: True,
    ),
    wechat_work: config.WechatWorkConfig(
      webhook_url: Some(
        "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=wechat-key",
      ),
      enabled: True,
    ),
  )
}

fn ignoring_handler(
  received: process.Subject(port.ChannelInbound),
) -> port.ChannelHandler {
  fn(inbound, _) {
    process.send(received, inbound)
    Error(port.Ignored("test handled"))
  }
}

fn test_hooks(
  discord_events: List(discord_gateway.DiscordEvent),
  telegram_updates: List(telegram.Update),
) -> channel_kit.StartHooks {
  channel_kit.StartHooks(
    discord_events: discord_events,
    discord_gateway: channel_kit.DiscordGatewayOff,
    telegram_updates: telegram_updates,
    slack_inbound_events: [],
    matrix_inbound_events: [],
    disable_telegram_polling: True,
    typing_keepalive_ms: 4000,
    stream_timeout_ms: 60_000,
    turn_hard_timeout_ms: 300_000,
    registry_id: "",
    outbound_records: None,
    leave_group: None,
    leave_retry_ms: [5000, 30_000, 120_000],
    leave_recheck_ms: 30_000,
  )
}

fn test_hooks_with_slack_inbound(
  slack_events: List(port.ChannelInbound),
  recorder: process.Subject(channel_kit.OutboundRecord),
) -> channel_kit.StartHooks {
  channel_kit.StartHooks(
    discord_events: [],
    discord_gateway: channel_kit.DiscordGatewayOff,
    telegram_updates: [],
    slack_inbound_events: slack_events,
    matrix_inbound_events: [],
    disable_telegram_polling: True,
    typing_keepalive_ms: 4000,
    stream_timeout_ms: 60_000,
    turn_hard_timeout_ms: 300_000,
    registry_id: "",
    outbound_records: Some(recorder),
    leave_group: None,
    leave_retry_ms: [5000, 30_000, 120_000],
    leave_recheck_ms: 30_000,
  )
}

fn test_hooks_with_matrix_inbound(
  matrix_events: List(port.ChannelInbound),
  recorder: process.Subject(channel_kit.OutboundRecord),
) -> channel_kit.StartHooks {
  channel_kit.StartHooks(
    discord_events: [],
    discord_gateway: channel_kit.DiscordGatewayOff,
    telegram_updates: [],
    slack_inbound_events: [],
    matrix_inbound_events: matrix_events,
    disable_telegram_polling: True,
    typing_keepalive_ms: 4000,
    stream_timeout_ms: 60_000,
    turn_hard_timeout_ms: 300_000,
    registry_id: "",
    outbound_records: Some(recorder),
    leave_group: None,
    leave_retry_ms: [5000, 30_000, 120_000],
    leave_recheck_ms: 30_000,
  )
}

fn test_hooks_with_recorder(
  discord_events: List(discord_gateway.DiscordEvent),
  telegram_updates: List(telegram.Update),
  recorder: process.Subject(channel_kit.OutboundRecord),
) -> channel_kit.StartHooks {
  test_hooks_with_recorder_and_keepalive(
    discord_events,
    telegram_updates,
    recorder,
    4000,
  )
}

fn test_hooks_with_recorder_and_keepalive(
  discord_events: List(discord_gateway.DiscordEvent),
  telegram_updates: List(telegram.Update),
  recorder: process.Subject(channel_kit.OutboundRecord),
  typing_keepalive_ms: Int,
) -> channel_kit.StartHooks {
  channel_kit.StartHooks(
    discord_events: discord_events,
    discord_gateway: channel_kit.DiscordGatewayOff,
    telegram_updates: telegram_updates,
    slack_inbound_events: [],
    matrix_inbound_events: [],
    disable_telegram_polling: True,
    typing_keepalive_ms: typing_keepalive_ms,
    stream_timeout_ms: 60_000,
    turn_hard_timeout_ms: 300_000,
    registry_id: "",
    outbound_records: Some(recorder),
    leave_group: None,
    leave_retry_ms: [5000, 30_000, 120_000],
    leave_recheck_ms: 30_000,
  )
}

fn streaming_handler() -> port.ChannelHandler {
  fn(inbound, events) {
    case inbound {
      port.InboundMessage(msg) -> {
        let base_reply =
          port.reply(to: msg, content: "") |> port.with_typing(True)

        process.send(
          events,
          port.StreamUpdate(port.reply(to: msg, content: "Mock ")),
        )
        process.send(
          events,
          port.StreamUpdate(port.reply(
            to: msg,
            content: "Mock streaming response",
          )),
        )
        process.send(
          events,
          port.StreamComplete(port.reply(
            to: msg,
            content: "Mock streaming response",
          )),
        )

        Ok(port.StreamReply(base_reply: base_reply))
      }
      port.InboundInteraction(_) -> Error(port.Ignored("interactions not used"))
    }
  }
}

fn delayed_streaming_handler(
  first_update_delay_ms: Int,
  completion_delay_ms: Int,
) -> port.ChannelHandler {
  fn(inbound, events) {
    case inbound {
      port.InboundMessage(msg) -> {
        let base_reply =
          port.reply(to: msg, content: "") |> port.with_typing(True)

        let _ =
          process.spawn_unlinked(fn() {
            process.sleep(first_update_delay_ms)
            process.send(
              events,
              port.StreamUpdate(port.reply(to: msg, content: "Mock ")),
            )
            process.sleep(completion_delay_ms)
            process.send(
              events,
              port.StreamComplete(port.reply(
                to: msg,
                content: "Mock streaming response",
              )),
            )
          })

        Ok(port.StreamReply(base_reply: base_reply))
      }
      port.InboundInteraction(_) -> Error(port.Ignored("interactions not used"))
    }
  }
}

fn discord_reply(content: String) -> port.ChannelReply {
  port.ChannelReply(
    channel_id: "900000000000000009",
    content: content,
    reply_to_id: Some("900000000000000087"),
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: None,
    media: [],
  )
}

fn telegram_reply(content: String) -> port.ChannelReply {
  port.ChannelReply(
    channel_id: "12345678",
    content: content,
    reply_to_id: Some("171"),
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: None,
    media: [],
  )
}

pub fn start_channels_registers_discord_and_telegram_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], []),
    )

  registry.is_channel_available(channel_registry, "discord")
  |> should.equal(True)

  registry.is_channel_available(channel_registry, "telegram")
  |> should.equal(True)

  let channels = registry.list_channels(channel_registry)
  list.length(channels) |> should.equal(2)

  registry.stop_channels(channel_registry)
}

pub fn start_channels_exposes_port_adapters_for_enabled_channels_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], []),
    )

  let assert Some(discord_adapter) =
    registry.get_channel_adapter(channel_registry, "discord")
  discord_adapter.name |> should.equal("discord")

  let assert Some(telegram_adapter) =
    registry.get_channel_adapter(channel_registry, "telegram")
  telegram_adapter.name |> should.equal("telegram")

  registry.get_channel_adapter(channel_registry, "matrix")
  |> should.equal(None)

  registry.stop_channels(channel_registry)
}

pub fn start_channels_registers_whatsapp_bridge_adapter_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_whatsapp_config(),
      ignoring_handler(received),
      test_hooks([], []),
    )

  registry.is_channel_available(channel_registry, "whatsapp")
  |> should.equal(True)

  let assert Some(whatsapp_adapter) =
    registry.get_channel_adapter(channel_registry, "whatsapp")
  whatsapp_adapter.name |> should.equal("whatsapp")

  registry.stop_channels(channel_registry)
}

pub fn start_channels_registers_slack_adapter_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_slack_config(),
      ignoring_handler(received),
      test_hooks([], []),
    )

  registry.is_channel_available(channel_registry, "slack")
  |> should.equal(True)

  let assert Some(slack_adapter) =
    registry.get_channel_adapter(channel_registry, "slack")
  slack_adapter.name |> should.equal("slack")

  registry.stop_channels(channel_registry)
}

pub fn start_channels_registers_remaining_native_adapters_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_remaining_native_channels_config(),
      ignoring_handler(received),
      test_hooks([], []),
    )

  registry.is_channel_available(channel_registry, "lark")
  |> should.equal(True)
  registry.is_channel_available(channel_registry, "google_chat")
  |> should.equal(True)
  registry.is_channel_available(channel_registry, "mattermost")
  |> should.equal(True)
  registry.is_channel_available(channel_registry, "wechat_work")
  |> should.equal(True)

  let channels = registry.list_channels(channel_registry)
  list.length(channels) |> should.equal(4)

  registry.stop_channels(channel_registry)
}

pub fn start_channels_skips_enabled_channels_with_missing_credentials_test() {
  let base = config.default_config()
  let cfg =
    config.Config(
      ..base,
      discord: config.DiscordConfig(
        token: None,
        app_id: None,
        guild_id: None,
        enabled: True,
      ),
      telegram: config.TelegramConfig(
        token: None,
        enabled: True,
        base_url: None,
      ),
      matrix: config.MatrixConfig(
        homeserver_url: None,
        token: None,
        enabled: True,
      ),
      lark: config.LarkConfig(token: None, base_url: None, enabled: True),
      google_chat: config.GoogleChatConfig(webhook_url: None, enabled: True),
      slack: config.SlackConfig(token: None, enabled: True),
      mattermost: config.MattermostConfig(
        token: None,
        base_url: Some("https://mattermost.example.com"),
        enabled: True,
      ),
      wechat_work: config.WechatWorkConfig(webhook_url: None, enabled: True),
      whatsapp: config.WhatsAppConfig(
        ..config.default_whatsapp_config(),
        enabled: True,
      ),
    )
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler(cfg, ignoring_handler(received))

  registry.list_channels(channel_registry)
  |> should.equal([])

  registry.stop_channels(channel_registry)
}

pub fn start_channels_skips_matrix_when_token_missing_test() {
  let base = config.default_config()
  let cfg =
    config.Config(
      ..base,
      matrix: config.MatrixConfig(
        homeserver_url: Some("https://matrix.example.org"),
        token: None,
        enabled: True,
      ),
    )
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler(cfg, ignoring_handler(received))

  registry.is_channel_available(channel_registry, "matrix")
  |> should.equal(False)

  registry.stop_channels(channel_registry)
}

pub fn start_channels_skips_mattermost_when_base_url_missing_test() {
  let base = config.default_config()
  let cfg =
    config.Config(
      ..base,
      mattermost: config.MattermostConfig(
        token: Some("mattermost-token"),
        base_url: None,
        enabled: True,
      ),
    )
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler(cfg, ignoring_handler(received))

  registry.is_channel_available(channel_registry, "mattermost")
  |> should.equal(False)

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_discord_gateway_message_to_handler_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([discord_fixture_message_create_event()], []),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)

  case inbound {
    port.InboundMessage(msg) -> {
      msg.channel |> should.equal("discord")
      msg.id |> should.equal("900000000000000087")
      msg.channel_id
      |> should.equal("900000000000000009@guild:900000000000000008")
      msg.user_id |> should.equal("900000000000000002")
      msg.username |> should.equal("username_1")
      msg.content |> should.equal("content_2")
      msg.is_bot |> should.equal(False)
      msg.reply_to_id |> should.equal(None)
    }
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_discord_slash_command_to_handler_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([discord_fixture_interaction_command_event()], []),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)

  case inbound {
    port.InboundMessage(msg) -> {
      msg.channel |> should.equal("discord")
      msg.id |> should.equal("interaction-help-1")
      msg.channel_id
      |> should.equal("900000000000000004@guild:900000000000000009")
      msg.user_id |> should.equal("900000000000000026")
      msg.username |> should.equal("username_5")
      msg.content |> should.equal("/help")
      msg.is_bot |> should.equal(False)
      msg.reply_to_id |> should.equal(None)
    }
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_discord_component_interaction_to_handler_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([discord_fixture_interaction_component_event()], []),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)

  case inbound {
    port.InboundInteraction(interaction) -> {
      interaction.channel |> should.equal("discord")
      interaction.channel_id
      |> should.equal("900000000000000004@guild:900000000000000009")
      interaction.user_id |> should.equal("900000000000000026")
      interaction.username |> should.equal("username_5")
      interaction.is_bot |> should.equal(False)
      interaction.event.id |> should.equal("interaction-component-1")
      interaction.event.action_id |> should.equal("picker_model_select")
      interaction.event.values |> should.equal(["openai|gpt-4o"])
      interaction.event.source_message_id |> should.equal(None)
    }
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_telegram_update_to_handler_test() {
  let received = process.new_subject()
  let assert Ok(update) = telegram.parse_update(telegram_fixture_update())
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], [update]),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)

  case inbound {
    port.InboundMessage(msg) -> {
      msg.channel |> should.equal("telegram")
      msg.id |> should.equal("171")
      msg.channel_id |> should.equal("12345678")
      msg.user_id |> should.equal("12345678")
      msg.username |> should.equal("anonymized_bot")
      msg.content |> should.equal("Anonymized message content")
      msg.is_bot |> should.equal(False)
      msg.reply_to_id |> should.equal(None)
    }
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

/// Model buttons carry `m:<provider|model>`; buttons sent before that
/// carry the long prefix. Both reach the router as the model list's action.
pub fn start_channels_routes_telegram_callback_query_to_handler_test() {
  routes_model_callback(telegram_fixture_callback_query_update())
  routes_model_callback(string.replace(
    telegram_fixture_callback_query_update(),
    "picker_model_select:mock|mock-alt-model",
    "m:mock|mock-alt-model",
  ))
}

fn routes_model_callback(fixture: String) -> Nil {
  let received = process.new_subject()
  let assert Ok(update) = telegram.parse_update(fixture)
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], [update]),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)

  case inbound {
    port.InboundInteraction(interaction) -> {
      interaction.channel |> should.equal("telegram")
      interaction.channel_id |> should.equal("12345678")
      interaction.user_id |> should.equal("12345678")
      interaction.username |> should.equal("anonymized_bot")
      interaction.is_bot |> should.equal(False)
      interaction.event.id |> should.equal("cb-telegram-1")
      interaction.event.action_id |> should.equal("picker_model_select")
      interaction.event.values |> should.equal(["mock|mock-alt-model"])
      interaction.event.source_message_id |> should.equal(Some("171"))
    }
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_streams_discord_reply_with_placeholder_and_edits_test() {
  let recorder = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      streaming_handler(),
      test_hooks_with_recorder(
        [discord_fixture_message_create_event()],
        [],
        recorder,
      ),
    )

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)
  let assert Ok(third) = process.receive(recorder, within: 1000)
  let assert Ok(fourth) = process.receive(recorder, within: 1000)

  first
  |> should.equal(channel_kit.OutboundRecord(
    channel: "discord",
    action: "typing",
    content: "",
    message_id: None,
  ))
  second
  |> should.equal(channel_kit.OutboundRecord(
    channel: "discord",
    action: "send",
    content: "Thinking...",
    message_id: Some("discord-stream-1"),
  ))
  third
  |> should.equal(channel_kit.OutboundRecord(
    channel: "discord",
    action: "edit",
    content: "Mock ",
    message_id: Some("discord-stream-1"),
  ))
  fourth
  |> should.equal(channel_kit.OutboundRecord(
    channel: "discord",
    action: "edit",
    content: "Mock streaming response",
    message_id: Some("discord-stream-1"),
  ))

  registry.stop_channels(channel_registry)
}

pub fn start_channels_refreshes_discord_typing_while_stream_waits_test() {
  let recorder = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      delayed_streaming_handler(90, 1),
      test_hooks_with_recorder_and_keepalive(
        [discord_fixture_message_create_event()],
        [],
        recorder,
        60,
      ),
    )

  let records = collect_registry_records(recorder, [])
  let assert Ok(first) = list.first(records)
  first
  |> should.equal(channel_kit.OutboundRecord(
    channel: "discord",
    action: "typing",
    content: "",
    message_id: None,
  ))
  records
  |> list.filter(fn(record) { record.action != "typing" })
  |> should.equal([
    channel_kit.OutboundRecord(
      channel: "discord",
      action: "send",
      content: "Thinking...",
      message_id: Some("discord-stream-1"),
    ),
    channel_kit.OutboundRecord(
      channel: "discord",
      action: "edit",
      content: "Mock ",
      message_id: Some("discord-stream-1"),
    ),
    channel_kit.OutboundRecord(
      channel: "discord",
      action: "edit",
      content: "Mock streaming response",
      message_id: Some("discord-stream-1"),
    ),
  ])

  registry.stop_channels(channel_registry)
}

pub fn start_channels_streams_telegram_reply_with_send_and_edits_test() {
  let recorder = process.new_subject()
  let assert Ok(update) = telegram.parse_update(telegram_fixture_update())
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      streaming_handler(),
      test_hooks_with_recorder([], [update], recorder),
    )

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)
  let assert Ok(third) = process.receive(recorder, within: 1000)
  let assert Ok(fourth) = process.receive(recorder, within: 1000)

  first
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "typing",
    content: "",
    message_id: None,
  ))
  second
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "send",
    content: "Thinking...",
    message_id: Some("telegram-stream-1"),
  ))
  third
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "edit",
    content: "Mock ",
    message_id: Some("telegram-stream-1"),
  ))
  fourth
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "edit",
    content: "Mock streaming response",
    message_id: Some("telegram-stream-1"),
  ))

  registry.stop_channels(channel_registry)
}

pub fn start_channels_refreshes_telegram_typing_while_stream_waits_test() {
  let recorder = process.new_subject()
  let assert Ok(update) = telegram.parse_update(telegram_fixture_update())
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      delayed_streaming_handler(90, 1),
      test_hooks_with_recorder_and_keepalive([], [update], recorder, 60),
    )

  let records = collect_registry_records(recorder, [])
  let assert Ok(first) = list.first(records)
  first
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "typing",
    content: "",
    message_id: None,
  ))
  records
  |> list.filter(fn(record) { record.action != "typing" })
  |> should.equal([
    channel_kit.OutboundRecord(
      channel: "telegram",
      action: "send",
      content: "Thinking...",
      message_id: Some("telegram-stream-1"),
    ),
    channel_kit.OutboundRecord(
      channel: "telegram",
      action: "edit",
      content: "Mock ",
      message_id: Some("telegram-stream-1"),
    ),
    channel_kit.OutboundRecord(
      channel: "telegram",
      action: "edit",
      content: "Mock streaming response",
      message_id: Some("telegram-stream-1"),
    ),
  ])

  registry.stop_channels(channel_registry)
}

pub fn start_channels_streams_slack_dm_reply_with_native_progress_test() {
  let recorder = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_slack_config(),
      ignoring_handler(process.new_subject()),
      test_hooks_with_recorder([], [], recorder),
    )

  let events = process.new_subject()
  let base_reply =
    port.ChannelReply(
      channel_id: "D012345678",
      content: "",
      reply_to_id: Some("1721609600.123456"),
      thread_id: None,
      typing: False,
      edit_message_id: None,
      interactive: None,
      media: [],
    )

  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        events,
        port.StreamUpdate(port.ChannelReply(..base_reply, content: "Mock ")),
      )
      process.send(
        events,
        port.StreamComplete(
          port.ChannelReply(..base_reply, content: "Mock streaming response"),
        ),
      )
    })

  let assert Ok(_) =
    registry.send_stream(channel_registry, "slack", base_reply, events)

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)
  let assert Ok(third) = process.receive(recorder, within: 1000)

  first
  |> should.equal(channel_kit.OutboundRecord(
    channel: "slack",
    action: "progress_start",
    content: "Thinking...",
    message_id: Some("slack-stream-1"),
  ))
  second
  |> should.equal(channel_kit.OutboundRecord(
    channel: "slack",
    action: "progress_append",
    content: "Mock ",
    message_id: Some("slack-stream-1"),
  ))
  third
  |> should.equal(channel_kit.OutboundRecord(
    channel: "slack",
    action: "progress_stop",
    content: "Mock streaming response",
    message_id: Some("slack-stream-1"),
  ))

  registry.stop_channels(channel_registry)
}

/// A model that falls back to a reply without streaming, after some text
/// already went out, ends with a text that does not continue it. The
/// message is reopened and holds only the final reply, never both.
pub fn slack_native_stream_reopens_when_the_reply_changes_test() {
  let recorder = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_slack_config(),
      ignoring_handler(process.new_subject()),
      test_hooks_with_recorder([], [], recorder),
    )
  let events = process.new_subject()
  let base_reply =
    port.ChannelReply(
      channel_id: "D012345678",
      content: "",
      reply_to_id: Some("1721609600.123456"),
      thread_id: None,
      typing: False,
      edit_message_id: None,
      interactive: None,
      media: [],
    )
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        events,
        port.StreamUpdate(port.ChannelReply(..base_reply, content: "Começo ")),
      )
      // Not a continuation: it is not appended.
      process.send(
        events,
        port.StreamUpdate(port.ChannelReply(..base_reply, content: "Outra")),
      )
      process.send(
        events,
        port.StreamComplete(
          port.ChannelReply(..base_reply, content: "Outra resposta inteira"),
        ),
      )
    })
  let assert Ok(_) =
    registry.send_stream(channel_registry, "slack", base_reply, events)
  let assert Ok(_start) = process.receive(recorder, within: 1000)
  let assert Ok(append) = process.receive(recorder, within: 1000)
  let assert Ok(last) = process.receive(recorder, within: 1000)
  append.action |> should.equal("progress_append")
  append.content |> should.equal("Começo ")
  last
  |> should.equal(channel_kit.OutboundRecord(
    channel: "slack",
    action: "progress_reopen",
    content: "Outra resposta inteira",
    message_id: Some("slack-stream-1"),
  ))
  process.receive(recorder, within: 100) |> should.be_error()
  registry.stop_channels(channel_registry)
}

pub fn start_channels_streams_slack_channel_reply_with_fallback_updates_test() {
  let recorder = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_slack_config(),
      ignoring_handler(process.new_subject()),
      test_hooks_with_recorder([], [], recorder),
    )

  let events = process.new_subject()
  let base_reply =
    port.ChannelReply(
      channel_id: "C0123456789",
      content: "",
      reply_to_id: Some("1721609600.123456"),
      thread_id: None,
      typing: False,
      edit_message_id: None,
      interactive: None,
      media: [],
    )

  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        events,
        port.StreamUpdate(port.ChannelReply(..base_reply, content: "Mock ")),
      )
      process.send(
        events,
        port.StreamComplete(
          port.ChannelReply(..base_reply, content: "Mock streaming response"),
        ),
      )
    })

  let assert Ok(_) =
    registry.send_stream(channel_registry, "slack", base_reply, events)

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)
  let assert Ok(third) = process.receive(recorder, within: 1000)

  first
  |> should.equal(channel_kit.OutboundRecord(
    channel: "slack",
    action: "send",
    content: "Thinking...",
    message_id: Some("slack-stream-1"),
  ))
  second
  |> should.equal(channel_kit.OutboundRecord(
    channel: "slack",
    action: "edit",
    content: "Mock ",
    message_id: Some("slack-stream-1"),
  ))
  third
  |> should.equal(channel_kit.OutboundRecord(
    channel: "slack",
    action: "edit",
    content: "Mock streaming response",
    message_id: Some("slack-stream-1"),
  ))

  registry.stop_channels(channel_registry)
}

pub fn adapter_send_chunks_discord_long_reply_test() {
  let recorder = process.new_subject()
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks_with_recorder([], [], recorder),
    )

  let assert Some(adapter) =
    registry.get_channel_adapter(channel_registry, "discord")
  let long_content = string.repeat("discord word ", 220)

  let assert Ok(_) = adapter.send(discord_reply(long_content))
  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)

  first.action |> should.equal("send")
  should.equal(string.length(first.content) <= 2000, True)
  second.action |> should.equal("send")
  should.equal(string.length(second.content) <= 2000, True)
  string.starts_with(second.content, "(continued)\n") |> should.equal(True)

  process.receive(recorder, within: 100)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
}

pub fn adapter_send_chunks_telegram_long_reply_test() {
  let recorder = process.new_subject()
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks_with_recorder([], [], recorder),
    )

  let assert Some(adapter) =
    registry.get_channel_adapter(channel_registry, "telegram")
  let long_content = string.repeat("telegram word ", 350)

  let assert Ok(_) = adapter.send(telegram_reply(long_content))
  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)

  first.action |> should.equal("send")
  should.equal(string.length(first.content) <= 4096, True)
  second.action |> should.equal("send")
  should.equal(string.length(second.content) <= 4096, True)
  string.starts_with(second.content, "(continued)\n") |> should.equal(True)

  process.receive(recorder, within: 100)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
}

pub fn e2e_discord_help_command_routes_from_adapter_to_reply_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  let recorder = process.new_subject()
  let #(channel_registry, session_sup) =
    start_runtime_registry_with_recorder(
      [discord_fixture_interaction_command_event()],
      [],
      recorder,
    )

  let assert Ok(record) = process.receive(recorder, within: 1000)

  record
  |> should.equal(channel_kit.OutboundRecord(
    channel: "discord",
    action: "send",
    content: "Supernova AI Agent Framework\n\n"
      <> "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/vincular - Bring another app to the same agent\n"
      <> "/model - Change LLM model\n"
      <> "/project - Start project wizard\n",
    message_id: Some("discord-send-1"),
  ))

  process.receive(recorder, within: 100)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

pub fn e2e_telegram_model_selection_updates_ui_and_next_reply_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  use <- catalog_support.with_alt_model(
    mock_provider_config(),
    "mock-alt-model",
  )
  let recorder = process.new_subject()
  let assert Ok(callback_update) =
    telegram.parse_update(telegram_fixture_callback_query_update())
  let assert Ok(follow_up_update) =
    telegram.parse_update(telegram_fixture_update_with_text(
      "[echo-model] use selected model",
    ))
  let #(channel_registry, session_sup) =
    start_runtime_registry_with_recorder(
      [],
      [callback_update, follow_up_update],
      recorder,
    )

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)
  let assert Ok(third) = process.receive(recorder, within: 1000)
  let assert Ok(fourth) = process.receive(recorder, within: 1000)

  first
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "edit",
    content: "Modelo trocado para Mock / mock-alt-model. Vale para as próximas mensagens, também depois de reiniciar.",
    message_id: Some("171"),
  ))
  second
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "typing",
    content: "",
    message_id: None,
  ))
  third
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "send",
    content: "Thinking...",
    message_id: Some("telegram-stream-1"),
  ))
  fourth
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "edit",
    content: "Mock response via mock-alt-model",
    message_id: Some("telegram-stream-1"),
  ))

  process.receive(recorder, within: 100)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

pub fn e2e_discord_stream_error_falls_back_to_non_streaming_reply_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  let recorder = process.new_subject()
  let #(channel_registry, session_sup) =
    start_runtime_registry_with_recorder(
      [
        discord_fixture_message_create_event_with_content(
          "[stream-error] please recover",
        ),
      ],
      [],
      recorder,
    )

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)
  let assert Ok(third) = process.receive(recorder, within: 1000)

  first
  |> should.equal(channel_kit.OutboundRecord(
    channel: "discord",
    action: "typing",
    content: "",
    message_id: None,
  ))
  second
  |> should.equal(channel_kit.OutboundRecord(
    channel: "discord",
    action: "send",
    content: "Thinking...",
    message_id: Some("discord-stream-1"),
  ))
  third
  |> should.equal(channel_kit.OutboundRecord(
    channel: "discord",
    action: "edit",
    content: "Mock fallback after stream error",
    message_id: Some("discord-stream-1"),
  ))

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

pub fn e2e_telegram_stream_timeout_falls_back_to_non_streaming_reply_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  let recorder = process.new_subject()
  let assert Ok(update) =
    telegram.parse_update(telegram_fixture_update_with_text(
      "[stream-timeout] please recover",
    ))
  let #(channel_registry, session_sup) =
    start_runtime_registry_with_recorder([], [update], recorder)

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)
  let assert Ok(third) = process.receive(recorder, within: 3000)

  first
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "typing",
    content: "",
    message_id: None,
  ))
  second
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "send",
    content: "Thinking...",
    message_id: Some("telegram-stream-1"),
  ))
  third
  |> should.equal(channel_kit.OutboundRecord(
    channel: "telegram",
    action: "edit",
    content: "Mock fallback after stream timeout",
    message_id: Some("telegram-stream-1"),
  ))

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

pub fn e2e_discord_invalid_callback_produces_no_outbound_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  let recorder = process.new_subject()
  let #(channel_registry, session_sup) =
    start_runtime_registry_with_recorder(
      [
        discord_fixture_interaction_component_event_with_action(
          "picker_unknown_action",
          [],
        ),
      ],
      [],
      recorder,
    )

  process.receive(recorder, within: 200)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

pub fn start_channels_routes_discord_command_with_typed_options_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([discord_fixture_interaction_command_with_options_event()], []),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)

  case inbound {
    port.InboundMessage(msg) -> {
      msg.channel |> should.equal("discord")
      msg.content
      |> should.equal(
        "/deploy env:prod retries:3 dry:true user:900000000000000111",
      )
    }
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_discord_interaction_with_root_user_fallback_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks(
        [discord_fixture_interaction_command_with_user_fallback_event()],
        [],
      ),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)
  case inbound {
    port.InboundMessage(msg) -> {
      msg.user_id |> should.equal("900000000000000333")
      msg.username |> should.equal("fallback_user")
      msg.is_bot |> should.equal(False)
    }
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_ignores_discord_interaction_missing_channel_id_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([discord_fixture_interaction_missing_channel_event()], []),
    )

  process.receive(received, within: 200)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
}

pub fn start_channels_ignores_discord_interaction_missing_data_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([discord_fixture_interaction_missing_data_event()], []),
    )

  process.receive(received, within: 200)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
}

pub fn start_channels_ignores_telegram_message_without_sender_test() {
  let received = process.new_subject()
  let assert Ok(update) =
    telegram.parse_update(telegram_fixture_update_without_sender())
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], [update]),
    )

  process.receive(received, within: 200)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_telegram_caption_when_text_missing_test() {
  let received = process.new_subject()
  let assert Ok(update) =
    telegram.parse_update(telegram_fixture_update_with_caption_only())
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], [update]),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)
  case inbound {
    port.InboundMessage(msg) -> msg.content |> should.equal("caption only")
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_ignores_telegram_callback_missing_message_test() {
  let received = process.new_subject()
  let assert Ok(update) =
    telegram.parse_update(
      telegram_fixture_callback_query_without_message_update(),
    )
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], [update]),
    )

  process.receive(received, within: 200)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_telegram_callback_non_model_action_test() {
  let received = process.new_subject()
  let assert Ok(update) =
    telegram.parse_update(telegram_fixture_callback_query_non_model_update())
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], [update]),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)
  case inbound {
    port.InboundInteraction(interaction) -> {
      interaction.event.action_id |> should.equal("custom_action")
      interaction.event.values |> should.equal([])
    }
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

fn discord_fixture_message_create_event() -> discord_gateway.DiscordEvent {
  discord_fixture_message_create_event_with_content("content_2")
}

fn discord_fixture_message_create_event_with_content(
  content: String,
) -> discord_gateway.DiscordEvent {
  discord_gateway.MessageCreate(
    "{\"id\":\"900000000000000087\",\"channel_id\":\"900000000000000009\",\"guild_id\":\"900000000000000008\",\"content\":\""
    <> content
    <> "\",\"timestamp\":\"2026-03-30T00:00:00.000000+00:00\",\"author\":{\"id\":\"900000000000000002\",\"username\":\"username_1\",\"discriminator\":\"0\",\"bot\":false}}",
  )
}

fn discord_fixture_interaction_command_event() -> discord_gateway.DiscordEvent {
  discord_gateway.RawEvent(
    "INTERACTION_CREATE",
    "{\"id\":\"interaction-help-1\",\"application_id\":\"app-1\",\"type\":2,\"token\":\"token-help\",\"version\":1,\"guild_id\":\"900000000000000009\",\"channel_id\":\"900000000000000004\",\"member\":{\"user\":{\"id\":\"900000000000000026\",\"username\":\"username_5\",\"discriminator\":\"0\",\"bot\":false}} ,\"data\":{\"id\":\"cmd-help-1\",\"name\":\"help\",\"type\":1}}",
  )
}

fn discord_fixture_interaction_command_with_options_event() -> discord_gateway.DiscordEvent {
  discord_gateway.RawEvent(
    "INTERACTION_CREATE",
    "{\"id\":\"interaction-deploy-1\",\"application_id\":\"app-1\",\"type\":2,\"token\":\"token-deploy\",\"version\":1,\"guild_id\":\"900000000000000009\",\"channel_id\":\"900000000000000004\",\"member\":{\"user\":{\"id\":\"900000000000000026\",\"username\":\"username_5\",\"discriminator\":\"0\",\"bot\":false}},\"data\":{\"id\":\"cmd-deploy-1\",\"name\":\"deploy\",\"type\":1,\"options\":[{\"name\":\"env\",\"type\":3,\"value\":\"prod\"},{\"name\":\"retries\",\"type\":4,\"value\":3},{\"name\":\"dry\",\"type\":5,\"value\":true},{\"name\":\"user\",\"type\":6,\"value\":\"900000000000000111\"}]}}",
  )
}

fn discord_fixture_interaction_command_with_user_fallback_event() -> discord_gateway.DiscordEvent {
  discord_gateway.RawEvent(
    "INTERACTION_CREATE",
    "{\"id\":\"interaction-fallback-1\",\"application_id\":\"app-1\",\"type\":2,\"token\":\"token-fallback\",\"version\":1,\"guild_id\":\"900000000000000009\",\"channel_id\":\"900000000000000004\",\"user\":{\"id\":\"900000000000000333\",\"username\":\"fallback_user\",\"discriminator\":\"0\",\"bot\":false},\"data\":{\"id\":\"cmd-fallback-1\",\"name\":\"help\",\"type\":1}}",
  )
}

fn discord_fixture_interaction_missing_channel_event() -> discord_gateway.DiscordEvent {
  discord_gateway.RawEvent(
    "INTERACTION_CREATE",
    "{\"id\":\"interaction-missing-channel\",\"application_id\":\"app-1\",\"type\":2,\"token\":\"token\",\"version\":1,\"guild_id\":\"900000000000000009\",\"member\":{\"user\":{\"id\":\"900000000000000026\",\"username\":\"username_5\",\"discriminator\":\"0\",\"bot\":false}},\"data\":{\"id\":\"cmd-help-1\",\"name\":\"help\",\"type\":1}}",
  )
}

fn discord_fixture_interaction_missing_data_event() -> discord_gateway.DiscordEvent {
  discord_gateway.RawEvent(
    "INTERACTION_CREATE",
    "{\"id\":\"interaction-missing-data\",\"application_id\":\"app-1\",\"type\":3,\"token\":\"token\",\"version\":1,\"guild_id\":\"900000000000000009\",\"channel_id\":\"900000000000000004\",\"member\":{\"user\":{\"id\":\"900000000000000026\",\"username\":\"username_5\",\"discriminator\":\"0\",\"bot\":false}}}",
  )
}

fn discord_fixture_interaction_component_event() -> discord_gateway.DiscordEvent {
  discord_fixture_interaction_component_event_with_action(
    "picker_model_select",
    ["openai|gpt-4o"],
  )
}

fn discord_fixture_interaction_component_event_with_action(
  action_id: String,
  values: List(String),
) -> discord_gateway.DiscordEvent {
  let values_json = case values {
    [] -> "[]"
    _ -> "[\"" <> string.join(values, "\",\"") <> "\"]"
  }

  discord_gateway.RawEvent(
    "INTERACTION_CREATE",
    "{\"id\":\"interaction-component-1\",\"application_id\":\"app-1\",\"type\":3,\"token\":\"token-component\",\"version\":1,\"guild_id\":\"900000000000000009\",\"channel_id\":\"900000000000000004\",\"member\":{\"user\":{\"id\":\"900000000000000026\",\"username\":\"username_5\",\"discriminator\":\"0\",\"bot\":false}},\"data\":{\"custom_id\":\""
      <> action_id
      <> "\",\"component_type\":3,\"values\":"
      <> values_json
      <> "}}",
  )
}

fn telegram_fixture_update() -> String {
  telegram_fixture_update_with_text("Anonymized message content")
}

fn telegram_fixture_update_with_text(text: String) -> String {
  "{\"update_id\":737343144,\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":171,\"from\":{\"is_bot\":false,\"id\":12345678,\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"text\":\""
  <> text
  <> "\",\"date\":1774569232}}"
}

fn telegram_fixture_callback_query_update() -> String {
  "{\"update_id\":737343145,\"message\":null,\"edited_message\":null,\"channel_post\":null,\"edited_channel_post\":null,\"inline_query\":null,\"chosen_inline_result\":null,\"callback_query\":{\"id\":\"cb-telegram-1\",\"from\":{\"is_bot\":false,\"id\":12345678,\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":171,\"from\":{\"is_bot\":true,\"id\":999999,\"first_name\":\"SupernovaBot\",\"username\":\"supernova_bot\"},\"text\":\"Current selection: Mock / mock-model\",\"date\":1774569232},\"inline_message_id\":null,\"chat_instance\":\"instance-1\",\"data\":\"picker_model_select:mock|mock-alt-model\",\"game_short_name\":null}}"
}

fn telegram_fixture_update_without_sender() -> String {
  "{\"update_id\":737343146,\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":172,\"from\":null,\"text\":\"Hello\",\"date\":1774569232}}"
}

fn telegram_fixture_update_with_caption_only() -> String {
  "{\"update_id\":737343147,\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":173,\"from\":{\"is_bot\":false,\"id\":12345678,\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"text\":null,\"caption\":\"caption only\",\"date\":1774569232}}"
}

fn telegram_fixture_callback_query_without_message_update() -> String {
  "{\"update_id\":737343148,\"callback_query\":{\"id\":\"cb-telegram-2\",\"from\":{\"is_bot\":false,\"id\":12345678,\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message\":null,\"inline_message_id\":null,\"chat_instance\":\"instance-2\",\"data\":\"picker_model_select:mock|mock-alt-model\",\"game_short_name\":null}}"
}

fn telegram_fixture_callback_query_non_model_update() -> String {
  "{\"update_id\":737343149,\"callback_query\":{\"id\":\"cb-telegram-3\",\"from\":{\"is_bot\":false,\"id\":12345678,\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":174,\"from\":{\"is_bot\":true,\"id\":999999,\"first_name\":\"SupernovaBot\",\"username\":\"supernova_bot\"},\"text\":\"Current selection\",\"date\":1774569232},\"inline_message_id\":null,\"chat_instance\":\"instance-3\",\"data\":\"custom_action\",\"game_short_name\":null}}"
}

// ============================================================================
// Slack fixtures
// ============================================================================

fn slack_fixture_message(content: String) -> port.ChannelInbound {
  port.inbound_message(port.ChannelMessage(
    id: "msg-slack-1",
    channel: "slack",
    channel_id: "D012345678",
    user_id: "U012345678",
    username: "slack_user",
    content: content,
    is_bot: False,
    reply_to_id: None,
  ))
}

fn slack_fixture_interaction(
  action_id: String,
  values: List(String),
) -> port.ChannelInbound {
  port.inbound_interaction(port.ChannelInteractionMessage(
    channel: "slack",
    channel_id: "D012345678",
    user_id: "U012345678",
    username: "slack_user",
    is_bot: False,
    event: port.ChannelInteractionEvent(
      id: "slack-interaction-1",
      action_id: action_id,
      values: values,
      source_message_id: Some("msg-slack-1"),
    ),
  ))
}

// ============================================================================
// Matrix fixtures
// ============================================================================

fn matrix_fixture_message(content: String) -> port.ChannelInbound {
  port.inbound_message(port.ChannelMessage(
    id: "$matrix-event-1:matrix.example.org",
    channel: "matrix",
    channel_id: "!room1:matrix.example.org",
    user_id: "@user:matrix.example.org",
    username: "matrix_user",
    content: content,
    is_bot: False,
    reply_to_id: None,
  ))
}

// ============================================================================
// US-028: Slack E2E tests
// ============================================================================

pub fn start_channels_registers_matrix_adapter_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_matrix_config(),
      ignoring_handler(received),
      test_hooks([], []),
    )

  registry.is_channel_available(channel_registry, "matrix")
  |> should.equal(True)

  let assert Some(matrix_adapter) =
    registry.get_channel_adapter(channel_registry, "matrix")
  matrix_adapter.name |> should.equal("matrix")

  registry.stop_channels(channel_registry)
}

pub fn slack_inbound_event_dispatched_to_handler_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_slack_config(),
      ignoring_handler(received),
      channel_kit.StartHooks(
        discord_events: [],
        discord_gateway: channel_kit.DiscordGatewayOff,
        telegram_updates: [],
        slack_inbound_events: [slack_fixture_message("hello slack")],
        matrix_inbound_events: [],
        disable_telegram_polling: True,
        typing_keepalive_ms: 4000,
        stream_timeout_ms: 60_000,
        turn_hard_timeout_ms: 300_000,
        registry_id: "",
        outbound_records: None,
        leave_group: None,
        leave_retry_ms: [5000, 30_000, 120_000],
        leave_recheck_ms: 30_000,
      ),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)

  case inbound {
    port.InboundMessage(msg) -> {
      msg.channel |> should.equal("slack")
      msg.channel_id |> should.equal("D012345678")
      msg.user_id |> should.equal("U012345678")
      msg.content |> should.equal("hello slack")
      msg.is_bot |> should.equal(False)
    }
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn e2e_slack_help_command_routes_from_inbound_to_reply_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  let recorder = process.new_subject()
  let #(channel_registry, session_sup) =
    start_slack_runtime_registry_with_recorder(
      [slack_fixture_message("/help")],
      recorder,
    )

  let assert Ok(record) = process.receive(recorder, within: 1000)

  record
  |> should.equal(channel_kit.OutboundRecord(
    channel: "slack",
    action: "send",
    content: "Supernova AI Agent Framework\n\n"
      <> "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/vincular - Bring another app to the same agent\n"
      <> "/model - Change LLM model\n",
    message_id: Some("slack-send-1"),
  ))

  process.receive(recorder, within: 100)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

pub fn e2e_slack_start_command_returns_session_bootstrapped_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  let recorder = process.new_subject()
  let #(channel_registry, session_sup) =
    start_slack_runtime_registry_with_recorder(
      [slack_fixture_message("/start")],
      recorder,
    )

  let assert Ok(record) = process.receive(recorder, within: 1000)

  record.channel |> should.equal("slack")
  record.action |> should.equal("send")
  string.contains(record.content, "Session bootstrapped") |> should.equal(True)

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

pub fn e2e_slack_model_command_returns_interactive_picker_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  let recorder = process.new_subject()
  let #(channel_registry, session_sup) =
    start_slack_runtime_registry_with_recorder(
      [slack_fixture_message("/model")],
      recorder,
    )

  let assert Ok(record) = process.receive(recorder, within: 1000)

  record.channel |> should.equal("slack")
  record.action |> should.equal("send")
  string.contains(record.content, "mock") |> should.equal(True)

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

pub fn e2e_slack_model_selection_persists_for_session_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  use <- catalog_support.with_alt_model(
    mock_provider_config(),
    "mock-alt-model",
  )
  let recorder = process.new_subject()
  let #(channel_registry, session_sup) =
    start_slack_runtime_registry_with_recorder(
      [
        slack_fixture_interaction("picker_model_select", ["mock|mock-alt-model"]),
        slack_fixture_message("[echo-model] use selected model"),
      ],
      recorder,
    )

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)
  let assert Ok(third) = process.receive(recorder, within: 1000)

  first.channel |> should.equal("slack")
  first.action |> should.equal("send")
  string.contains(first.content, "mock-alt-model") |> should.equal(True)

  second
  |> should.equal(channel_kit.OutboundRecord(
    channel: "slack",
    action: "send",
    content: "Thinking...",
    message_id: Some("slack-stream-1"),
  ))
  third
  |> should.equal(channel_kit.OutboundRecord(
    channel: "slack",
    action: "edit",
    content: "Mock response via mock-alt-model",
    message_id: Some("slack-stream-1"),
  ))

  process.receive(recorder, within: 100)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

// ============================================================================
// US-029: Matrix E2E tests
// ============================================================================

pub fn matrix_inbound_event_dispatched_to_handler_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_matrix_config(),
      ignoring_handler(received),
      channel_kit.StartHooks(
        discord_events: [],
        discord_gateway: channel_kit.DiscordGatewayOff,
        telegram_updates: [],
        slack_inbound_events: [],
        matrix_inbound_events: [matrix_fixture_message("hello matrix")],
        disable_telegram_polling: True,
        typing_keepalive_ms: 4000,
        stream_timeout_ms: 60_000,
        turn_hard_timeout_ms: 300_000,
        registry_id: "",
        outbound_records: None,
        leave_group: None,
        leave_retry_ms: [5000, 30_000, 120_000],
        leave_recheck_ms: 30_000,
      ),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)

  case inbound {
    port.InboundMessage(msg) -> {
      msg.channel |> should.equal("matrix")
      msg.channel_id |> should.equal("!room1:matrix.example.org")
      msg.user_id |> should.equal("@user:matrix.example.org")
      msg.content |> should.equal("hello matrix")
      msg.is_bot |> should.equal(False)
    }
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn e2e_matrix_help_command_routes_from_inbound_to_reply_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  let recorder = process.new_subject()
  let #(channel_registry, session_sup) =
    start_matrix_runtime_registry_with_recorder(
      [matrix_fixture_message("/help")],
      recorder,
    )

  let assert Ok(record) = process.receive(recorder, within: 1000)

  record
  |> should.equal(channel_kit.OutboundRecord(
    channel: "matrix",
    action: "send",
    content: "Supernova AI Agent Framework\n\n"
      <> "Commands:\n"
      <> "/help - Show this help\n"
      <> "/start - Start a new session\n"
      <> "/status - Show session status\n"
      <> "/vincular - Bring another app to the same agent\n"
      <> "/model - Change LLM model\n",
    message_id: Some("matrix-send-1"),
  ))

  process.receive(recorder, within: 100)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

pub fn e2e_matrix_start_command_returns_session_bootstrapped_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  let recorder = process.new_subject()
  let #(channel_registry, session_sup) =
    start_matrix_runtime_registry_with_recorder(
      [matrix_fixture_message("/start")],
      recorder,
    )

  let assert Ok(record) = process.receive(recorder, within: 1000)

  record.channel |> should.equal("matrix")
  record.action |> should.equal("send")
  string.contains(record.content, "Session bootstrapped") |> should.equal(True)

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

pub fn e2e_matrix_follow_up_uses_session_history_test() {
  use _ <- test_workspace.with_isolated_workspace("registry-e2e")
  let recorder = process.new_subject()
  let #(channel_registry, session_sup) =
    start_matrix_runtime_registry_with_recorder(
      [matrix_fixture_message("[echo-model] use model info")],
      recorder,
    )

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)

  first
  |> should.equal(channel_kit.OutboundRecord(
    channel: "matrix",
    action: "send",
    content: "Thinking...",
    message_id: Some("matrix-stream-1"),
  ))
  second
  |> should.equal(channel_kit.OutboundRecord(
    channel: "matrix",
    action: "edit",
    content: "Mock response via mock-model",
    message_id: Some("matrix-stream-1"),
  ))

  process.receive(recorder, within: 100)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
  supervisor.stop(session_sup)
}

pub fn send_returns_error_for_unregistered_channel_test() {
  let assert Ok(channel_registry) =
    registry.start_channels(config.default_config())

  case registry.send(channel_registry, "discord", discord_reply("hello")) {
    Error(port.SendFailed(reason)) ->
      reason |> should.equal("Channel not registered: discord")
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn send_stream_returns_error_for_unregistered_channel_test() {
  let assert Ok(channel_registry) =
    registry.start_channels(config.default_config())
  let events = process.new_subject()

  case
    registry.send_stream(
      channel_registry,
      "discord",
      discord_reply("base"),
      events,
    )
  {
    Error(port.SendFailed(reason)) ->
      reason |> should.equal("Channel stream not registered: discord")
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_ignores_discord_autocomplete_interaction_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks(
        [discord_fixture_interaction_autocomplete_with_channel_role_event()],
        [],
      ),
    )

  process.receive(received, within: 150) |> should.be_error

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_discord_command_with_channel_and_role_options_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks(
        [discord_fixture_interaction_command_with_channel_role_event()],
        [],
      ),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)
  case inbound {
    port.InboundMessage(msg) ->
      msg.content |> should.equal("/configure channel:123 role:456")
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_discord_nested_command_options_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks(
        [discord_fixture_interaction_command_with_nested_options_event()],
        [],
      ),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)
  case inbound {
    port.InboundMessage(msg) ->
      msg.content |> should.equal("/ops deploy dry:false")
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_discord_component_without_values_as_empty_list_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks(
        [discord_fixture_interaction_component_without_values_event()],
        [],
      ),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)
  case inbound {
    port.InboundInteraction(interaction) ->
      interaction.event.values |> should.equal([])
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_discord_interaction_without_user_defaults_sender_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks(
        [discord_fixture_interaction_without_user_or_member_event()],
        [],
      ),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)
  case inbound {
    port.InboundMessage(msg) -> {
      msg.user_id |> should.equal("unknown")
      msg.username |> should.equal("unknown")
      msg.is_bot |> should.equal(False)
    }
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_ignores_telegram_callback_missing_data_test() {
  let received = process.new_subject()
  let assert Ok(update) =
    telegram.parse_update(telegram_fixture_callback_query_without_data_update())
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], [update]),
    )

  process.receive(received, within: 200)
  |> should.equal(Error(Nil))

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_telegram_message_without_username_falls_back_to_first_name_test() {
  let received = process.new_subject()
  let assert Ok(update) =
    telegram.parse_update(telegram_fixture_update_without_username())
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], [update]),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)
  case inbound {
    port.InboundMessage(msg) -> msg.username |> should.equal("NoUser")
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn start_channels_routes_telegram_message_without_text_or_caption_test() {
  let received = process.new_subject()
  let assert Ok(update) =
    telegram.parse_update(telegram_fixture_update_without_text_and_caption())
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], [update]),
    )

  let assert Ok(inbound) = process.receive(received, within: 1000)
  case inbound {
    port.InboundMessage(msg) -> msg.content |> should.equal("")
    _ -> should.fail()
  }

  registry.stop_channels(channel_registry)
}

pub fn adapter_send_telegram_rejects_invalid_reply_to_id_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], []),
    )

  let assert Some(adapter) =
    registry.get_channel_adapter(channel_registry, "telegram")
  let bad_reply =
    port.ChannelReply(..telegram_reply("hello"), reply_to_id: Some("oops"))

  adapter.send(bad_reply)
  |> should.equal(Error(port.SendFailed("invalid telegram reply_to_id: oops")))

  registry.stop_channels(channel_registry)
}

pub fn adapter_send_telegram_rejects_invalid_thread_id_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], []),
    )

  let assert Some(adapter) =
    registry.get_channel_adapter(channel_registry, "telegram")
  let bad_reply =
    port.ChannelReply(
      ..telegram_reply("hello"),
      reply_to_id: Some("171"),
      thread_id: Some("thread-x"),
    )

  adapter.send(bad_reply)
  |> should.equal(
    Error(port.SendFailed("invalid telegram thread_id: thread-x")),
  )

  registry.stop_channels(channel_registry)
}

pub fn adapter_send_telegram_rejects_invalid_edit_message_id_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], []),
    )

  let assert Some(adapter) =
    registry.get_channel_adapter(channel_registry, "telegram")
  let bad_reply =
    port.ChannelReply(
      ..telegram_reply("hello"),
      reply_to_id: None,
      edit_message_id: Some("bad"),
    )

  adapter.send(bad_reply)
  |> should.equal(
    Error(port.SendFailed("invalid telegram edit_message_id: bad")),
  )

  registry.stop_channels(channel_registry)
}

pub fn send_stream_telegram_rejects_invalid_reply_to_id_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], []),
    )

  let events = process.new_subject()
  let bad_base_reply =
    port.ChannelReply(..telegram_reply(""), reply_to_id: Some("oops"))

  registry.send_stream(channel_registry, "telegram", bad_base_reply, events)
  |> should.equal(Error(port.SendFailed("invalid telegram reply_to_id: oops")))

  registry.stop_channels(channel_registry)
}

pub fn send_stream_telegram_rejects_invalid_thread_id_test() {
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks([], []),
    )

  let events = process.new_subject()
  let bad_base_reply =
    port.ChannelReply(
      ..telegram_reply(""),
      reply_to_id: Some("171"),
      thread_id: Some("thread-x"),
    )

  registry.send_stream(channel_registry, "telegram", bad_base_reply, events)
  |> should.equal(
    Error(port.SendFailed("invalid telegram thread_id: thread-x")),
  )

  registry.stop_channels(channel_registry)
}

pub fn send_stream_discord_propagates_stream_failure_test() {
  let recorder = process.new_subject()
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks_with_recorder([], [], recorder),
    )

  let events = process.new_subject()
  let base_reply = discord_reply("") |> port.with_typing(True)
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        events,
        port.StreamFailure(port.SendFailed("discord-failure")),
      )
    })

  registry.send_stream(channel_registry, "discord", base_reply, events)
  |> should.equal(Error(port.SendFailed("discord-failure")))

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)
  first.action |> should.equal("typing")
  second.action |> should.equal("send")

  registry.stop_channels(channel_registry)
}

pub fn send_stream_telegram_propagates_stream_failure_test() {
  let recorder = process.new_subject()
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      ignoring_handler(received),
      test_hooks_with_recorder([], [], recorder),
    )

  let events = process.new_subject()
  let base_reply = telegram_reply("") |> port.with_typing(True)
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        events,
        port.StreamFailure(port.SendFailed("telegram-failure")),
      )
    })

  registry.send_stream(channel_registry, "telegram", base_reply, events)
  |> should.equal(Error(port.SendFailed("telegram-failure")))

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)
  first.action |> should.equal("typing")
  second.action |> should.equal("send")

  registry.stop_channels(channel_registry)
}

pub fn send_stream_matrix_complete_without_updates_records_final_edit_test() {
  let recorder = process.new_subject()
  let received = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_matrix_config(),
      ignoring_handler(received),
      test_hooks_with_matrix_inbound([], recorder),
    )

  let base_reply =
    port.ChannelReply(
      channel_id: "!room:example.org",
      content: "",
      reply_to_id: None,
      thread_id: None,
      typing: False,
      edit_message_id: None,
      interactive: None,
      media: [],
    )
  let events = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        events,
        port.StreamComplete(port.ChannelReply(..base_reply, content: "final")),
      )
    })

  registry.send_stream(channel_registry, "matrix", base_reply, events)
  |> should.equal(Ok(Nil))

  let assert Ok(first) = process.receive(recorder, within: 1000)
  let assert Ok(second) = process.receive(recorder, within: 1000)
  first.action |> should.equal("send")
  second
  |> should.equal(channel_kit.OutboundRecord(
    channel: "matrix",
    action: "edit",
    content: "final",
    message_id: Some("matrix-stream-1"),
  ))

  registry.stop_channels(channel_registry)
}

pub fn send_stream_slack_native_propagates_stream_failure_test() {
  let recorder = process.new_subject()
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_slack_config(),
      ignoring_handler(process.new_subject()),
      test_hooks_with_recorder([], [], recorder),
    )

  let base_reply =
    port.ChannelReply(
      channel_id: "D012345678",
      content: "",
      reply_to_id: Some("1721609600.123456"),
      thread_id: None,
      typing: False,
      edit_message_id: None,
      interactive: None,
      media: [],
    )
  let events = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(events, port.StreamFailure(port.SendFailed("slack-failure")))
    })

  registry.send_stream(channel_registry, "slack", base_reply, events)
  |> should.equal(Error(port.SendFailed("slack-failure")))

  let assert Ok(first) = process.receive(recorder, within: 1000)
  first.action |> should.equal("progress_start")

  registry.stop_channels(channel_registry)
}

fn discord_fixture_interaction_autocomplete_with_channel_role_event() -> discord_gateway.DiscordEvent {
  discord_gateway.RawEvent(
    "INTERACTION_CREATE",
    "{\"id\":\"interaction-auto-1\",\"application_id\":\"app-1\",\"type\":4,\"token\":\"token-auto\",\"version\":1,\"guild_id\":\"900000000000000009\",\"channel_id\":\"900000000000000004\",\"member\":{\"user\":{\"id\":\"900000000000000026\",\"username\":\"username_5\",\"discriminator\":\"0\",\"bot\":false}},\"data\":{\"id\":\"cmd-config-1\",\"name\":\"configure\",\"type\":1,\"options\":[{\"name\":\"channel\",\"type\":7,\"value\":\"123\"},{\"name\":\"role\",\"type\":8,\"value\":\"456\"}]}}",
  )
}

fn discord_fixture_interaction_command_with_channel_role_event() -> discord_gateway.DiscordEvent {
  discord_gateway.RawEvent(
    "INTERACTION_CREATE",
    "{\"id\":\"interaction-cmd-1\",\"application_id\":\"app-1\",\"type\":2,\"token\":\"token-cmd\",\"version\":1,\"guild_id\":\"900000000000000009\",\"channel_id\":\"900000000000000004\",\"member\":{\"user\":{\"id\":\"900000000000000026\",\"username\":\"username_5\",\"discriminator\":\"0\",\"bot\":false}},\"data\":{\"id\":\"cmd-config-1\",\"name\":\"configure\",\"type\":1,\"options\":[{\"name\":\"channel\",\"type\":7,\"value\":\"123\"},{\"name\":\"role\",\"type\":8,\"value\":\"456\"}]}}",
  )
}

fn discord_fixture_interaction_command_with_nested_options_event() -> discord_gateway.DiscordEvent {
  discord_gateway.RawEvent(
    "INTERACTION_CREATE",
    "{\"id\":\"interaction-nested-1\",\"application_id\":\"app-1\",\"type\":2,\"token\":\"token-nested\",\"version\":1,\"guild_id\":\"900000000000000009\",\"channel_id\":\"900000000000000004\",\"member\":{\"user\":{\"id\":\"900000000000000026\",\"username\":\"username_5\",\"discriminator\":\"0\",\"bot\":false}},\"data\":{\"id\":\"cmd-ops-1\",\"name\":\"ops\",\"type\":1,\"options\":[{\"name\":\"deploy\",\"type\":1,\"options\":[{\"name\":\"dry\",\"type\":5,\"value\":false}]}]}}",
  )
}

fn discord_fixture_interaction_component_without_values_event() -> discord_gateway.DiscordEvent {
  discord_gateway.RawEvent(
    "INTERACTION_CREATE",
    "{\"id\":\"interaction-component-empty\",\"application_id\":\"app-1\",\"type\":3,\"token\":\"token-component\",\"version\":1,\"guild_id\":\"900000000000000009\",\"channel_id\":\"900000000000000004\",\"member\":{\"user\":{\"id\":\"900000000000000026\",\"username\":\"username_5\",\"discriminator\":\"0\",\"bot\":false}},\"data\":{\"custom_id\":\"picker_model_select\",\"component_type\":3}}",
  )
}

fn discord_fixture_interaction_without_user_or_member_event() -> discord_gateway.DiscordEvent {
  discord_gateway.RawEvent(
    "INTERACTION_CREATE",
    "{\"id\":\"interaction-anon-1\",\"application_id\":\"app-1\",\"type\":2,\"token\":\"token-anon\",\"version\":1,\"guild_id\":\"900000000000000009\",\"channel_id\":\"900000000000000004\",\"data\":{\"id\":\"cmd-help-1\",\"name\":\"help\",\"type\":1}}",
  )
}

fn telegram_fixture_callback_query_without_data_update() -> String {
  "{\"update_id\":737343150,\"callback_query\":{\"id\":\"cb-telegram-4\",\"from\":{\"is_bot\":false,\"id\":12345678,\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":175,\"from\":{\"is_bot\":true,\"id\":999999,\"first_name\":\"SupernovaBot\",\"username\":\"supernova_bot\"},\"text\":\"Current selection\",\"date\":1774569232},\"inline_message_id\":null,\"chat_instance\":\"instance-4\",\"data\":null,\"game_short_name\":null}}"
}

fn telegram_fixture_update_without_username() -> String {
  "{\"update_id\":737343151,\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"first_name\":\"NoUser\",\"username\":null},\"message_id\":176,\"from\":{\"is_bot\":false,\"id\":12345678,\"first_name\":\"NoUser\",\"username\":null},\"text\":\"hello\",\"date\":1774569232}}"
}

fn telegram_fixture_update_without_text_and_caption() -> String {
  "{\"update_id\":737343152,\"message\":{\"chat\":{\"id\":12345678,\"type\":\"private\",\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"message_id\":177,\"from\":{\"is_bot\":false,\"id\":12345678,\"first_name\":\"AnonymizedUser\",\"username\":\"anonymized_bot\"},\"text\":null,\"caption\":null,\"date\":1774569232}}"
}

fn collect_registry_records(
  recorder: process.Subject(channel_kit.OutboundRecord),
  acc: List(channel_kit.OutboundRecord),
) -> List(channel_kit.OutboundRecord) {
  case process.receive(recorder, within: 2000) {
    Ok(record) -> collect_registry_records(recorder, [record, ..acc])
    Error(_) -> list.reverse(acc)
  }
}

fn stream_test_reply(content: String) -> port.ChannelReply {
  port.ChannelReply(
    channel_id: "999",
    content: content,
    reply_to_id: None,
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: None,
    media: [],
  )
}

pub fn split_delivery_treats_not_modified_as_success_test() {
  let delivered = process.new_subject()
  let result =
    channel_kit.finish_stream_in_parts_for_test(
      stream_test_reply(string.repeat("a", 500)),
      "placeholder",
      200,
      fn(part) {
        process.send(delivered, part.content)
        case part.edit_message_id {
          Some(_) ->
            Error(port.SendFailed("Bad Request: message is not modified"))
          None -> Ok(Nil)
        }
      },
    )

  result |> should.be_ok()
  process.receive(delivered, within: 100) |> should.be_ok()
  process.receive(delivered, within: 100) |> should.be_ok()
  process.receive(delivered, within: 100) |> should.be_ok()
}

pub fn split_delivery_retries_rate_limited_parts_test() {
  let decisions = process.new_subject()
  let delivered = process.new_subject()
  process.send(decisions, Ok(Nil))
  process.send(decisions, Error(port.RateLimited(retry_after_seconds: 0)))
  process.send(decisions, Ok(Nil))
  process.send(decisions, Ok(Nil))

  let result =
    channel_kit.finish_stream_in_parts_for_test(
      stream_test_reply(string.repeat("a", 500)),
      "placeholder",
      200,
      fn(part) {
        process.send(delivered, part.content)
        process.receive(decisions, within: 100)
        |> result.unwrap(Error(port.SendFailed("missing decision")))
      },
    )

  result |> should.be_ok()
}

pub fn split_delivery_sends_fallback_after_rate_limit_exhaustion_test() {
  let decisions = process.new_subject()
  let delivered = process.new_subject()
  let fallback_seen = process.new_subject()
  process.send(decisions, Ok(Nil))
  list.repeat(Nil, 10)
  |> list.each(fn(_) {
    process.send(decisions, Error(port.RateLimited(retry_after_seconds: 0)))
  })

  let result =
    channel_kit.finish_stream_in_parts_for_test(
      stream_test_reply(string.repeat("a", 500)),
      "placeholder",
      200,
      fn(part) {
        process.send(delivered, part.content)
        case part.content == "(Não consegui enviar o restante da resposta.)" {
          True -> {
            process.send(fallback_seen, part.content)
            Ok(Nil)
          }
          False ->
            process.receive(decisions, within: 100)
            |> result.unwrap(Error(port.SendFailed("missing decision")))
        }
      },
    )

  result |> should.be_ok()
  process.receive(fallback_seen, within: 1000)
  |> should.equal(Ok("(Não consegui enviar o restante da resposta.)"))
}

pub fn oversized_stream_update_is_ignored_test() {
  let recorder = process.new_subject()
  let handler = fn(inbound, events) {
    case inbound {
      port.InboundMessage(msg) -> {
        let base_reply =
          port.reply(to: msg, content: "") |> port.with_typing(True)
        process.send(
          events,
          port.StreamUpdate(port.reply(
            to: msg,
            content: string.repeat("X", 5000),
          )),
        )
        process.send(
          events,
          port.StreamComplete(port.reply(to: msg, content: "ok")),
        )
        Ok(port.StreamReply(base_reply: base_reply))
      }
      port.InboundInteraction(_) -> Error(port.Ignored("no interactions"))
    }
  }
  let assert Ok(update) = telegram.parse_update(telegram_fixture_update())
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      handler,
      test_hooks_with_recorder([], [update], recorder),
    )

  let records = collect_registry_records(recorder, [])
  list.any(records, fn(entry: channel_kit.OutboundRecord) {
    entry.content == string.repeat("X", 5000)
  })
  |> should.equal(False)
  list.any(records, fn(entry) { entry.content == "ok" })
  |> should.equal(True)

  registry.stop_channels(channel_registry)
}

fn test_hooks_with_timeouts(
  telegram_updates: List(telegram.Update),
  recorder: process.Subject(channel_kit.OutboundRecord),
  stream_timeout_ms: Int,
  turn_hard_timeout_ms: Int,
) -> channel_kit.StartHooks {
  channel_kit.StartHooks(
    discord_events: [],
    discord_gateway: channel_kit.DiscordGatewayOff,
    telegram_updates: telegram_updates,
    slack_inbound_events: [],
    matrix_inbound_events: [],
    disable_telegram_polling: True,
    typing_keepalive_ms: 4000,
    stream_timeout_ms: stream_timeout_ms,
    turn_hard_timeout_ms: turn_hard_timeout_ms,
    registry_id: "",
    outbound_records: Some(recorder),
    leave_group: None,
    leave_retry_ms: [5000, 30_000, 120_000],
    leave_recheck_ms: 30_000,
  )
}

pub fn hard_turn_timeout_releases_the_next_turn_test() {
  let recorder = process.new_subject()
  let started = process.new_subject()
  let handler = fn(inbound, _events) {
    case inbound {
      port.InboundMessage(msg) -> {
        process.send(started, msg.channel_id)
        Ok(port.StreamReply(base_reply: port.reply(to: msg, content: "")))
      }
      port.InboundInteraction(_) -> Error(port.Ignored("no interactions"))
    }
  }
  let assert Ok(update) = telegram.parse_update(telegram_fixture_update())
  let assert Ok(channel_registry) =
    registry.start_channels_with_handler_and_hooks(
      enabled_discord_and_telegram_config(),
      handler,
      test_hooks_with_timeouts([update, update], recorder, 20, 200),
    )
  let assert Ok(_) = process.receive(started, within: 1000)
  // The first lane is stuck without a terminal event until the hard timeout.
  // A second inbound update must not start before it.
  process.receive(started, within: 50) |> should.equal(Error(Nil))
  let assert Ok(_) = process.receive(started, within: 1000)
  registry.stop_channels_with_timeout(channel_registry, 1000)
}

pub fn stop_channels_stops_ingress_before_adapters_test() {
  let order = process.new_subject()
  let adapter =
    port.ChannelAdapter(
      name: "test",
      send: fn(_) { Ok(Nil) },
      stop_ingress: fn() { process.send(order, "ingress") },
      stop: fn() { process.send(order, "stop") },
    )
  let registry =
    registry.ChannelRegistry(
      id: "stop-order-test",
      channels: dict.from_list([#("test", adapter)]),
      streams: dict.new(),
      injectors: dict.new(),
      health: channel_health.start(),
    )

  registry.stop_channels_with_timeout(registry, 10)

  let assert Ok(first) = process.receive(order, within: 1000)
  let assert Ok(second) = process.receive(order, within: 1000)
  first |> should.equal("ingress")
  second |> should.equal("stop")
}
