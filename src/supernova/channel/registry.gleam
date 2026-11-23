//// Channel Registry — manages all channel adapters and their send functions.
//// This module provides a centralized registry for all channel adapters,
//// allowing the core to send messages through any enabled channel without
//// knowing the implementation details.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import supernova/adapters/discord_channel
import supernova/adapters/google_chat_adapter
import supernova/adapters/lark_adapter
import supernova/adapters/matrix_channel
import supernova/adapters/mattermost_adapter
import supernova/adapters/sim_adapter
import supernova/adapters/slack_channel
import supernova/adapters/telegram_channel
import supernova/adapters/wechat_work_adapter
import supernova/adapters/whatsapp_adapter
import supernova/channel/channel_kit
import supernova/channel/chat_lanes
import supernova/channel/health as channel_health
import supernova/channel/port
import supernova/config
import supernova/core/closed_group/commands as closed_group_commands

/// A registry of all channel adapters, keyed by channel name.
pub type ChannelRegistry {
  ChannelRegistry(
    id: String,
    channels: Dict(String, port.ChannelAdapter),
    streams: Dict(String, channel_kit.StreamSendFn),
    health: channel_health.ChannelHealth,
  )
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn new_registry_id() -> String {
  "registry:"
  <> int.to_string(unique_integer())
  <> ":"
  <> int.to_string(channel_kit.current_timestamp())
}

/// Start all enabled channel adapters based on configuration.
///
/// Returns a ChannelRegistry containing send functions for each enabled channel.
pub fn start_channels(cfg: config.Config) -> Result(ChannelRegistry, String) {
  start_channels_with_handler(cfg, channel_kit.noop_handler())
}

/// Start all enabled channel adapters with an injected inbound handler.
pub fn start_channels_with_handler(
  cfg: config.Config,
  handler: port.ChannelHandler,
) -> Result(ChannelRegistry, String) {
  start_channels_with_handler_and_hooks(
    cfg,
    handler,
    channel_kit.no_start_hooks(),
  )
}

/// Start all enabled channel adapters with an injected inbound handler.
///
/// `hooks` exists to keep registry tests deterministic without live network
/// dependencies.
pub fn start_channels_with_handler_and_hooks(
  cfg: config.Config,
  handler: port.ChannelHandler,
  hooks: channel_kit.StartHooks,
) -> Result(ChannelRegistry, String) {
  let registry_id = new_registry_id()
  let hooks = channel_kit.StartHooks(..hooks, registry_id: registry_id)
  let channels = dict.new()
  let streams = dict.new()
  let health = channel_health.start()
  config.incomplete_channels(cfg)
  |> list.each(fn(pair) {
    io.println(pair.0 <> ": not started - " <> pair.1)
    channel_health.failed(health, pair.0, pair.1)
  })

  let #(channels, streams) =
    starters(cfg, handler, hooks, health)
    |> list.filter(fn(starter) { config.is_channel_enabled(cfg, starter.name) })
    |> list.fold(#(channels, streams), fn(acc, starter) {
      let #(channels, streams) = acc
      case starter.start() {
        Ok(#(adapter, stream_send_fn)) -> {
          io.println(starter.name <> ": started")
          insert_channel(channels, streams, adapter, stream_send_fn)
        }
        Error(reason) -> {
          io.println(starter.name <> ": failed to start - " <> reason)
          channel_health.failed(health, starter.name, reason)
          #(channels, streams)
        }
      }
    })

  let total = dict.size(channels)
  io.println("Started " <> int.to_string(total) <> " channel adapter(s)")

  // Channels that report their own health register before they start, so an
  // early failure is not overwritten here.
  let self_reporting =
    starters(cfg, handler, hooks, health)
    |> list.filter(fn(starter) { starter.reports_health })
    |> list.map(fn(starter) { starter.name })
  let now = channel_health.now_ms()
  channels
  |> dict.keys
  |> list.filter(fn(name) { !list.contains(self_reporting, name) })
  |> list.each(fn(name) { channel_health.started(health, name, None, now) })

  Ok(ChannelRegistry(
    id: registry_id,
    channels: channels,
    streams: streams,
    health: health,
  ))
}

/// How to start one channel adapter.
type Starter {
  Starter(
    name: String,
    /// The adapter reports its own health from the moment it starts.
    reports_health: Bool,
    start: fn() ->
      Result(#(port.ChannelAdapter, Option(channel_kit.StreamSendFn)), String),
  )
}

/// Every channel adapter, in start order. This is the one place that knows
/// which adapters exist.
fn starters(
  cfg: config.Config,
  handler: port.ChannelHandler,
  hooks: channel_kit.StartHooks,
  health: channel_health.ChannelHealth,
) -> List(Starter) {
  let streaming = fn(started) {
    result.map(
      started,
      fn(pair: #(port.ChannelAdapter, channel_kit.StreamSendFn)) {
        #(pair.0, Some(pair.1))
      },
    )
  }
  let plain = fn(started) {
    result.map(started, fn(adapter) { #(adapter, None) })
  }
  [
    Starter("discord", False, fn() {
      streaming(discord_channel.start_discord_channel(
        cfg.discord,
        handler,
        hooks,
      ))
    }),
    Starter("matrix", False, fn() {
      streaming(matrix_channel.start_matrix_channel(cfg.matrix, handler, hooks))
    }),
    Starter("mattermost", False, fn() {
      plain(start_mattermost_channel(cfg.mattermost, handler))
    }),
    Starter("whatsapp", False, fn() {
      plain(start_whatsapp_channel(cfg.whatsapp, handler))
    }),
    Starter("sim", False, fn() {
      sim_adapter.start(cfg.sim, handler)
      |> result.map(fn(pair) { #(pair.0, None) })
    }),
    Starter("telegram", True, fn() {
      let started =
        telegram_channel.start_telegram_channel(
          cfg.telegram,
          handler,
          hooks,
          health,
        )
      // Tests drive Telegram without polling; they do not publish a menu.
      case started, hooks.disable_telegram_polling {
        Ok(_), False -> publish_telegram_menu(cfg)
        _, _ -> Nil
      }
      streaming(started)
    }),
    Starter("slack", False, fn() {
      streaming(slack_channel.start_slack_channel(cfg.slack, handler, hooks))
    }),
    Starter("lark", False, fn() { plain(start_lark_channel(cfg.lark, handler)) }),
    Starter("google_chat", False, fn() {
      plain(start_google_chat_channel(cfg.google_chat, handler))
    }),
    Starter("wechat_work", False, fn() {
      plain(start_wechat_work_channel(cfg.wechat_work, handler))
    }),
  ]
}

/// Send a reply through a specific channel.
///
/// Returns Ok(Nil) on success, or the appropriate error.
pub fn send(
  registry: ChannelRegistry,
  channel: String,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case dict.get(registry.channels, channel) {
    Ok(adapter) -> adapter.send(reply)
    Error(_) -> Error(port.SendFailed("Channel not registered: " <> channel))
  }
}

pub fn send_stream(
  registry: ChannelRegistry,
  channel: String,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
) -> Result(Nil, port.ChannelError) {
  case dict.get(registry.streams, channel) {
    Ok(send_fn) -> send_fn(base_reply, events)
    Error(_) ->
      Error(port.SendFailed("Channel stream not registered: " <> channel))
  }
}

/// Get the adapter registered for a specific channel, if available.
pub fn get_channel_adapter(
  registry: ChannelRegistry,
  channel: String,
) -> Option(port.ChannelAdapter) {
  case dict.get(registry.channels, channel) {
    Ok(adapter) -> Some(adapter)
    Error(_) -> None
  }
}

/// Check if a channel is registered and available.
pub fn is_channel_available(
  registry: ChannelRegistry,
  channel: String,
) -> Bool {
  dict.has_key(registry.channels, channel)
}

/// List all registered channel names.
pub fn list_channels(registry: ChannelRegistry) -> List(String) {
  dict.keys(registry.channels)
}

/// Stop all channels in the registry.
pub fn stop_channels(registry: ChannelRegistry) -> Nil {
  stop_channels_with_timeout(registry, 25_000)
}

/// Stop adapters after draining this registry's lane prefix.
pub fn stop_channels_with_timeout(
  registry: ChannelRegistry,
  drain_timeout_ms: Int,
) -> Nil {
  registry.channels
  |> dict.values
  |> list.each(fn(adapter) { adapter.stop_ingress() })

  let remaining = chat_lanes.drain(registry.id, drain_timeout_ms)
  case remaining > 0 {
    True ->
      io.println(
        "warn: "
        <> int.to_string(remaining)
        <> " chat lane job(s) remained after drain",
      )
    False -> Nil
  }

  registry.channels
  |> dict.values
  |> list.each(fn(adapter) { adapter.stop() })

  io.println("Stopped all channel adapters")
  Nil
}

fn insert_channel(
  channels: Dict(String, port.ChannelAdapter),
  streams: Dict(String, channel_kit.StreamSendFn),
  adapter: port.ChannelAdapter,
  stream_send: Option(channel_kit.StreamSendFn),
) -> #(
  Dict(String, port.ChannelAdapter),
  Dict(String, channel_kit.StreamSendFn),
) {
  let channels = dict.insert(channels, adapter.name, adapter)

  let streams = case stream_send {
    Some(send_fn) -> dict.insert(streams, adapter.name, send_fn)
    None -> streams
  }

  #(channels, streams)
}

// ============================================================================
// Channel Bootstrap
// ============================================================================

fn start_whatsapp_channel(
  whatsapp_cfg: config.WhatsAppConfig,
  handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  case whatsapp_cfg.bridge_url {
    Some(bridge_url) ->
      whatsapp_adapter.start(bridge_url, whatsapp_cfg.device_id, handler)
    None -> Error("enabled but no bridge_url configured")
  }
}

fn start_lark_channel(
  lark_cfg: config.LarkConfig,
  handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  case lark_cfg.token {
    Some(token) -> lark_adapter.start(token, lark_cfg.base_url, handler)
    None -> Error("enabled but no token configured")
  }
}

fn start_google_chat_channel(
  google_chat_cfg: config.GoogleChatConfig,
  handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  case google_chat_cfg.webhook_url {
    Some(webhook_url) -> google_chat_adapter.start(webhook_url, handler)
    None -> Error("enabled but no webhook_url configured")
  }
}

fn start_mattermost_channel(
  mattermost_cfg: config.MattermostConfig,
  handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  case mattermost_cfg.token, mattermost_cfg.base_url {
    Some(token), Some(base_url) ->
      mattermost_adapter.start(token, base_url, handler)
    None, _ -> Error("enabled but no token configured")
    _, None -> Error("enabled but no base_url configured")
  }
}

fn start_wechat_work_channel(
  wechat_work_cfg: config.WechatWorkConfig,
  handler: port.ChannelHandler,
) -> Result(port.ChannelAdapter, String) {
  case wechat_work_cfg.webhook_url {
    Some(webhook_url) -> wechat_work_adapter.start(webhook_url, handler)
    None -> Error("enabled but no webhook_url configured")
  }
}

/// Run an inbound the core produced itself (an agenda entry coming due) as if
/// the channel had delivered it: same handler, same per-chat lane, so it never
/// overlaps a turn the person is having in that chat.
pub fn inject(
  registry: ChannelRegistry,
  handler: port.ChannelHandler,
  inbound: port.ChannelInbound,
) -> Result(Nil, port.ChannelError) {
  let channel = case inbound {
    port.InboundMessage(message) -> message.channel
    port.InboundInteraction(interaction) -> interaction.channel
  }
  case dict.has_key(registry.channels, channel) {
    False -> Error(port.SendFailed("Channel not registered: " <> channel))
    True -> {
      let stream_send_fn = case dict.get(registry.streams, channel) {
        Ok(send_fn) -> send_fn
        Error(_) -> fn(base_reply, _events) {
          send(registry, channel, base_reply)
        }
      }
      channel_kit.dispatch_inbound(
        handler,
        fn(reply) { send(registry, channel, reply) },
        stream_send_fn,
        inbound,
        registry.id,
        channel_kit.turn_hard_timeout_ms,
      )
      Ok(Nil)
    }
  }
}

/// The closed group's commands as the Telegram menu, in the background: the
/// boot does not wait on Telegram.
fn publish_telegram_menu(cfg: config.Config) -> Nil {
  let pairs = fn(is_admin) {
    closed_group_commands.for_role(is_admin)
    |> list.map(fn(command) { #(command.name, command.description) })
  }
  let admin_ids =
    list.filter_map(cfg.access.admins, fn(principal) {
      case principal {
        "telegram:" <> id -> Ok(id)
        _ -> Error(Nil)
      }
    })
  process.spawn_unlinked(fn() {
    telegram_channel.publish_menu(
      cfg.telegram,
      pairs(False),
      pairs(True),
      admin_ids,
    )
  })
  Nil
}
