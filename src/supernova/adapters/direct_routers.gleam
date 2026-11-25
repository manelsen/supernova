//// The per-channel handler for the parallel path (PRD-P, P-05,
//// `routing.parallel`): the router's work runs in the chat's lane instead of
//// the router's actor, so chats no longer wait for each other.
////
//// The core asks for the table and never names a channel (PRD-C, C-01). The
//// channels live here, in the adapters layer, and the catalog decides which
//// ones take part.

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import supernova/adapters/discord_router
import supernova/adapters/matrix_router
import supernova/adapters/sim_router
import supernova/adapters/slack_router
import supernova/adapters/telegram_router
import supernova/channel/catalog as channel_catalog
import supernova/channel/port
import supernova/core/session/supervisor
import supernova/llm/provider

pub type DirectHandler =
  fn(port.ChannelInbound, Subject(port.ChannelStreamEvent)) ->
    Result(port.ChannelHandlerResult, port.ChannelError)

/// One direct handler per channel whose traits say it routes inbound and that
/// has a lane-parallel implementation of its own.
pub fn handlers(
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> dict.Dict(String, DirectHandler) {
  channel_catalog.all()
  |> list.filter(fn(channel) { channel.routes_inbound })
  |> list.fold(dict.new(), fn(table, channel) {
    case handler_for(channel.name, session_supervisor, llm_config) {
      Some(handler) -> dict.insert(table, channel.name, handler)
      None -> table
    }
  })
}

fn handler_for(
  name: String,
  session_supervisor: supervisor.SessionSupervisor,
  llm_config: provider.ProviderConfig,
) -> Option(DirectHandler) {
  case name {
    "discord" ->
      Some(discord_router.direct_handler(session_supervisor, llm_config))
    "telegram" ->
      Some(telegram_router.direct_handler(session_supervisor, llm_config))
    "slack" -> Some(slack_router.direct_handler(session_supervisor, llm_config))
    "matrix" ->
      Some(matrix_router.direct_handler(session_supervisor, llm_config))
    "sim" -> Some(sim_router.direct_handler(session_supervisor, llm_config))
    _ -> None
  }
}
