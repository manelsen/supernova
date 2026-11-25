//// Pairing codes for channels that link a device to an account (PRD-A,
//// A-12): WhatsApp through GOWA. The channel registers how to ask for a
//// code when it starts; the core asks by channel name through here, never
//// calling an adapter (ports and adapters).

import gleam/dict.{type Dict}
import gleam/result

pub type Provider =
  fn() -> Result(String, String)

const key = "supernova_channel_pairing"

@external(erlang, "supernova_global_ffi", "global_put")
fn put(key: String, providers: Dict(String, Provider)) -> Nil

@external(erlang, "supernova_tool_limits_ffi", "get")
fn get(key: String) -> Result(Dict(String, Provider), Nil)

fn providers() -> Dict(String, Provider) {
  get(key) |> result.unwrap(dict.new())
}

pub fn register(channel: String, provider: Provider) -> Nil {
  put(key, dict.insert(providers(), channel, provider))
}

pub fn unregister(channel: String) -> Nil {
  put(key, dict.delete(providers(), channel))
}

/// A new pairing code for the channel's account.
pub fn request(channel: String) -> Result(String, String) {
  case dict.get(providers(), channel) {
    Ok(provider) -> provider()
    Error(Nil) -> Error("this channel has no pairing")
  }
}

/// How to use a WhatsApp pairing code, for the alert and `/parear`.
pub fn whatsapp_instructions(code: String) -> String {
  "Para reconectar, no celular da agente: WhatsApp → Aparelhos conectados → Conectar aparelho → Conectar com número de telefone, e digite o código "
  <> code
  <> ". Se ele vencer, mande /parear aqui para pedir outro."
}
