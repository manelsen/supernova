//// buscar_conversa finds what was said in any of the person's chats, by
//// every term, ignoring case and accents; never another person's words;
//// at most the 20 most recent, with the total; nothing after /esquecer.

import exception
import gleam/dict
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import supernova/agenda/runtime
import supernova/config
import supernova/core/agent_identity
import supernova/core/capability_manifest/types as cap_types
import supernova/core/session/history_store.{HistoryStore, StoredMessage}
import supernova/core/syscall/actor
import supernova/tools/buscar_conversa
import test_workspace

// 2026-11-26 12:00 UTC, in milliseconds.
const base = 1_795_694_400_000

const minute = 60_000

fn with_dir(body: fn(String) -> a) -> a {
  let dir = test_workspace.create_temp_dir("buscar_conversa")
  use <- exception.defer(fn() { test_workspace.remove_dir_recursive(dir) })
  body(dir)
}

fn say(dir: String, session: String, messages: List(#(String, String, Int))) {
  let store = HistoryStore(data_dir: dir, limit: 100)
  let stored =
    list.map(messages, fn(m) {
      StoredMessage(role: m.0, content: m.1, at: base + m.2 * minute)
    })
  let assert Ok(Nil) = history_store.append(store, session, stored)
  Nil
}

fn run(dir: String, principal: String, terms: String) -> String {
  let assert Ok(text) =
    buscar_conversa.execute_for(
      dir,
      principal,
      -180,
      "{\"terms\":\"" <> terms <> "\"}",
    )
  text
}

pub fn finds_in_private_and_group_by_every_term_test() {
  use dir <- with_dir
  say(dir, "telegram:42:42", [
    #("user", "A consulta da minha mãe é na Rua Aurora 210, às 15h.", 0),
    #("assistant", "Guardado: rua Aurora 210, 15h.", 1),
    #("user", "Comprei pão.", 2),
  ])
  say(dir, "telegram:-100:42", [
    #("user", "Gente, a reunião é na rua das Flores.", 5),
  ])

  let text = run(dir, "telegram:42", "aurora 210")
  text
  |> should.equal(
    "2 mensagens encontradas:\n"
    <> "[26/11/2026 09:00, privado] pessoa: A consulta da minha mãe é na Rua Aurora 210, às 15h.\n"
    <> "[26/11/2026 09:01, privado] você: Guardado: rua Aurora 210, 15h.",
  )

  // Case and accents are ignored, in the terms and in the text.
  run(dir, "telegram:42", "MAE consulta")
  |> string.contains("A consulta da minha mãe")
  |> should.be_true()
  run(dir, "telegram:42", "reuniao")
  |> string.contains("[26/11/2026 09:05, grupo] pessoa: Gente, a reunião")
  |> should.be_true()
  // Every term must be in the same message.
  run(dir, "telegram:42", "aurora flores")
  |> should.equal(
    "Nada encontrado para \"aurora flores\" nas conversas guardadas.",
  )
}

/// Another person's conversations are never searched.
pub fn only_the_callers_conversations_test() {
  use dir <- with_dir
  say(dir, "telegram:42:42", [#("user", "meu segredo é abacaxi", 0)])
  say(dir, "telegram:43:43", [#("user", "o segredo da Bia é melancia", 0)])
  say(dir, "telegram:-100:43", [#("user", "segredo no grupo, da Bia", 1)])
  let text = run(dir, "telegram:42", "segredo")
  text |> string.contains("abacaxi") |> should.be_true()
  text |> string.contains("melancia") |> should.be_false()
  text |> string.contains("grupo") |> should.be_false()
  run(dir, "telegram:44", "segredo")
  |> should.equal("Nada encontrado para \"segredo\" nas conversas guardadas.")
}

pub fn shows_the_most_recent_twenty_with_the_total_test() {
  use dir <- with_dir
  say(
    dir,
    "telegram:42:42",
    list.repeat(Nil, 25)
      |> list.index_map(fn(_, i) {
        #("user", "nota número " <> string.inspect(i + 1), i)
      }),
  )
  let lines = run(dir, "telegram:42", "nota") |> string.split("\n")
  let assert [header, first, ..] = lines
  header
  |> should.equal(
    "25 mensagens encontradas; as 20 mais recentes, da mais antiga para a mais nova. Use termos mais específicos para as outras.",
  )
  first |> string.ends_with("pessoa: nota número 6") |> should.be_true()
  list.length(lines) |> should.equal(21)
}

pub fn long_messages_are_cut_test() {
  use dir <- with_dir
  say(dir, "telegram:42:42", [
    #("user", "palavra " <> string.repeat("x", 1000), 0),
  ])
  let assert [_, line] =
    run(dir, "telegram:42", "palavra") |> string.split("\n")
  line |> string.ends_with("…") |> should.be_true()
  { string.length(line) < 700 } |> should.be_true()
}

pub fn needs_terms_test() {
  use dir <- with_dir
  buscar_conversa.execute_for(dir, "telegram:42", 0, "{\"terms\":\"  \"}")
  |> should.equal(Error("buscar_conversa needs at least one term"))
  buscar_conversa.execute_for(dir, "telegram:42", 0, "{}")
  |> should.equal(Error(
    "Invalid arguments for buscar_conversa: terms is required",
  ))
}

fn member_gateway() -> actor.SyscallGateway {
  let manifests =
    dict.from_list([
      #(
        "member",
        cap_types.CapabilityManifest(
          allowed_tools: ["buscar_conversa"],
          denied_tools: [],
        ),
      ),
    ])
  let assert Ok(gateway) =
    actor.start_with_capabilities(
      option.None,
      option.None,
      option.None,
      manifests,
      fn(_, _) { Error("the raw executor must not run buscar_conversa") },
    )
  gateway
}

/// Through the gateway, a call searches the caller's own conversations.
pub fn the_gateway_searches_for_the_caller_test() {
  use dir <- with_dir
  runtime.configure(
    runtime.Context(data_dir: dir, offset_minutes: -180, clock: fn() { base }),
  )
  use <- exception.defer(runtime.clear)
  say(dir, "telegram:111:111", [#("user", "o código é ABACAXI-7781", 0)])
  let gateway = member_gateway()
  let args = "{\"terms\":\"abacaxi\"}"
  let search = fn(principal) {
    let assert Ok(reservation) =
      actor.authorize_tool_call(
        gateway,
        principal,
        "member",
        "buscar_conversa",
        args,
      )
    let assert Ok(execute) = actor.claim_tool_call(gateway, reservation)
    execute("buscar_conversa", args)
  }
  let assert Ok(found) = search("telegram:111")
  found |> string.contains("ABACAXI-7781") |> should.be_true()
  search("telegram:222")
  |> should.equal(Ok(
    "Nada encontrado para \"abacaxi\" nas conversas guardadas.",
  ))
}

pub fn members_may_search_by_default_test() {
  config.default_capabilities_config().member.allowed
  |> list.contains("buscar_conversa")
  |> should.be_true()
}

pub fn fold_test() {
  buscar_conversa.fold("Ação ÉPICA, Ñandu") |> should.equal("acao epica, nandu")
}

@external(erlang, "erlang", "list_to_binary")
fn raw_bytes(bytes: List(Int)) -> String

/// Bytes that are not UTF-8 come back as they are, instead of crashing.
pub fn fold_leaves_invalid_utf8_alone_test() {
  let bad = raw_bytes([255, 65])
  buscar_conversa.fold(bad) |> should.equal(bad)
}

pub fn chat_label_test() {
  let label = fn(session) {
    buscar_conversa.chat_label(agent_identity.encode_principal(session))
  }
  label("telegram:42:42") |> should.equal("privado")
  label("telegram:-100:42") |> should.equal("grupo")
  label("sim:group-1:alice") |> should.equal("grupo")
  // Chat ids with colons: the user is the last part.
  label("matrix:!room:server:alice") |> should.equal("grupo")
  label("matrix:a:b:a:b") |> should.equal("grupo")
}

/// A directory that cannot be read is an error, never "not said". A plain
/// file where the directory should be fails the same way for any user.
pub fn unreadable_directory_is_an_error_test() {
  use dir <- with_dir
  let conversations = history_store.dir(dir, "telegram:42")
  let assert Ok(Nil) = ensure_dir(dir <> "/agents")
  let assert Ok(Nil) = ensure_dir(agent_identity.agent_dir(dir, "telegram:42"))
  let assert Ok(Nil) = write_file(conversations, "not a directory")
  case
    buscar_conversa.execute_for(dir, "telegram:42", 0, "{\"terms\":\"oi\"}")
  {
    Error(reason) ->
      string.starts_with(
        reason,
        "buscar_conversa could not read the conversations",
      )
      |> should.be_true()
    Ok(_) -> should.fail()
  }
}

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)
