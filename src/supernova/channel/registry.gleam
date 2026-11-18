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
import gleam/string
import supernova/adapters/discord_events
import supernova/adapters/discord_gateway
import supernova/adapters/discord_rest
import supernova/adapters/google_chat_adapter
import supernova/adapters/lark_adapter
import supernova/adapters/matrix_adapter
import supernova/adapters/mattermost_adapter
import supernova/adapters/slack_adapter
import supernova/adapters/telegram
import supernova/adapters/wechat_work_adapter
import supernova/adapters/whatsapp_adapter
import supernova/channel/chat_lanes
import supernova/channel/chunking
import supernova/channel/port
import supernova/config
import supernova/core/access/actor as access_actor
import supernova/core/audit_log/actor as audit_actor
import supernova/core/audit_log/types as audit_types
import supernova/core/closed_group/global as closed_group_global

// ============================================================================
// Types
// ============================================================================

/// A registry of all channel adapters, keyed by channel name.
pub type ChannelRegistry {
  ChannelRegistry(
    id: String,
    channels: Dict(String, port.ChannelAdapter),
    streams: Dict(String, StreamSendFn),
  )
}

/// Optional hooks for deterministic bootstrap tests.
pub type StartHooks {
  StartHooks(
    discord_events: List(discord_gateway.DiscordEvent),
    telegram_updates: List(telegram.Update),
    slack_inbound_events: List(port.ChannelInbound),
    matrix_inbound_events: List(port.ChannelInbound),
    disable_telegram_polling: Bool,
    typing_keepalive_ms: Int,
    stream_timeout_ms: Int,
    turn_hard_timeout_ms: Int,
    registry_id: String,
    outbound_records: Option(process.Subject(OutboundRecord)),
    leave_group: Option(fn(String) -> Bool),
    leave_retry_ms: List(Int),
  )
}

/// Test-only outbound observation record for channel runtime sends/edits.
pub type OutboundRecord {
  OutboundRecord(
    channel: String,
    action: String,
    content: String,
    message_id: Option(String),
  )
}

type DiscordBridgeControl {
  StopDiscordBridge
}

type DiscordBridgeReady {
  DiscordBridgeReady(
    events: process.Subject(discord_gateway.DiscordEvent),
    control: process.Subject(DiscordBridgeControl),
  )
}

type DiscordBridge {
  DiscordBridge(
    events: process.Subject(discord_gateway.DiscordEvent),
    control: process.Subject(DiscordBridgeControl),
    done: process.Subject(Nil),
  )
}

type TelegramWorker {
  TelegramWorker(done: process.Subject(Nil))
}

type StreamSendFn =
  fn(port.ChannelReply, process.Subject(port.ChannelStreamEvent)) ->
    Result(Nil, port.ChannelError)

const default_typing_keepalive_ms = 4000

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn new_registry_id() -> String {
  "registry:"
  <> int.to_string(unique_integer())
  <> ":"
  <> int.to_string(current_timestamp())
}

const stream_timeout_ms = 60_000

const turn_hard_timeout_ms = 300_000

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int

// ============================================================================
// Public API
// ============================================================================

/// Build empty bootstrap hooks for production startup.
pub fn no_start_hooks() -> StartHooks {
  StartHooks(
    discord_events: [],
    telegram_updates: [],
    slack_inbound_events: [],
    matrix_inbound_events: [],
    disable_telegram_polling: False,
    typing_keepalive_ms: default_typing_keepalive_ms,
    stream_timeout_ms: 60_000,
    turn_hard_timeout_ms: 300_000,
    registry_id: "",
    outbound_records: None,
    leave_group: None,
    leave_retry_ms: [5000, 30_000, 120_000],
  )
}

/// Start all enabled channel adapters based on configuration.
///
/// Returns a ChannelRegistry containing send functions for each enabled channel.
pub fn start_channels(cfg: config.Config) -> Result(ChannelRegistry, String) {
  start_channels_with_handler(cfg, noop_handler())
}

/// Start all enabled channel adapters with an injected inbound handler.
pub fn start_channels_with_handler(
  cfg: config.Config,
  handler: port.ChannelHandler,
) -> Result(ChannelRegistry, String) {
  start_channels_with_handler_and_hooks(cfg, handler, no_start_hooks())
}

/// Start all enabled channel adapters with an injected inbound handler.
///
/// `hooks` exists to keep registry tests deterministic without live network
/// dependencies.
pub fn start_channels_with_handler_and_hooks(
  cfg: config.Config,
  handler: port.ChannelHandler,
  hooks: StartHooks,
) -> Result(ChannelRegistry, String) {
  let registry_id = new_registry_id()
  let hooks = StartHooks(..hooks, registry_id: registry_id)
  let channels = dict.new()
  let streams = dict.new()

  let #(channels, streams) = case config.is_discord_enabled(cfg) {
    True -> {
      case start_discord_channel(cfg.discord, handler, hooks) {
        Ok(#(adapter, stream_send_fn)) -> {
          io.println("Discord: gateway and REST client started")
          insert_channel(channels, streams, adapter, Some(stream_send_fn))
        }
        Error(reason) -> {
          io.println("Discord: failed to start - " <> reason)
          #(channels, streams)
        }
      }
    }
    False -> #(channels, streams)
  }

  let #(channels, streams) = case config.is_matrix_enabled(cfg) {
    True -> {
      case start_matrix_channel(cfg.matrix, handler, hooks) {
        Ok(#(adapter, stream_send_fn)) -> {
          io.println("Matrix: adapter ready")
          insert_channel(channels, streams, adapter, Some(stream_send_fn))
        }
        Error(reason) -> {
          io.println("Matrix: failed to start - " <> reason)
          #(channels, streams)
        }
      }
    }
    False -> #(channels, streams)
  }

  let #(channels, streams) = case config.is_mattermost_enabled(cfg) {
    True -> {
      case start_mattermost_channel(cfg.mattermost, handler) {
        Ok(adapter) -> {
          io.println("Mattermost: adapter ready")
          insert_channel(channels, streams, adapter, None)
        }
        Error(reason) -> {
          io.println("Mattermost: failed to start - " <> reason)
          #(channels, streams)
        }
      }
    }
    False -> #(channels, streams)
  }

  let #(channels, streams) = case config.is_whatsapp_enabled(cfg) {
    True -> {
      case start_whatsapp_channel(cfg.whatsapp, handler) {
        Ok(adapter) -> {
          io.println("WhatsApp: bridge adapter ready")
          insert_channel(channels, streams, adapter, None)
        }
        Error(reason) -> {
          io.println("WhatsApp: failed to start - " <> reason)
          #(channels, streams)
        }
      }
    }
    False -> #(channels, streams)
  }

  let #(channels, streams) = case config.is_telegram_enabled(cfg) {
    True -> {
      case start_telegram_channel(cfg.telegram, handler, hooks) {
        Ok(#(adapter, stream_send_fn)) -> {
          io.println("Telegram: poller started")
          insert_channel(channels, streams, adapter, Some(stream_send_fn))
        }
        Error(reason) -> {
          io.println("Telegram: failed to start - " <> reason)
          #(channels, streams)
        }
      }
    }
    False -> #(channels, streams)
  }

  let #(channels, streams) = case config.is_slack_enabled(cfg) {
    True -> {
      case start_slack_channel(cfg.slack, handler, hooks) {
        Ok(#(adapter, stream_send_fn)) -> {
          io.println("Slack: adapter ready")
          insert_channel(channels, streams, adapter, Some(stream_send_fn))
        }
        Error(reason) -> {
          io.println("Slack: failed to start - " <> reason)
          #(channels, streams)
        }
      }
    }
    False -> #(channels, streams)
  }

  let #(channels, streams) = case config.is_lark_enabled(cfg) {
    True -> {
      case start_lark_channel(cfg.lark, handler) {
        Ok(adapter) -> {
          io.println("Lark: adapter ready")
          insert_channel(channels, streams, adapter, None)
        }
        Error(reason) -> {
          io.println("Lark: failed to start - " <> reason)
          #(channels, streams)
        }
      }
    }
    False -> #(channels, streams)
  }

  let #(channels, streams) = case config.is_google_chat_enabled(cfg) {
    True -> {
      case start_google_chat_channel(cfg.google_chat, handler) {
        Ok(adapter) -> {
          io.println("Google Chat: adapter ready")
          insert_channel(channels, streams, adapter, None)
        }
        Error(reason) -> {
          io.println("Google Chat: failed to start - " <> reason)
          #(channels, streams)
        }
      }
    }
    False -> #(channels, streams)
  }

  let #(channels, streams) = case config.is_wechat_work_enabled(cfg) {
    True -> {
      case start_wechat_work_channel(cfg.wechat_work, handler) {
        Ok(adapter) -> {
          io.println("WeChat Work: adapter ready")
          insert_channel(channels, streams, adapter, None)
        }
        Error(reason) -> {
          io.println("WeChat Work: failed to start - " <> reason)
          #(channels, streams)
        }
      }
    }
    False -> #(channels, streams)
  }

  let total = dict.size(channels)
  io.println("Started " <> int.to_string(total) <> " channel adapter(s)")

  Ok(ChannelRegistry(id: registry_id, channels: channels, streams: streams))
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
  streams: Dict(String, StreamSendFn),
  adapter: port.ChannelAdapter,
  stream_send: Option(StreamSendFn),
) -> #(Dict(String, port.ChannelAdapter), Dict(String, StreamSendFn)) {
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

fn start_discord_channel(
  discord_cfg: config.DiscordConfig,
  handler: port.ChannelHandler,
  hooks: StartHooks,
) -> Result(#(port.ChannelAdapter, StreamSendFn), String) {
  case discord_cfg.token {
    Some(token) -> {
      let gateway_config =
        discord_gateway.GatewayConfig(
          ..discord_gateway.default_config(token),
          intents: discord_gateway.message_content_intents(),
          app_id: discord_cfg.app_id,
        )

      use gateway <- result.try(
        discord_gateway.start(gateway_config)
        |> result.map_error(fn(_) { "failed to start gateway actor" }),
      )

      use _ <- result.try(
        discord_gateway.connect(gateway)
        |> result.map_error(fn(error) {
          "failed to connect gateway: "
          <> discord_gateway.error_to_string(error)
        }),
      )

      use rest_client <- result.try(
        discord_rest.start(discord_rest.new_config(token))
        |> result.map_error(fn(_) { "failed to start REST client" }),
      )

      let send_fn = discord_send(rest_client, hooks)
      let stream_send_fn = discord_stream_send(rest_client, hooks)

      use bridge <- result.try(start_discord_bridge(
        handler,
        send_fn,
        stream_send_fn,
        hooks.registry_id,
      ))

      let subscription_id = discord_gateway.subscribe(gateway, bridge.events)

      hooks.discord_events
      |> list.each(fn(event) { process.send(bridge.events, event) })

      Ok(#(
        port.ChannelAdapter(name: "discord", send: send_fn, stop: fn() {
          let _ = discord_gateway.unsubscribe(gateway, subscription_id)
          stop_discord_bridge(bridge)
          discord_rest.stop(rest_client)
          discord_gateway.stop(gateway)
        }),
        stream_send_fn,
      ))
    }
    None -> Error("enabled but no token configured")
  }
}

fn start_telegram_channel(
  telegram_cfg: config.TelegramConfig,
  handler: port.ChannelHandler,
  hooks: StartHooks,
) -> Result(#(port.ChannelAdapter, StreamSendFn), String) {
  case telegram_cfg.token {
    Some(token) -> {
      let poller_config = telegram.new_config(token)
      let send_fn = telegram_send(poller_config, hooks)
      let stream_send_fn = telegram_stream_send(poller_config, hooks)

      use poller <- result.try(
        telegram.start_poller(poller_config)
        |> result.map_error(fn(_) { "failed to start poller actor" }),
      )

      let worker =
        start_telegram_worker(
          poller,
          handler,
          send_fn,
          stream_send_fn,
          hooks,
          poller_config,
        )

      Ok(#(
        port.ChannelAdapter(name: "telegram", send: send_fn, stop: fn() {
          let _ = telegram.stop_polling(poller)
          stop_telegram_worker(worker, poller_config.polling_timeout)
          Nil
        }),
        stream_send_fn,
      ))
    }
    None -> Error("enabled but no token configured")
  }
}

fn start_slack_channel(
  slack_cfg: config.SlackConfig,
  handler: port.ChannelHandler,
  hooks: StartHooks,
) -> Result(#(port.ChannelAdapter, StreamSendFn), String) {
  case slack_cfg.token {
    Some(token) -> {
      let send_fn = slack_send(token, hooks)
      let stream_send_fn = slack_stream_send(token, hooks)

      hooks.slack_inbound_events
      |> list.each(fn(inbound) {
        dispatch_inbound(
          handler,
          send_fn,
          stream_send_fn,
          inbound,
          hooks.registry_id,
        )
      })

      Ok(#(
        port.ChannelAdapter(name: "slack", send: send_fn, stop: fn() { Nil }),
        stream_send_fn,
      ))
    }
    None -> Error("enabled but no token configured")
  }
}

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

fn start_matrix_channel(
  matrix_cfg: config.MatrixConfig,
  handler: port.ChannelHandler,
  hooks: StartHooks,
) -> Result(#(port.ChannelAdapter, StreamSendFn), String) {
  case matrix_cfg.homeserver_url, matrix_cfg.token {
    Some(homeserver_url), Some(token) -> {
      let send_fn = matrix_send(homeserver_url, token, hooks)
      let stream_send_fn = matrix_stream_send(homeserver_url, token, hooks)

      hooks.matrix_inbound_events
      |> list.each(fn(inbound) {
        dispatch_inbound(
          handler,
          send_fn,
          stream_send_fn,
          inbound,
          hooks.registry_id,
        )
      })

      Ok(#(
        port.ChannelAdapter(name: "matrix", send: send_fn, stop: fn() { Nil }),
        stream_send_fn,
      ))
    }
    None, _ -> Error("enabled but no homeserver_url configured")
    _, None -> Error("enabled but no token configured")
  }
}

// ============================================================================
// Inbound Runtime
// ============================================================================

fn start_discord_bridge(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: StreamSendFn,
  registry_id: String,
) -> Result(DiscordBridge, String) {
  let ready = process.new_subject()
  let done = process.new_subject()

  let _ =
    process.spawn_unlinked(fn() {
      let events = process.new_subject()
      let control = process.new_subject()
      process.send(ready, DiscordBridgeReady(events: events, control: control))
      discord_bridge_loop(
        handler,
        send_fn,
        stream_send_fn,
        events,
        control,
        done,
        registry_id,
      )
    })

  case process.receive(ready, within: 1000) {
    Ok(DiscordBridgeReady(events, control)) ->
      Ok(DiscordBridge(events: events, control: control, done: done))
    Error(_) -> Error("failed to start discord inbound bridge")
  }
}

fn discord_bridge_loop(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: StreamSendFn,
  events: process.Subject(discord_gateway.DiscordEvent),
  control: process.Subject(DiscordBridgeControl),
  done: process.Subject(Nil),
  registry_id: String,
) -> Nil {
  case process.receive(control, within: 0) {
    Ok(StopDiscordBridge) -> process.send(done, Nil)
    Error(_) -> {
      case process.receive(events, within: 100) {
        Ok(event) -> {
          dispatch_discord_event(
            handler,
            send_fn,
            stream_send_fn,
            event,
            registry_id,
          )
          discord_bridge_loop(
            handler,
            send_fn,
            stream_send_fn,
            events,
            control,
            done,
            registry_id,
          )
        }
        Error(_) ->
          discord_bridge_loop(
            handler,
            send_fn,
            stream_send_fn,
            events,
            control,
            done,
            registry_id,
          )
      }
    }
  }
}

fn stop_discord_bridge(bridge: DiscordBridge) -> Nil {
  process.send(bridge.control, StopDiscordBridge)
  let _ = process.receive(bridge.done, within: 1000)
  Nil
}

fn start_telegram_worker(
  poller: telegram.Poller,
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: StreamSendFn,
  hooks: StartHooks,
  telegram_config: telegram.Config,
) -> TelegramWorker {
  let done = process.new_subject()

  let _ =
    process.spawn_unlinked(fn() {
      case hooks.disable_telegram_polling {
        True ->
          hooks.telegram_updates
          |> list.each(fn(update) {
            dispatch_telegram_update(
              handler,
              send_fn,
              stream_send_fn,
              update,
              telegram_config,
              hooks.leave_group,
              hooks.leave_retry_ms,
              hooks.registry_id,
            )
          })
        False -> {
          hooks.telegram_updates
          |> list.each(fn(update) {
            dispatch_telegram_update(
              handler,
              send_fn,
              stream_send_fn,
              update,
              telegram_config,
              hooks.leave_group,
              hooks.leave_retry_ms,
              hooks.registry_id,
            )
          })

          let _ =
            telegram.start_polling_loop(poller, fn(update) {
              dispatch_telegram_update(
                handler,
                send_fn,
                stream_send_fn,
                update,
                telegram_config,
                hooks.leave_group,
                hooks.leave_retry_ms,
                hooks.registry_id,
              )
            })
          Nil
        }
      }

      process.send(done, Nil)
    })

  TelegramWorker(done: done)
}

fn stop_telegram_worker(worker: TelegramWorker, polling_timeout: Int) -> Nil {
  let wait_ms = { polling_timeout + 5 } * 1000
  let _ = process.receive(worker.done, within: wait_ms)
  Nil
}

fn dispatch_discord_event(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: StreamSendFn,
  event: discord_gateway.DiscordEvent,
  registry_id: String,
) -> Nil {
  case event {
    discord_gateway.MessageCreate(data) ->
      case discord_events.parse_event("MESSAGE_CREATE", data) {
        discord_events.EventMessageCreate(message) ->
          dispatch_inbound(
            handler,
            send_fn,
            stream_send_fn,
            port.inbound_message(discord_message_to_port(message)),
            registry_id,
          )
        _ -> Nil
      }
    discord_gateway.RawEvent("INTERACTION_CREATE", data) ->
      case discord_events.parse_event("INTERACTION_CREATE", data) {
        discord_events.EventInteractionCreate(interaction) ->
          case discord_interaction_to_inbound(interaction) {
            Ok(inbound) ->
              dispatch_inbound(
                handler,
                send_fn,
                stream_send_fn,
                inbound,
                registry_id,
              )
            Error(_) -> Nil
          }
        _ -> Nil
      }
    _ -> Nil
  }
}

fn dispatch_telegram_update(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: StreamSendFn,
  update: telegram.Update,
  telegram_config: telegram.Config,
  leave_group: Option(fn(String) -> Bool),
  leave_retry_ms: List(Int),
  registry_id: String,
) -> Nil {
  case update.my_chat_member {
    Some(member) ->
      maybe_leave_unauthorized_group(
        telegram_config,
        member,
        leave_group,
        leave_retry_ms,
      )
    None -> Nil
  }
  case telegram_update_to_inbound(update) {
    Ok(inbound) ->
      dispatch_inbound(handler, send_fn, stream_send_fn, inbound, registry_id)
    Error(_) -> Nil
  }
}

fn maybe_leave_unauthorized_group(
  telegram_config: telegram.Config,
  member: telegram.ChatMemberUpdated,
  leave_group: Option(fn(String) -> Bool),
  leave_retry_ms: List(Int),
) -> Nil {
  let is_group = case member.chat.chat_type {
    telegram.GroupChat | telegram.SupergroupChat -> True
    _ -> False
  }
  let joined = case member.new_status {
    "member" | "administrator" -> True
    _ -> False
  }
  let chat_key = "telegram:" <> member.chat.id
  case is_group && joined {
    True ->
      case closed_group_global.chat_authorized_result(chat_key) {
        Ok(True) -> Nil
        Ok(False) ->
          leave_confirmed(
            telegram_config,
            member.chat.id,
            chat_key,
            leave_group,
            leave_retry_ms,
          )
        Error(_) -> {
          io.println(
            "warn: access lookup failed while checking chat " <> chat_key,
          )
          record_chat_check_failed(chat_key)
          schedule_leave_recheck(
            telegram_config,
            member,
            leave_group,
            leave_retry_ms,
          )
        }
      }
    False -> Nil
  }
}

fn leave_confirmed(
  telegram_config: telegram.Config,
  chat_id: String,
  chat_key: String,
  leave_group: Option(fn(String) -> Bool),
  retry_delays: List(Int),
) -> Nil {
  case leave_group {
    Some(leave) ->
      case leave(chat_id) {
        True -> record_leave_audit(chat_key)
        False ->
          schedule_leave_retry(
            telegram_config,
            chat_id,
            chat_key,
            leave_group,
            retry_delays,
          )
      }
    None ->
      case telegram.leave_chat(telegram_config, chat_id) {
        Ok(_) -> record_leave_audit(chat_key)
        Error(_) ->
          schedule_leave_retry(
            telegram_config,
            chat_id,
            chat_key,
            leave_group,
            retry_delays,
          )
      }
  }
}

fn schedule_leave_retry(
  telegram_config: telegram.Config,
  chat_id: String,
  chat_key: String,
  leave_group: Option(fn(String) -> Bool),
  retry_delays: List(Int),
) -> Nil {
  case retry_delays {
    [] -> {
      record_leave_failed(chat_key)
      alert_admins(
        "Não consegui sair do grupo não autorizado " <> chat_key <> ".",
      )
      Nil
    }
    [delay, ..rest] -> {
      let _ =
        process.spawn_unlinked(fn() {
          process.sleep(delay)
          leave_confirmed(telegram_config, chat_id, chat_key, leave_group, rest)
        })
      Nil
    }
  }
}

fn schedule_leave_recheck(
  telegram_config: telegram.Config,
  member: telegram.ChatMemberUpdated,
  leave_group: Option(fn(String) -> Bool),
  retry_delays: List(Int),
) -> Nil {
  process.spawn_unlinked(fn() {
    process.sleep(30_000)
    recheck_leave(telegram_config, member, leave_group, retry_delays)
  })
  Nil
}

fn recheck_leave(
  telegram_config: telegram.Config,
  member: telegram.ChatMemberUpdated,
  leave_group: Option(fn(String) -> Bool),
  retry_delays: List(Int),
) -> Nil {
  let chat_key = "telegram:" <> member.chat.id
  case closed_group_global.chat_authorized_result(chat_key) {
    Ok(True) -> Nil
    Ok(False) ->
      leave_confirmed(
        telegram_config,
        member.chat.id,
        chat_key,
        leave_group,
        retry_delays,
      )
    Error(_) -> {
      io.println(
        "warn: access lookup failed again while checking chat " <> chat_key,
      )
      record_chat_check_failed(chat_key)
    }
  }
}

fn record_leave_failed(chat_key: String) -> Nil {
  case closed_group_global.get_audit() {
    None -> Nil
    Some(audit) ->
      audit_actor.log_entry(
        audit,
        audit_types.denied_entry(
          closed_group_global.now(),
          "telegram",
          "leave_failed",
          chat_key,
          "Telegram did not confirm the leave",
        ),
      )
  }
}

fn alert_admins(text: String) -> Nil {
  case closed_group_global.get_runtime() {
    None -> Nil
    Some(runtime) -> {
      let admins = case access_actor.list_admins(runtime.access) {
        [] -> runtime.config.access.admins
        admins -> admins
      }
      list.each(admins, fn(admin) { runtime.send_alert(admin, text) })
    }
  }
}

fn record_chat_check_failed(chat_key: String) -> Nil {
  case closed_group_global.get_audit() {
    None -> Nil
    Some(audit) ->
      audit_actor.log_entry(
        audit,
        audit_types.denied_entry(
          closed_group_global.now(),
          "telegram",
          "chat_check_failed",
          chat_key,
          "access lookup unavailable",
        ),
      )
  }
}

fn record_leave_audit(chat_key: String) -> Nil {
  case closed_group_global.get_audit() {
    None -> Nil
    Some(audit) ->
      audit_actor.log_entry(
        audit,
        audit_types.denied_entry(
          closed_group_global.now(),
          "telegram",
          "chat_denied",
          chat_key,
          "left unauthorized group",
        ),
      )
  }
}

/// Hand the inbound turn to the lane of its chat and return immediately.
///
/// The polling loop must never wait for a turn: a slow LLM or tool call
/// would hold every other chat of the channel. Turns of the same chat stay
/// ordered inside their lane.
fn dispatch_inbound(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: StreamSendFn,
  inbound: port.ChannelInbound,
  registry_id: String,
) -> Nil {
  let key = chat_lanes.key_for_registry(registry_id, inbound)
  let _ =
    chat_lanes.submit(key, fn() {
      run_inbound_turn(handler, send_fn, stream_send_fn, inbound, key)
    })
  Nil
}

fn run_inbound_turn(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: StreamSendFn,
  inbound: port.ChannelInbound,
  chat_key: String,
) -> Nil {
  let stream_events = process.new_subject()

  case handler(inbound, stream_events) {
    Ok(port.ImmediateReply(reply)) -> {
      let _ = send_fn(reply)
      Nil
    }
    Ok(port.StreamReply(base_reply)) -> {
      case stream_send_fn(base_reply, stream_events) {
        Ok(_) -> Nil
        Error(port.SendFailed("stream timed out")) ->
          await_late_terminal(
            stream_events,
            send_fn,
            base_reply,
            chat_key,
            current_timestamp() + turn_hard_timeout_ms,
          )
        Error(_) -> Nil
      }
    }
    Error(_) -> Nil
  }
}

fn await_late_terminal(
  events: process.Subject(port.ChannelStreamEvent),
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  base_reply: port.ChannelReply,
  chat_key: String,
  deadline: Int,
) -> Nil {
  let remaining = deadline - current_timestamp()
  case remaining <= 0 {
    True -> {
      io.println("error: chat lane turn hard timeout key=" <> chat_key)
      Nil
    }
    False ->
      case process.receive(events, within: remaining) {
        Ok(port.StreamComplete(reply)) -> {
          case string.trim(reply.content) {
            "" -> Nil
            _ -> {
              let _ =
                send_fn(
                  port.ChannelReply(
                    ..base_reply,
                    content: reply.content,
                    edit_message_id: None,
                    typing: False,
                  ),
                )
              Nil
            }
          }
        }
        Ok(port.StreamFailure(_)) -> Nil
        Ok(port.StreamUpdate(_)) ->
          await_late_terminal(events, send_fn, base_reply, chat_key, deadline)
        Error(_) -> {
          io.println("error: chat lane turn hard timeout key=" <> chat_key)
          Nil
        }
      }
  }
}

fn discord_message_to_port(
  message: discord_events.Message,
) -> port.ChannelMessage {
  port.ChannelMessage(
    id: message.id,
    channel: "discord",
    channel_id: discord_chat_id(message.channel_id, message.guild_id),
    user_id: message.author.id,
    username: message.author.username,
    content: message.content,
    is_bot: discord_is_bot(message.author.bot),
    reply_to_id: discord_reply_to_id(message.message_reference),
  )
}

fn discord_chat_id(channel_id: String, guild_id: Option(String)) -> String {
  case guild_id {
    Some(guild) -> channel_id <> "@guild:" <> guild
    None -> "dm:" <> channel_id
  }
}

fn discord_is_bot(bot: Option(Bool)) -> Bool {
  case bot {
    Some(is_bot) -> is_bot
    None -> False
  }
}

fn discord_interaction_to_inbound(
  interaction: discord_events.Interaction,
) -> Result(port.ChannelInbound, port.ChannelError) {
  use raw_channel_id <- result.try(require_discord_channel_id(
    interaction.channel_id,
  ))
  let channel_id = discord_chat_id(raw_channel_id, interaction.guild_id)
  let #(user_id, username, is_bot) = discord_interaction_sender(interaction)

  case interaction.interaction_type, interaction.data {
    discord_events.ApplicationCommand, Some(command_data) ->
      discord_command_interaction_to_inbound(
        interaction,
        channel_id,
        user_id,
        username,
        is_bot,
        command_data,
      )
    discord_events.ApplicationCommandAutocomplete, _ ->
      Error(port.Ignored("discord autocomplete interaction ignored"))
    discord_events.MessageComponent, Some(component_data) ->
      discord_component_interaction_to_inbound(
        interaction,
        channel_id,
        user_id,
        username,
        is_bot,
        component_data,
      )
    _, _ -> Error(port.Ignored("unsupported discord interaction"))
  }
}

fn require_discord_channel_id(
  channel_id: Option(String),
) -> Result(String, port.ChannelError) {
  case channel_id {
    Some(value) -> Ok(value)
    None -> Error(port.Ignored("discord interaction missing channel_id"))
  }
}

fn discord_interaction_sender(
  interaction: discord_events.Interaction,
) -> #(String, String, Bool) {
  case interaction.member {
    Some(member) ->
      case member.user {
        Some(user) -> #(user.id, user.username, discord_is_bot(user.bot))
        None -> discord_optional_user_to_sender(interaction.user)
      }
    None -> discord_optional_user_to_sender(interaction.user)
  }
}

fn discord_optional_user_to_sender(
  user: Option(discord_events.User),
) -> #(String, String, Bool) {
  case user {
    Some(value) -> #(value.id, value.username, discord_is_bot(value.bot))
    None -> #("unknown", "", False)
  }
}

fn discord_command_interaction_to_inbound(
  interaction: discord_events.Interaction,
  channel_id: String,
  user_id: String,
  username: String,
  is_bot: Bool,
  command_data: discord_events.InteractionData,
) -> Result(port.ChannelInbound, port.ChannelError) {
  case command_data {
    discord_events.ApplicationCommandData(name:, options:, ..) ->
      Ok(
        port.inbound_message(port.ChannelMessage(
          id: interaction.id,
          channel: "discord",
          channel_id: channel_id,
          user_id: user_id,
          username: username,
          content: discord_slash_command_text(name, options),
          is_bot: is_bot,
          reply_to_id: None,
        )),
      )
    _ -> Error(port.Ignored("discord interaction missing command data"))
  }
}

fn discord_slash_command_text(
  name: String,
  options: List(discord_events.ApplicationCommandOption),
) -> String {
  case options {
    [] -> "/" <> name
    _ ->
      "/"
      <> name
      <> " "
      <> string.join(list.map(options, discord_command_option_to_text), " ")
  }
}

fn discord_command_option_to_text(
  option: discord_events.ApplicationCommandOption,
) -> String {
  let discord_events.ApplicationCommandOption(name:, value:, options:, ..) =
    option

  case value {
    Some(option_value) ->
      name <> ":" <> discord_option_value_to_text(option_value)
    None ->
      case options {
        [] -> name
        _ ->
          name
          <> " "
          <> string.join(list.map(options, discord_command_option_to_text), " ")
      }
  }
}

fn discord_option_value_to_text(
  value: discord_events.CommandOptionValue,
) -> String {
  case value {
    discord_events.StringValue(text) -> text
    discord_events.IntValue(number) -> int.to_string(number)
    discord_events.BoolValue(flag) ->
      case flag {
        True -> "true"
        False -> "false"
      }
    discord_events.UserValue(id) -> id
    discord_events.ChannelValue(id) -> id
    discord_events.RoleValue(id) -> id
  }
}

fn discord_component_interaction_to_inbound(
  interaction: discord_events.Interaction,
  channel_id: String,
  user_id: String,
  username: String,
  is_bot: Bool,
  component_data: discord_events.InteractionData,
) -> Result(port.ChannelInbound, port.ChannelError) {
  case component_data {
    discord_events.MessageComponentData(custom_id:, values:, ..) ->
      Ok(
        port.inbound_interaction(port.ChannelInteractionMessage(
          channel: "discord",
          channel_id: channel_id,
          user_id: user_id,
          username: username,
          is_bot: is_bot,
          event: port.ChannelInteractionEvent(
            id: interaction.id,
            action_id: custom_id,
            values: discord_component_values(values),
            source_message_id: None,
          ),
        )),
      )
    _ -> Error(port.Ignored("discord interaction missing component data"))
  }
}

fn discord_component_values(values: Option(List(String))) -> List(String) {
  case values {
    Some(selected) -> selected
    None -> []
  }
}

fn discord_reply_to_id(
  reference: Option(discord_events.MessageReference),
) -> Option(String) {
  case reference {
    Some(message_reference) -> message_reference.message_id
    None -> None
  }
}

fn telegram_update_to_inbound(
  update: telegram.Update,
) -> Result(port.ChannelInbound, port.ChannelError) {
  case update.message {
    Some(message) ->
      case message.from {
        Some(from) ->
          Ok(
            port.inbound_message(port.ChannelMessage(
              id: int.to_string(message.message_id),
              channel: "telegram",
              channel_id: message.chat.id,
              user_id: from.id,
              username: telegram_username(from),
              content: telegram_message_content(message),
              is_bot: from.is_bot,
              reply_to_id: telegram_reply_to_id(message.reply_to_message_id),
            )),
          )
        None -> Error(port.Ignored("telegram message missing sender"))
      }
    None ->
      case update.callback_query {
        Some(callback) ->
          case
            telegram_callback_query_to_inbound(
              callback,
              telegram_callback_query_message_id(callback.message),
            )
          {
            Ok(inbound) -> Ok(inbound)
            Error(error) -> Error(error)
          }
        None -> Error(port.Ignored("unsupported telegram update"))
      }
  }
}

fn telegram_callback_query_to_inbound(
  callback: telegram.CallbackQuery,
  source_message_id: Option(String),
) -> Result(port.ChannelInbound, port.ChannelError) {
  let telegram.CallbackQuery(
    id: callback_id,
    from: user,
    message: message,
    data: data,
    ..,
  ) = callback

  case message, data {
    Some(message), Some(callback_data) -> {
      let #(action_id, values) = telegram_callback_action(callback_data)

      Ok(
        port.inbound_interaction(port.ChannelInteractionMessage(
          channel: "telegram",
          channel_id: message.chat.id,
          user_id: user.id,
          username: telegram_username(user),
          is_bot: user.is_bot,
          event: port.ChannelInteractionEvent(
            id: callback_id,
            action_id: action_id,
            values: values,
            source_message_id: source_message_id,
          ),
        )),
      )
    }
    None, _ -> Error(port.Ignored("telegram callback query missing message"))
    _, None -> Error(port.Ignored("telegram callback query missing data"))
  }
}

fn telegram_callback_query_message_id(
  message: Option(telegram.Message),
) -> Option(String) {
  case message {
    Some(message) -> Some(int.to_string(message.message_id))
    None -> None
  }
}

fn telegram_callback_action(callback_data: String) -> #(String, List(String)) {
  let model_select_prefix = "picker_model_select:"

  case string.starts_with(callback_data, model_select_prefix) {
    True -> #("picker_model_select", [
      string.drop_start(callback_data, string.length(model_select_prefix)),
    ])
    False -> #(callback_data, [])
  }
}

fn telegram_username(user: telegram.User) -> String {
  case user.username {
    Some(username) -> username
    None -> user.first_name
  }
}

fn telegram_message_content(message: telegram.Message) -> String {
  case message.text {
    Some(text) -> text
    None ->
      case message.caption {
        Some(caption) -> caption
        None -> ""
      }
  }
}

fn telegram_reply_to_id(reply_to_message_id: Option(Int)) -> Option(String) {
  case reply_to_message_id {
    Some(message_id) -> Some(int.to_string(message_id))
    None -> None
  }
}

fn noop_handler() -> port.ChannelHandler {
  fn(_, _) { Error(port.Ignored("no inbound handler configured")) }
}

// ============================================================================
// Outbound Senders
// ============================================================================

fn discord_send(
  rest_client: discord_rest.RestClient,
  hooks: StartHooks,
) -> fn(port.ChannelReply) -> Result(Nil, port.ChannelError) {
  fn(reply: port.ChannelReply) {
    let replies = chunking.split_reply(reply, chunking.discord_max_length)

    case hooks.outbound_records {
      Some(recorder) -> record_reply_for_test(recorder, "discord", replies)
      None ->
        send_chunked_replies(replies, fn(part) {
          case discord_send_message(rest_client, part) {
            Ok(_) -> Ok(Nil)
            Error(error) -> Error(error)
          }
        })
    }
  }
}

fn telegram_send(
  telegram_config: telegram.Config,
  hooks: StartHooks,
) -> fn(port.ChannelReply) -> Result(Nil, port.ChannelError) {
  fn(reply: port.ChannelReply) {
    let replies = chunking.split_reply(reply, chunking.telegram_max_length)

    case hooks.outbound_records {
      Some(recorder) -> record_reply_for_test(recorder, "telegram", replies)
      None ->
        send_chunked_replies(replies, fn(part) {
          case telegram_send_message(telegram_config, part) {
            Ok(_) -> Ok(Nil)
            Error(error) -> Error(error)
          }
        })
    }
  }
}

fn discord_stream_send(
  rest_client: discord_rest.RestClient,
  hooks: StartHooks,
) -> StreamSendFn {
  fn(
    base_reply: port.ChannelReply,
    events: process.Subject(port.ChannelStreamEvent),
  ) {
    let keepalive_ms = normalize_typing_keepalive_ms(hooks.typing_keepalive_ms)
    case hooks.outbound_records {
      Some(recorder) ->
        record_stream_for_test(
          recorder,
          "discord",
          base_reply,
          events,
          keepalive_ms,
          hooks.stream_timeout_ms,
        )
      None ->
        stream_discord_reply(rest_client, base_reply, events, keepalive_ms)
    }
  }
}

fn telegram_stream_send(
  telegram_config: telegram.Config,
  hooks: StartHooks,
) -> StreamSendFn {
  fn(
    base_reply: port.ChannelReply,
    events: process.Subject(port.ChannelStreamEvent),
  ) {
    let keepalive_ms = normalize_typing_keepalive_ms(hooks.typing_keepalive_ms)
    case hooks.outbound_records {
      Some(recorder) ->
        record_stream_for_test(
          recorder,
          "telegram",
          base_reply,
          events,
          keepalive_ms,
          hooks.stream_timeout_ms,
        )
      None ->
        stream_telegram_reply(telegram_config, base_reply, events, keepalive_ms)
    }
  }
}

fn slack_send(
  bot_token: String,
  hooks: StartHooks,
) -> fn(port.ChannelReply) -> Result(Nil, port.ChannelError) {
  fn(reply: port.ChannelReply) {
    case hooks.outbound_records {
      Some(recorder) -> record_reply_for_test(recorder, "slack", [reply])
      None -> slack_adapter.send_reply(bot_token, reply)
    }
  }
}

fn slack_stream_send(bot_token: String, hooks: StartHooks) -> StreamSendFn {
  fn(
    base_reply: port.ChannelReply,
    events: process.Subject(port.ChannelStreamEvent),
  ) {
    case hooks.outbound_records {
      Some(recorder) ->
        record_slack_stream_for_test(recorder, base_reply, events)
      None -> stream_slack_reply(bot_token, base_reply, events)
    }
  }
}

fn matrix_send(
  homeserver_url: String,
  access_token: String,
  hooks: StartHooks,
) -> fn(port.ChannelReply) -> Result(Nil, port.ChannelError) {
  fn(reply: port.ChannelReply) {
    case hooks.outbound_records {
      Some(recorder) -> record_reply_for_test(recorder, "matrix", [reply])
      None -> matrix_adapter.send_reply(homeserver_url, access_token, reply)
    }
  }
}

fn matrix_stream_send(
  homeserver_url: String,
  access_token: String,
  hooks: StartHooks,
) -> StreamSendFn {
  fn(
    base_reply: port.ChannelReply,
    events: process.Subject(port.ChannelStreamEvent),
  ) {
    let keepalive_ms = normalize_typing_keepalive_ms(hooks.typing_keepalive_ms)
    case hooks.outbound_records {
      Some(recorder) ->
        record_stream_for_test(
          recorder,
          "matrix",
          base_reply,
          events,
          keepalive_ms,
          hooks.stream_timeout_ms,
        )
      None ->
        stream_matrix_reply(
          homeserver_url,
          access_token,
          base_reply,
          events,
          keepalive_ms,
        )
    }
  }
}

fn discord_send_message(
  rest_client: discord_rest.RestClient,
  reply: port.ChannelReply,
) -> Result(discord_rest.SentMessage, port.ChannelError) {
  use target_channel <- result.try(discord_delivery_channel(rest_client, reply))
  let options = discord_options_for_reply(reply)

  let typing_result = case reply.typing {
    True -> discord_rest.trigger_typing_indicator(rest_client, target_channel)
    False -> Ok(Nil)
  }

  case typing_result {
    Error(error) -> Error(map_discord_send_error(error))
    Ok(_) ->
      case
        discord_rest.send_message_with_options(
          rest_client,
          target_channel,
          options,
        )
      {
        Ok(message) -> Ok(message)
        Error(error) -> Error(map_discord_send_error(error))
      }
  }
}

/// Alert DMs carry `open-dm:<user_id>`; ordinary replies carry a channel id.
fn discord_delivery_channel(
  rest_client: discord_rest.RestClient,
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  case string.starts_with(reply.channel_id, "open-dm:") {
    True ->
      discord_rest.open_dm(rest_client, string.drop_start(reply.channel_id, 8))
      |> result.map_error(map_discord_send_error)
    False -> Ok(discord_target_channel(reply))
  }
}

fn discord_edit_message(
  rest_client: discord_rest.RestClient,
  reply: port.ChannelReply,
  message_id: String,
) -> Result(discord_rest.SentMessage, port.ChannelError) {
  let options = discord_options_for_reply(reply)
  let target_channel = discord_target_channel(reply)

  case
    discord_rest.edit_message_with_options(
      rest_client,
      target_channel,
      message_id,
      options,
    )
  {
    Ok(message) -> Ok(message)
    Error(error) -> Error(map_discord_send_error(error))
  }
}

fn discord_options_for_reply(
  reply: port.ChannelReply,
) -> discord_rest.SendMessageOptions {
  let options = case reply.reply_to_id {
    Some(message_id) ->
      discord_rest.new_message_options()
      |> discord_rest.with_content(reply.content)
      |> discord_rest.with_message_reference(discord_rest.reply_to(message_id))
    None ->
      discord_rest.new_message_options()
      |> discord_rest.with_content(reply.content)
  }

  case reply.interactive {
    Some(interactive) -> {
      let components = discord_components(interactive)
      case components {
        [] -> options
        _ -> discord_rest.with_components(options, components)
      }
    }
    None -> options
  }
}

fn discord_target_channel(reply: port.ChannelReply) -> String {
  case reply.thread_id {
    Some(thread_id) -> thread_id
    None -> discord_route_channel(reply.channel_id)
  }
}

/// Strip policy-only routing annotations before calling Discord.
fn discord_route_channel(channel_id: String) -> String {
  case string.starts_with(channel_id, "dm:") {
    True -> string.drop_start(channel_id, 3)
    False ->
      case string.split(channel_id, "@guild:") {
        [target, _guild] -> target
        _ -> channel_id
      }
  }
}

fn discord_trigger_typing(
  rest_client: discord_rest.RestClient,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  let target_channel = discord_target_channel(reply)

  case discord_rest.trigger_typing_indicator(rest_client, target_channel) {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(map_discord_send_error(error))
  }
}

fn telegram_trigger_typing(
  telegram_config: telegram.Config,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case
    telegram.send_chat_action(
      telegram_config,
      reply.channel_id,
      telegram.TypingAction,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(map_telegram_send_error(error))
  }
}

fn telegram_send_message(
  telegram_config: telegram.Config,
  reply: port.ChannelReply,
) -> Result(telegram.SentMessage, port.ChannelError) {
  case telegram_send_options(reply) {
    Error(error) -> Error(error)
    Ok(send_options) -> {
      let typing_result = case reply.typing {
        True -> telegram_trigger_typing(telegram_config, reply)
        False -> Ok(Nil)
      }

      case typing_result {
        Error(error) -> Error(error)
        Ok(_) ->
          case parse_optional_telegram_message_id(reply.edit_message_id) {
            Error(error) -> Error(error)
            Ok(edit_message_id) ->
              case
                telegram.send_or_edit_message(
                  telegram_config,
                  reply.channel_id,
                  reply.content,
                  edit_message_id,
                  send_options,
                )
              {
                Ok(message) -> Ok(message)
                Error(error) -> Error(map_telegram_send_error(error))
              }
          }
      }
    }
  }
}

fn telegram_send_options(
  reply: port.ChannelReply,
) -> Result(telegram.SendMessageOptions, port.ChannelError) {
  let options = telegram.new_send_options()

  let options = case reply.interactive {
    Some(interactive) ->
      telegram.with_reply_markup(options, telegram_reply_markup(interactive))
    None -> options
  }

  let options_result = case reply.reply_to_id {
    Some(reply_to_id) ->
      case int.parse(reply_to_id) {
        Ok(message_id) -> Ok(telegram.with_reply_to(options, message_id))
        Error(_) ->
          Error(port.SendFailed("invalid telegram reply_to_id: " <> reply_to_id))
      }
    None -> Ok(options)
  }

  case options_result, reply.thread_id {
    Ok(current_options), Some(thread_id) ->
      case int.parse(thread_id) {
        Ok(message_thread_id) ->
          Ok(telegram.with_message_thread_id(current_options, message_thread_id))
        Error(_) ->
          Error(port.SendFailed("invalid telegram thread_id: " <> thread_id))
      }
    Ok(current_options), None -> Ok(current_options)
    Error(error), _ -> Error(error)
  }
}

fn stream_discord_reply(
  rest_client: discord_rest.RestClient,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let placeholder =
    port.ChannelReply(..base_reply, content: "Thinking...", typing: True)

  use placeholder_message <- result.try(discord_send_message(
    rest_client,
    placeholder,
  ))

  consume_discord_stream_events(
    rest_client,
    base_reply,
    events,
    placeholder_message.id,
    "",
    stream_timeout_ms,
    keepalive_ms,
  )
}

fn consume_discord_stream_events(
  rest_client: discord_rest.RestClient,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  message_id: String,
  last_content: String,
  remaining_ms: Int,
  keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let wait_ms = stream_wait_ms(remaining_ms, keepalive_ms)

  case process.receive(events, within: wait_ms) {
    Ok(port.StreamUpdate(reply)) ->
      case stream_update_fits("discord", reply.content) {
        True -> {
          let next_reply =
            port.ChannelReply(..reply, edit_message_id: Some(message_id))
          use _ <- result.try(discord_edit_message(
            rest_client,
            next_reply,
            message_id,
          ))
          consume_discord_stream_events(
            rest_client,
            base_reply,
            events,
            message_id,
            reply.content,
            remaining_ms,
            keepalive_ms,
          )
        }
        False ->
          consume_discord_stream_events(
            rest_client,
            base_reply,
            events,
            message_id,
            last_content,
            remaining_ms,
            keepalive_ms,
          )
      }
    Ok(port.StreamComplete(reply)) ->
      case reply.content == last_content {
        True -> Ok(Nil)
        False ->
          finish_stream_in_parts(
            reply,
            message_id,
            chunking.discord_max_length,
            fn(part) {
              case part.edit_message_id {
                Some(id) ->
                  discord_edit_message(rest_client, part, id)
                  |> result.map(fn(_) { Nil })
                None ->
                  discord_send_message(rest_client, part)
                  |> result.map(fn(_) { Nil })
              }
            },
          )
      }
    Ok(port.StreamFailure(error)) -> Error(error)
    Error(_) ->
      case remaining_ms <= wait_ms {
        True -> {
          let timeout_reply =
            port.ChannelReply(
              ..base_reply,
              content: "Streaming timed out",
              edit_message_id: Some(message_id),
              typing: False,
            )
          let _ = discord_edit_message(rest_client, timeout_reply, message_id)
          Error(port.SendFailed("stream timed out"))
        }
        False -> {
          use _ <- result.try(discord_trigger_typing(rest_client, base_reply))
          consume_discord_stream_events(
            rest_client,
            base_reply,
            events,
            message_id,
            last_content,
            remaining_ms - wait_ms,
            keepalive_ms,
          )
        }
      }
  }
}

/// Deliver the final stream content within the channel's length limit: the
/// first part edits the placeholder, the remaining parts go out as new
/// messages. Editing a message past the limit is rejected by the channel.
fn finish_stream_in_parts(
  reply: port.ChannelReply,
  placeholder_id: String,
  max_length: Int,
  deliver: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
) -> Result(Nil, port.ChannelError) {
  case chunking.split_reply(reply, max_length) {
    [] -> Ok(Nil)
    [first, ..rest] -> {
      let first_result =
        deliver(
          port.ChannelReply(..first, edit_message_id: Some(placeholder_id)),
        )
      case first_result {
        Ok(_) -> send_remaining_parts(rest, deliver, reply)
        Error(error) ->
          case is_message_not_modified(error) {
            True -> send_remaining_parts(rest, deliver, reply)
            False -> Error(error)
          }
      }
    }
  }
}

fn send_remaining_parts(
  parts: List(port.ChannelReply),
  deliver: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  base_reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  case parts {
    [] -> Ok(Nil)
    [part, ..rest] ->
      case deliver(part) {
        Ok(_) -> send_remaining_parts(rest, deliver, base_reply)
        Error(port.RateLimited(retry_after_seconds)) ->
          deliver_rate_limited_part(
            part,
            rest,
            deliver,
            base_reply,
            retry_after_seconds,
            1,
            0,
          )
        Error(error) -> Error(error)
      }
  }
}

fn deliver_rate_limited_part(
  part: port.ChannelReply,
  rest: List(port.ChannelReply),
  deliver: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  base_reply: port.ChannelReply,
  retry_after_seconds: Int,
  attempts: Int,
  waited_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let wait_ms =
    int.min(int.min(retry_after_seconds * 1000, 10_000 - waited_ms), 10_000)
  case wait_ms > 0 {
    True -> process.sleep(wait_ms)
    False -> Nil
  }
  let waited_ms = waited_ms + int.max(wait_ms, 0)
  case deliver(part) {
    Ok(_) -> send_remaining_parts(rest, deliver, base_reply)
    Error(port.RateLimited(next_retry)) ->
      case attempts < 3 {
        True ->
          deliver_rate_limited_part(
            part,
            rest,
            deliver,
            base_reply,
            next_retry,
            attempts + 1,
            waited_ms,
          )
        False -> send_stream_fallback(base_reply, deliver)
      }
    Error(error) -> Error(error)
  }
}

fn send_stream_fallback(
  base_reply: port.ChannelReply,
  deliver: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
) -> Result(Nil, port.ChannelError) {
  deliver(
    port.ChannelReply(
      ..base_reply,
      content: "(Não consegui enviar o restante da resposta.)",
      edit_message_id: None,
      typing: False,
    ),
  )
}

fn is_message_not_modified(error: port.ChannelError) -> Bool {
  case error {
    port.SendFailed(reason) ->
      string.contains(string.lowercase(reason), "message is not modified")
    _ -> False
  }
}

fn stream_update_fits(channel: String, content: String) -> Bool {
  string.length(content) <= stream_max_length(channel)
}

/// Test seam for split-delivery edge cases.
pub fn finish_stream_in_parts_for_test(
  reply: port.ChannelReply,
  placeholder_id: String,
  max_length: Int,
  deliver: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
) -> Result(Nil, port.ChannelError) {
  finish_stream_in_parts(reply, placeholder_id, max_length, deliver)
}

fn stream_max_length(channel: String) -> Int {
  case channel {
    "telegram" -> chunking.telegram_max_length
    "discord" -> chunking.discord_max_length
    // Channels without a documented edit limit keep the whole content.
    _ -> 1_000_000
  }
}

fn stream_telegram_reply(
  telegram_config: telegram.Config,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let placeholder =
    port.ChannelReply(..base_reply, content: "Thinking...", typing: True)

  use placeholder_message <- result.try(telegram_send_message(
    telegram_config,
    placeholder,
  ))

  consume_telegram_stream_events(
    telegram_config,
    base_reply,
    events,
    placeholder_message.message_id,
    "",
    stream_timeout_ms,
    keepalive_ms,
  )
}

fn consume_telegram_stream_events(
  telegram_config: telegram.Config,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  message_id: Int,
  last_content: String,
  remaining_ms: Int,
  keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let wait_ms = stream_wait_ms(remaining_ms, keepalive_ms)

  case process.receive(events, within: wait_ms) {
    Ok(port.StreamUpdate(reply)) ->
      case stream_update_fits("telegram", reply.content) {
        True -> {
          let next_reply =
            port.ChannelReply(
              ..reply,
              edit_message_id: Some(int.to_string(message_id)),
            )
          use _ <- result.try(telegram_send_message(telegram_config, next_reply))
          consume_telegram_stream_events(
            telegram_config,
            base_reply,
            events,
            message_id,
            reply.content,
            remaining_ms,
            keepalive_ms,
          )
        }
        False ->
          consume_telegram_stream_events(
            telegram_config,
            base_reply,
            events,
            message_id,
            last_content,
            remaining_ms,
            keepalive_ms,
          )
      }
    Ok(port.StreamComplete(reply)) ->
      case reply.content == last_content {
        True -> Ok(Nil)
        False ->
          finish_stream_in_parts(
            reply,
            int.to_string(message_id),
            chunking.telegram_max_length,
            fn(part) {
              telegram_send_message(telegram_config, part)
              |> result.map(fn(_) { Nil })
            },
          )
      }
    Ok(port.StreamFailure(error)) -> Error(error)
    Error(_) ->
      case remaining_ms <= wait_ms {
        True -> {
          let timeout_reply =
            port.ChannelReply(
              ..base_reply,
              content: "Streaming timed out",
              edit_message_id: Some(int.to_string(message_id)),
              typing: False,
            )
          let _ = telegram_send_message(telegram_config, timeout_reply)
          Error(port.SendFailed("stream timed out"))
        }
        False -> {
          use _ <- result.try(telegram_trigger_typing(
            telegram_config,
            base_reply,
          ))
          consume_telegram_stream_events(
            telegram_config,
            base_reply,
            events,
            message_id,
            last_content,
            remaining_ms - wait_ms,
            keepalive_ms,
          )
        }
      }
  }
}

fn stream_slack_reply(
  bot_token: String,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
) -> Result(Nil, port.ChannelError) {
  use session <- result.try(slack_adapter.start_progress(bot_token, base_reply))
  consume_slack_stream_events(bot_token, session, events, "", stream_timeout_ms)
}

fn consume_slack_stream_events(
  bot_token: String,
  session: slack_adapter.ProgressSession,
  events: process.Subject(port.ChannelStreamEvent),
  last_content: String,
  remaining_ms: Int,
) -> Result(Nil, port.ChannelError) {
  case process.receive(events, within: remaining_ms) {
    Ok(port.StreamUpdate(reply)) -> {
      let next_content =
        slack_progress_content_delta(session, reply.content, last_content)
      use _ <- result.try(slack_adapter.append_progress(
        bot_token,
        session,
        next_content,
      ))
      consume_slack_stream_events(
        bot_token,
        session,
        events,
        reply.content,
        remaining_ms,
      )
    }
    Ok(port.StreamComplete(reply)) -> {
      let final_content =
        slack_progress_content_delta(session, reply.content, last_content)
      slack_adapter.finish_progress(bot_token, session, final_content)
    }
    Ok(port.StreamFailure(error)) -> {
      let _ =
        slack_adapter.finish_progress(
          bot_token,
          session,
          slack_stream_failure_text(error),
        )
      Error(error)
    }
    Error(_) -> {
      let _ =
        slack_adapter.finish_progress(bot_token, session, "Streaming timed out")
      Error(port.SendFailed("stream timed out"))
    }
  }
}

fn stream_matrix_reply(
  homeserver_url: String,
  access_token: String,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  _keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let placeholder = port.ChannelReply(..base_reply, content: "Thinking...")

  use event_id <- result.try(matrix_adapter.send_reply_with_event_id(
    homeserver_url,
    access_token,
    placeholder,
  ))

  consume_matrix_stream_events(
    homeserver_url,
    access_token,
    events,
    event_id,
    "",
    stream_timeout_ms,
  )
}

fn consume_matrix_stream_events(
  homeserver_url: String,
  access_token: String,
  events: process.Subject(port.ChannelStreamEvent),
  event_id: String,
  last_content: String,
  remaining_ms: Int,
) -> Result(Nil, port.ChannelError) {
  case process.receive(events, within: remaining_ms) {
    Ok(port.StreamUpdate(reply)) -> {
      let _ = case stream_update_fits("matrix", reply.content) {
        True -> {
          let edit_reply =
            port.ChannelReply(..reply, edit_message_id: Some(event_id))
          matrix_adapter.send_reply(homeserver_url, access_token, edit_reply)
        }
        False -> Ok(Nil)
      }
      consume_matrix_stream_events(
        homeserver_url,
        access_token,
        events,
        event_id,
        reply.content,
        remaining_ms,
      )
    }
    Ok(port.StreamComplete(reply)) ->
      case reply.content == last_content {
        True -> Ok(Nil)
        False -> {
          let final_reply =
            port.ChannelReply(..reply, edit_message_id: Some(event_id))
          matrix_adapter.send_reply(homeserver_url, access_token, final_reply)
        }
      }
    Ok(port.StreamFailure(error)) -> Error(error)
    Error(_) -> Error(port.SendFailed("stream timed out"))
  }
}

fn record_stream_for_test(
  recorder: process.Subject(OutboundRecord),
  channel: String,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  keepalive_ms: Int,
  timeout_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let message_id = case channel {
    "discord" -> "discord-stream-1"
    "telegram" -> "telegram-stream-1"
    _ -> channel <> "-stream-1"
  }

  case channel_supports_typing(channel) && base_reply.typing {
    True ->
      process.send(
        recorder,
        OutboundRecord(
          channel: channel,
          action: "typing",
          content: "",
          message_id: None,
        ),
      )
    False -> Nil
  }

  process.send(
    recorder,
    OutboundRecord(
      channel: channel,
      action: "send",
      content: "Thinking...",
      message_id: Some(message_id),
    ),
  )

  consume_recorded_stream_events(
    recorder,
    channel,
    events,
    message_id,
    "",
    base_reply.typing,
    timeout_ms,
    keepalive_ms,
  )
}

fn record_slack_stream_for_test(
  recorder: process.Subject(OutboundRecord),
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
) -> Result(Nil, port.ChannelError) {
  case slack_adapter.progress_mode(base_reply) {
    slack_adapter.NativeStream -> {
      let message_id = "slack-stream-1"
      process.send(
        recorder,
        OutboundRecord(
          channel: "slack",
          action: "progress_start",
          content: "Thinking...",
          message_id: Some(message_id),
        ),
      )

      consume_recorded_slack_native_stream_events(
        recorder,
        events,
        message_id,
        "",
        stream_timeout_ms,
      )
    }
    slack_adapter.MessageUpdateFallback ->
      record_stream_for_test(
        recorder,
        "slack",
        base_reply,
        events,
        stream_timeout_ms,
        stream_timeout_ms,
      )
  }
}

fn send_chunked_replies(
  replies: List(port.ChannelReply),
  send_one: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
) -> Result(Nil, port.ChannelError) {
  case replies {
    [] -> Ok(Nil)
    [reply, ..rest] -> {
      use _ <- result.try(send_one(reply))
      send_chunked_replies(rest, send_one)
    }
  }
}

fn record_reply_for_test(
  recorder: process.Subject(OutboundRecord),
  channel: String,
  replies: List(port.ChannelReply),
) -> Result(Nil, port.ChannelError) {
  record_reply_for_test_loop(recorder, channel, replies, 1)
}

fn record_reply_for_test_loop(
  recorder: process.Subject(OutboundRecord),
  channel: String,
  replies: List(port.ChannelReply),
  index: Int,
) -> Result(Nil, port.ChannelError) {
  case replies {
    [] -> Ok(Nil)
    [reply, ..rest] -> {
      let #(action, message_id) = case reply.edit_message_id {
        Some(existing_id) -> #("edit", Some(existing_id))
        None -> #("send", Some(channel <> "-send-" <> int.to_string(index)))
      }

      process.send(
        recorder,
        OutboundRecord(
          channel: channel,
          action: action,
          content: reply.content,
          message_id: message_id,
        ),
      )
      record_reply_for_test_loop(recorder, channel, rest, index + 1)
    }
  }
}

fn consume_recorded_stream_events(
  recorder: process.Subject(OutboundRecord),
  channel: String,
  events: process.Subject(port.ChannelStreamEvent),
  message_id: String,
  last_content: String,
  typing: Bool,
  remaining_ms: Int,
  keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let wait_ms = stream_wait_ms(remaining_ms, keepalive_ms)

  case process.receive(events, within: wait_ms) {
    Ok(port.StreamUpdate(reply)) ->
      case stream_update_fits(channel, reply.content) {
        True -> {
          process.send(
            recorder,
            OutboundRecord(
              channel: channel,
              action: "edit",
              content: reply.content,
              message_id: Some(message_id),
            ),
          )
          consume_recorded_stream_events(
            recorder,
            channel,
            events,
            message_id,
            reply.content,
            typing,
            remaining_ms,
            keepalive_ms,
          )
        }
        False ->
          consume_recorded_stream_events(
            recorder,
            channel,
            events,
            message_id,
            last_content,
            typing,
            remaining_ms,
            keepalive_ms,
          )
      }
    Ok(port.StreamComplete(reply)) -> {
      case reply.content == last_content {
        True -> Ok(Nil)
        False ->
          finish_stream_in_parts(
            reply,
            message_id,
            stream_max_length(channel),
            fn(part) {
              let #(action, id) = case part.edit_message_id {
                Some(id) -> #("edit", Some(id))
                None -> #("send", None)
              }
              process.send(
                recorder,
                OutboundRecord(
                  channel: channel,
                  action: action,
                  content: part.content,
                  message_id: id,
                ),
              )
              Ok(Nil)
            },
          )
      }
    }
    Ok(port.StreamFailure(error)) -> Error(error)
    Error(_) ->
      case remaining_ms <= wait_ms {
        True -> {
          process.send(
            recorder,
            OutboundRecord(
              channel: channel,
              action: "edit",
              content: "Streaming timed out",
              message_id: Some(message_id),
            ),
          )
          Error(port.SendFailed("stream timed out"))
        }
        False -> {
          case channel_supports_typing(channel) && typing {
            True ->
              process.send(
                recorder,
                OutboundRecord(
                  channel: channel,
                  action: "typing",
                  content: "",
                  message_id: None,
                ),
              )
            False -> Nil
          }

          consume_recorded_stream_events(
            recorder,
            channel,
            events,
            message_id,
            last_content,
            typing,
            remaining_ms - wait_ms,
            keepalive_ms,
          )
        }
      }
  }
}

fn consume_recorded_slack_native_stream_events(
  recorder: process.Subject(OutboundRecord),
  events: process.Subject(port.ChannelStreamEvent),
  message_id: String,
  last_content: String,
  remaining_ms: Int,
) -> Result(Nil, port.ChannelError) {
  case process.receive(events, within: remaining_ms) {
    Ok(port.StreamUpdate(reply)) -> {
      process.send(
        recorder,
        OutboundRecord(
          channel: "slack",
          action: "progress_append",
          content: slack_progress_content_delta(
            slack_adapter.NativeProgressSession(channel_id: "", stream_ts: ""),
            reply.content,
            last_content,
          ),
          message_id: Some(message_id),
        ),
      )
      consume_recorded_slack_native_stream_events(
        recorder,
        events,
        message_id,
        reply.content,
        remaining_ms,
      )
    }
    Ok(port.StreamComplete(reply)) -> {
      process.send(
        recorder,
        OutboundRecord(
          channel: "slack",
          action: "progress_stop",
          content: reply.content,
          message_id: Some(message_id),
        ),
      )
      Ok(Nil)
    }
    Ok(port.StreamFailure(error)) -> Error(error)
    Error(_) -> Error(port.SendFailed("stream timed out"))
  }
}

fn slack_progress_content_delta(
  session: slack_adapter.ProgressSession,
  content: String,
  previous_content: String,
) -> String {
  case session {
    slack_adapter.NativeProgressSession(_, _) ->
      case string.starts_with(content, previous_content) {
        True -> string.drop_start(content, string.length(previous_content))
        False -> content
      }
    slack_adapter.MessageUpdateSession(_, _) -> content
  }
}

fn slack_stream_failure_text(error: port.ChannelError) -> String {
  case error {
    port.SendFailed(reason) -> "Streaming failed: " <> reason
    port.NotConnected -> "Streaming failed: not connected"
    port.RateLimited(_) -> "Streaming failed: rate limited"
    port.Ignored(reason) -> "Streaming failed: " <> reason
    port.UnsupportedInteraction(reason) -> "Streaming failed: " <> reason
  }
}

fn normalize_typing_keepalive_ms(interval_ms: Int) -> Int {
  case interval_ms < 1 {
    True -> default_typing_keepalive_ms
    False -> interval_ms
  }
}

fn stream_wait_ms(remaining_ms: Int, keepalive_ms: Int) -> Int {
  case remaining_ms < keepalive_ms {
    True -> remaining_ms
    False -> keepalive_ms
  }
}

fn channel_supports_typing(channel: String) -> Bool {
  channel == "discord" || channel == "telegram"
}

fn discord_components(
  interactive: port.ChannelInteractiveReply,
) -> List(discord_rest.MessageComponentRow) {
  list.fold(interactive.blocks, [], fn(rows, block) {
    case block {
      port.InteractionText(_) -> rows
      port.InteractionButtons(buttons) -> [
        discord_rest.action_row(list.map(buttons, discord_button_component)),
        ..rows
      ]
      port.InteractionSelect(action_id, placeholder, options) -> {
        let select =
          discord_rest.string_select(
            action_id,
            list.map(options, discord_select_option),
          )

        let select = case placeholder {
          Some(text) -> discord_rest.select_with_placeholder(select, text)
          None -> select
        }

        [discord_rest.action_row([select]), ..rows]
      }
    }
  })
  |> list.reverse
}

fn discord_button_component(
  button: port.ChannelButton,
) -> discord_rest.MessageComponent {
  let action_id = port.button_action_id(button)
  let label = port.button_label(button)

  case port.button_style(button) {
    port.ButtonPrimary -> discord_rest.primary_button(action_id, label)
    port.ButtonSecondary -> discord_rest.secondary_button(action_id, label)
    port.ButtonSuccess -> discord_rest.success_button(action_id, label)
    port.ButtonDanger -> discord_rest.danger_button(action_id, label)
  }
}

fn discord_select_option(
  option: port.ChannelSelectOption,
) -> discord_rest.MessageSelectOption {
  discord_rest.select_option(
    port.select_option_label(option),
    port.select_option_value(option),
  )
}

fn telegram_reply_markup(
  interactive: port.ChannelInteractiveReply,
) -> telegram.ReplyMarkup {
  interactive.blocks
  |> list.fold([], fn(rows, block) {
    case block {
      port.InteractionText(_) -> rows
      port.InteractionButtons(buttons) -> [
        list.map(buttons, telegram_button),
        ..rows
      ]
      port.InteractionSelect(action_id, _, options) -> [
        list.map(options, fn(option) {
          telegram.inline_keyboard_button(
            port.select_option_label(option),
            action_id <> ":" <> port.select_option_value(option),
          )
        }),
        ..rows
      ]
    }
  })
  |> list.reverse
  |> telegram.inline_keyboard
}

fn telegram_button(
  button: port.ChannelButton,
) -> telegram.InlineKeyboardButton {
  telegram.inline_keyboard_button(
    port.button_label(button),
    port.button_action_id(button),
  )
}

fn parse_optional_telegram_message_id(
  message_id: Option(String),
) -> Result(Option(Int), port.ChannelError) {
  case message_id {
    None -> Ok(None)
    Some(value) ->
      case int.parse(value) {
        Ok(parsed) -> Ok(Some(parsed))
        Error(_) ->
          Error(port.SendFailed("invalid telegram edit_message_id: " <> value))
      }
  }
}

fn map_discord_send_error(
  error: discord_rest.DiscordRestError,
) -> port.ChannelError {
  case error {
    discord_rest.RateLimited(retry_after_ms) ->
      port.RateLimited(retry_after_seconds: retry_after_ms / 1000)
    discord_rest.BadRequest(message) -> port.SendFailed(message)
    discord_rest.Forbidden(message) -> port.SendFailed(message)
    discord_rest.NotFound(message) -> port.SendFailed(message)
    discord_rest.InternalError(message) -> port.SendFailed(message)
    discord_rest.UnknownError(_, body) -> port.SendFailed(body)
    discord_rest.HttpError(message) -> port.SendFailed(message)
    discord_rest.JsonError(message) -> port.SendFailed(message)
    discord_rest.Unauthorized -> port.NotConnected
  }
}

fn map_telegram_send_error(error: telegram.TelegramError) -> port.ChannelError {
  case error {
    telegram.RateLimitError(retry_after) ->
      port.RateLimited(retry_after_seconds: retry_after)
    telegram.InvalidTokenError -> port.NotConnected
    _ -> port.SendFailed(telegram_error_to_string(error))
  }
}

fn telegram_error_to_string(error: telegram.TelegramError) -> String {
  case error {
    telegram.HttpError(message) -> message
    telegram.JsonDecodeError(message) -> message
    telegram.ApiError(code, description) ->
      "api error " <> int.to_string(code) <> ": " <> description
    telegram.RateLimitError(retry_after) ->
      "rate limited for " <> int.to_string(retry_after) <> " seconds"
    telegram.InvalidTokenError -> "invalid token"
    telegram.NetworkError(message) -> message
    telegram.TimeoutError -> "timeout"
    telegram.MessageTooLongError -> "message too long"
    telegram.InvalidParseModeError -> "invalid parse mode"
  }
}
