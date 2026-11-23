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

  // The matches (») come with the message after them.
  let text = run(dir, "telegram:42", "aurora 210")
  text
  |> should.equal(
    "2 mensagens encontradas, em 1 trecho:\n\n"
    <> "» [26/11/2026 09:00] pessoa: A consulta da minha mãe é na Rua Aurora 210, às 15h.\n"
    <> "» [26/11/2026 09:01] você: Guardado: rua Aurora 210, 15h.\n"
    <> "  [26/11/2026 09:02] pessoa: Comprei pão.",
  )

  // Case and accents are ignored, in the terms and in the text.
  run(dir, "telegram:42", "MAE consulta")
  |> string.contains("A consulta da minha mãe")
  |> should.be_true()
  run(dir, "telegram:42", "reuniao")
  |> string.contains("» [26/11/2026 09:05] pessoa: Gente, a reunião")
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
  text |> string.contains("Bia") |> should.be_false()
  run(dir, "telegram:44", "segredo")
  |> should.equal("Nada encontrado para \"segredo\" nas conversas guardadas.")
}

/// The answer is often right after the word: "cardiologista" finds the
/// message, and the name comes in the next one.
pub fn a_match_comes_with_what_was_said_next_test() {
  use dir <- with_dir
  say(dir, "telegram:42:42", [
    #("user", "levei minha mãe no cardiologista", 0),
    #("assistant", "Como foi?", 1),
    #("user", "guarda o nome dele? é o dr. Otávio Lacerda", 2),
    #("assistant", "Guardado.", 3),
    #("user", "fiz bolo", 10),
    #("assistant", "Que bom.", 11),
  ])
  run(dir, "telegram:42", "cardiologista")
  |> should.equal(
    "1 mensagem encontrada, em 1 trecho:\n\n"
    <> "» [26/11/2026 09:00] pessoa: levei minha mãe no cardiologista\n"
    <> "  [26/11/2026 09:01] você: Como foi?\n"
    <> "  [26/11/2026 09:02] pessoa: guarda o nome dele? é o dr. Otávio Lacerda",
  )
}

/// Far-apart matches are separate excerpts; only the most recent ten are
/// shown, and the header says so.
pub fn shows_the_most_recent_excerpts_with_the_totals_test() {
  use dir <- with_dir
  say(
    dir,
    "telegram:42:42",
    list.repeat(Nil, 60)
      |> list.index_map(fn(_, i) {
        case i % 5 {
          0 -> #("user", "nota número " <> string.inspect(i / 5 + 1), i)
          _ -> #("assistant", "ok", i)
        }
      }),
  )
  let text = run(dir, "telegram:42", "nota")
  let assert [header, first, ..] = string.split(text, "\n\n")
  header
  |> should.equal(
    "12 mensagens encontradas, em 12 trechos; abaixo, só os mais recentes. Use termos mais específicos para ver os outros.",
  )
  first |> string.contains("nota número 3") |> should.be_true()
  string.split(text, "\n\n") |> list.length |> should.equal(11)
}

/// A run of matches merges into one excerpt, cut to its last lines.
pub fn a_long_run_of_matches_keeps_its_last_lines_test() {
  use dir <- with_dir
  say(
    dir,
    "telegram:42:42",
    list.repeat(Nil, 100)
      |> list.index_map(fn(_, i) {
        #("user", "linha " <> string.inspect(i + 1), i)
      }),
  )
  let text = run(dir, "telegram:42", "linha")
  let assert [header, body] = string.split(text, "\n\n")
  header
  |> string.starts_with("100 mensagens encontradas, em 1 trecho; abaixo")
  |> should.be_true()
  let lines = string.split(body, "\n")
  list.length(lines) |> should.equal(buscar_conversa.max_lines)
  let assert Ok(last) = list.last(lines)
  last |> string.ends_with("pessoa: linha 100") |> should.be_true()
}

pub fn long_messages_are_cut_test() {
  use dir <- with_dir
  say(dir, "telegram:42:42", [
    #("user", "palavra " <> string.repeat("x", 1000), 0),
  ])
  let assert [_, line] =
    run(dir, "telegram:42", "palavra") |> string.split("\n\n")
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

/// A conversation file that cannot be read is an error too, never "not said".
pub fn unreadable_file_is_an_error_test() {
  use dir <- with_dir
  say(dir, "telegram:42:42", [#("user", "oi", 0)])
  let conversations = history_store.dir(dir, "telegram:42")
  // A directory where a conversation file should be cannot be read as one.
  let assert Ok(Nil) =
    ensure_dir(conversations <> "/telegram%3A-100%3A42.jsonl")
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

/// The file is pre-filtered on its folded text, which holds the JSON keys
/// too: a term that only appears there ("role", "content", "user") matches
/// nothing.
pub fn json_keys_are_not_matched_test() {
  use dir <- with_dir
  say(dir, "telegram:42:42", [
    #("user", "oi", 0),
    #("assistant", "olá, tudo bem?", 1),
    #("user", "o papel dele no conteúdo", 2),
  ])
  run(dir, "telegram:42", "role")
  |> should.equal("Nada encontrado para \"role\" nas conversas guardadas.")
  run(dir, "telegram:42", "content user")
  |> should.equal(
    "Nada encontrado para \"content user\" nas conversas guardadas.",
  )
  run(dir, "telegram:42", "conteudo")
  |> string.contains("1 mensagem encontrada")
  |> should.be_true()
}
