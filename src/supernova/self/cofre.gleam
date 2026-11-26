//// The vault (PRD-K, K12, K13): the person's passwords, kept out of the
//// model. A password arrives by `/senha` (text only), is sealed here with
//// AES-256-GCM under `SUPERNOVA_COFRE_KEY`, and leaves only to fill a login
//// form in the person's computer, in the one call that does it (`entrar`).
//// Never in a prompt, a history, a transcript or a log (K-I3).
////
//// `<self>/cofre.json`: per site, the user name (shown to the person, so
//// they know which account) and the sealed password.

import envoy
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import supernova/core/agent_identity

pub type Entry {
  Entry(site: String, usuario: String, selada: String)
}

/// The key, when the vault is configured. No key: no vault (fail closed).
pub fn key() -> Result(String, Nil) {
  case envoy.get("SUPERNOVA_COFRE_KEY") |> result.map(string.trim) {
    Ok("") | Error(Nil) -> Error(Nil)
    Ok(key) -> Ok(key)
  }
}

pub fn path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/cofre.json"
}

/// Keep (or replace) the password for a site.
pub fn guardar(
  data_dir: String,
  principal: String,
  key: String,
  site: String,
  usuario: String,
  senha: String,
) -> Result(Nil, String) {
  use entries <- result.try(load(data_dir, principal))
  let entry = Entry(site: site, usuario: usuario, selada: seal(key, senha))
  let kept = list.filter(entries, fn(e) { e.site != site })
  save(data_dir, principal, [entry, ..kept])
}

/// The sites with a password, and their user names; never the passwords.
pub fn sites(
  data_dir: String,
  principal: String,
) -> Result(List(#(String, String)), String) {
  use entries <- result.map(load(data_dir, principal))
  entries
  |> list.map(fn(e) { #(e.site, e.usuario) })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

/// The user name and password for a site, for the one call that fills them.
pub fn credencial(
  data_dir: String,
  principal: String,
  key: String,
  site: String,
) -> Result(#(String, String), String) {
  use entries <- result.try(load(data_dir, principal))
  use entry <- result.try(
    list.find(entries, fn(e) { e.site == site })
    |> result.replace_error("no password for " <> site),
  )
  open(key, entry.selada)
  |> result.map(fn(senha) { #(entry.usuario, senha) })
  |> result.replace_error("the vault cannot open the password for " <> site)
}

pub fn apagar(
  data_dir: String,
  principal: String,
  site: String,
) -> Result(Bool, String) {
  use entries <- result.try(load(data_dir, principal))
  let kept = list.filter(entries, fn(e) { e.site != site })
  case list.length(kept) == list.length(entries) {
    True -> Ok(False)
    False -> save(data_dir, principal, kept) |> result.replace(True)
  }
}

fn load(data_dir: String, principal: String) -> Result(List(Entry), String) {
  let target = path(data_dir, principal)
  case file_exists(target) {
    Ok(False) -> Ok([])
    Error(reason) -> Error(reason)
    Ok(True) -> {
      use text <- result.try(read_file(target))
      let entry = {
        use site <- decode.field("site", decode.string)
        use usuario <- decode.field("usuario", decode.string)
        use selada <- decode.field("selada", decode.string)
        decode.success(Entry(site:, usuario:, selada:))
      }
      json.parse(text, decode.list(entry))
      |> result.replace_error("the vault file is damaged")
    }
  }
}

fn save(
  data_dir: String,
  principal: String,
  entries: List(Entry),
) -> Result(Nil, String) {
  let target = path(data_dir, principal)
  let text =
    json.array(entries, fn(e) {
      json.object([
        #("site", json.string(e.site)),
        #("usuario", json.string(e.usuario)),
        #("selada", json.string(e.selada)),
      ])
    })
    |> json.to_string
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  use _ <- result.try(write_file(target <> ".tmp", text))
  rename(target <> ".tmp", target)
}

@external(erlang, "supernova_cofre_ffi", "seal")
fn seal(key: String, plain: String) -> String

@external(erlang, "supernova_cofre_ffi", "open")
fn open(key: String, sealed: String) -> Result(String, Nil)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_self_ffi", "rename_file")
fn rename(from: String, to: String) -> Result(Nil, String)
