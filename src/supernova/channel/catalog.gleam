//// Every channel Supernova knows, with its traits.

import gleam/list
import gleam/option.{Some}
import gleam/string
import supernova/channel/traits.{type ChannelTraits, ChannelTraits}
import supernova/channel/traits/discord
import supernova/channel/traits/sim
import supernova/channel/traits/telegram
import supernova/channel/traits/whatsapp

/// Traits of all known channels.
pub fn all() -> List(ChannelTraits) {
  [
    telegram.channel(),
    discord.channel(),
    sim.channel(),
    ChannelTraits(..traits.generic("matrix"), routes_inbound: True),
    traits.generic("lark"),
    traits.generic("google_chat"),
    ChannelTraits(
      ..traits.generic("slack"),
      routes_inbound: True,
      supports_interactions: True,
    ),
    traits.generic("mattermost"),
    traits.generic("wechat_work"),
    whatsapp.channel(),
  ]
}

/// Traits of the named channel; `traits.unknown` when the catalog does not
/// know it.
pub fn get(name: String) -> ChannelTraits {
  case list.find(all(), fn(channel) { channel.name == name }) {
    Ok(channel) -> channel
    Error(_) -> traits.unknown(name)
  }
}

/// Channels whose people can be closed-group principals.
pub fn principal_channels() -> List(String) {
  all()
  |> list.filter(fn(channel) { channel.has_principals })
  |> list.map(fn(channel) { channel.name })
}

/// Group key prefixes accepted in `access.allowed_chats` and `/acesso chat`.
pub fn group_key_prefixes() -> List(String) {
  list.filter_map(all(), fn(channel) {
    case channel.group_key_prefix {
      Some(prefix) -> Ok(prefix)
      _ -> Error(Nil)
    }
  })
}

/// True when the key authorizes a group on some channel.
pub fn is_group_key(key: String) -> Bool {
  list.any(group_key_prefixes(), fn(prefix) {
    string.starts_with(key, prefix)
    && string.length(key) > string.length(prefix)
  })
}
