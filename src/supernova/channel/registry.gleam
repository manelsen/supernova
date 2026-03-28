//// Channel Registry — manages all channel adapters and their send functions.
///
//// This module provides a centralized registry for all channel adapters,
//// allowing the core to send messages through any enabled channel without
//// knowing the implementation details.
///

import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/option.{Some, None}
import supernova/adapters/slack_adapter
import supernova/channel/port
import supernova/config

// ============================================================================
// Types
// ============================================================================

/// A registry of all channel adapters, keyed by channel name.
pub type ChannelRegistry {
  ChannelRegistry(
    channels: Dict(String, ChannelEntry),
  )
}

/// An entry in the channel registry.
pub type ChannelEntry {
  ChannelEntry(send: fn(port.ChannelReply) -> Result(Nil, port.ChannelError))
}

// ============================================================================
// Public API
// ============================================================================

/// Start all enabled channel adapters based on configuration.
/// 
/// Returns a ChannelRegistry containing send functions for each enabled channel.
pub fn start_channels(cfg: config.Config) -> Result(ChannelRegistry, String) {
  let channels = dict.new()
  
  // Discord - not fully implemented yet
  let channels = case config.is_discord_enabled(cfg) {
    True -> {
      io.println("Discord: enabled (not fully implemented yet)")
      channels
    }
    False -> channels
  }
  
  // Matrix - needs homeserver_url and token in config
  let channels = case config.is_matrix_enabled(cfg) {
    True -> {
      io.println("Matrix: enabled (needs homeserver_url in config)")
      channels
    }
    False -> channels
  }
  
  // Mattermost - needs webhook_url in config
  let channels = case config.is_mattermost_enabled(cfg) {
    True -> {
      io.println("Mattermost: enabled (needs webhook_url in config)")
      channels
    }
    False -> channels
  }
  
  // WhatsApp - needs bridge_url in config
  let channels = case config.is_whatsapp_enabled(cfg) {
    True -> {
      io.println("WhatsApp: enabled (needs bridge_url in config)")
      channels
    }
    False -> channels
  }
  
  // Telegram - not fully implemented yet
  let channels = case config.is_telegram_enabled(cfg) {
    True -> {
      io.println("Telegram: enabled (not fully implemented)")
      channels
    }
    False -> channels
  }
  
  // Slack - fully implemented
  let channels = case config.is_slack_enabled(cfg) {
    True -> {
      case cfg.slack.token {
        Some(token) -> {
          case slack_adapter.start(token, "", fn(_reply) {
            Error(port.NotConnected)
          }) {
            Ok(adapter) -> {
              io.println("Slack: adapter ready")
              dict.insert(channels, "slack", ChannelEntry(send: adapter.send))
            }
            Error(e) -> {
              io.println("Slack: failed to start - " <> e)
              channels
            }
          }
        }
        None -> {
          io.println("Slack: enabled but no token configured")
          channels
        }
      }
    }
    False -> channels
  }
  
  // Lark - not implemented
  let channels = case config.is_lark_enabled(cfg) {
    True -> {
      io.println("Lark: enabled (not implemented)")
      channels
    }
    False -> channels
  }
  
  // Google Chat - needs webhook_url in config
  let channels = case config.is_google_chat_enabled(cfg) {
    True -> {
      io.println("Google Chat: enabled (needs webhook_url in config)")
      channels
    }
    False -> channels
  }
  
  // WeChat Work - not implemented
  let channels = case config.is_wechat_work_enabled(cfg) {
    True -> {
      io.println("WeChat Work: enabled (not implemented)")
      channels
    }
    False -> channels
  }
  
  let total = dict.size(channels)
  io.println("Started " <> int.to_string(total) <> " channel adapter(s)")
  
  Ok(ChannelRegistry(channels: channels))
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
    Ok(entry) -> entry.send(reply)
    Error(_) -> Error(port.SendFailed("Channel not registered: " <> channel))
  }
}

/// Check if a channel is registered and available.
pub fn is_channel_available(registry: ChannelRegistry, channel: String) -> Bool {
  dict.has_key(registry.channels, channel)
}

/// List all registered channel names.
pub fn list_channels(registry: ChannelRegistry) -> List(String) {
  dict.keys(registry.channels)
}

/// Stop all channels in the registry.
pub fn stop_channels(_registry: ChannelRegistry) -> Nil {
  // Currently stateless - add stop logic when adapters become stateful
  io.println("Stopped all channel adapters")
  Nil
}
