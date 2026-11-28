//// The parallel path (PRD-P, P-05, `routing.parallel`, the default) has a
//// handler for every channel that routes inbound. WhatsApp had none: every
//// message reached Supernova and was dropped as "unconfigured channel".

import gleam/dict
import gleam/list
import gleam/option.{None}
import gleeunit/should
import supernova/adapters/direct_routers
import supernova/channel/catalog as channel_catalog
import supernova/core/session/supervisor
import supernova/llm/provider

pub fn every_channel_that_routes_inbound_has_a_direct_handler_test() {
  let assert Ok(sessions) = supervisor.start()
  let handlers = direct_routers.handlers(sessions, llm_config())
  channel_catalog.all()
  |> list.filter(fn(channel) { channel.routes_inbound })
  |> list.filter(fn(channel) { !dict.has_key(handlers, channel.name) })
  |> list.map(fn(channel) { channel.name })
  |> should.equal([])
  supervisor.stop(sessions)
}

pub fn whatsapp_has_a_direct_handler_test() {
  let assert Ok(sessions) = supervisor.start()
  direct_routers.handlers(sessions, llm_config())
  |> dict.has_key("whatsapp")
  |> should.be_true
  supervisor.stop(sessions)
}

fn llm_config() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}
