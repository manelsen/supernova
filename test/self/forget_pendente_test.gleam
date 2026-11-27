//// PRD-K, K-I7 (and the review of 26/11): a part of /esquecer that fails
//// is not reported as forgotten. It is kept as pending, tried again, and
//// the receipt says what is left.

import envoy
import exception
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/adapters/mcp/computer
import supernova/channel/inbox
import supernova/channel/port
import supernova/self/aprovacoes
import supernova/self/cofre
import supernova/self/forget
import test_workspace

type Fake

@external(erlang, "mcp_computer_fake_ffi", "start")
fn start_fake(responder: fn(String) -> #(Int, String)) -> Fake

@external(erlang, "mcp_computer_fake_ffi", "requests")
fn requests(fake: Fake) -> List(String)

@external(erlang, "mcp_computer_fake_ffi", "stop")
fn stop(fake: Fake) -> Nil

@external(erlang, "erlang", "element")
fn port_of(index: Int, fake: Fake) -> Int

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_self_ffi", "clear_dir")
fn clear_dir(path: String) -> Result(Int, String)

@external(erlang, "file", "del_dir")
fn del_dir(path: String) -> a

pub fn a_computer_that_is_down_is_not_forgotten_yet_test() {
  let dir = test_workspace.create_temp_dir("forget_computador")
  // Nothing listens here: the dispatcher is down.
  envoy.set("SUPERNOVA_COMPUTER_URL", "http://127.0.0.1:9")
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_COMPUTER_URL") })

  let assert Ok(counts) = forget.forget(dir, "sim:ana", None)
  counts.pendente |> should.equal([forget.Computador])
  let receipt = forget.receipt(counts)
  string.contains(receipt, "Esqueci.") |> should.be_false
  string.contains(receipt, "o seu computador") |> should.be_true
  forget.pending(dir, "sim:ana") |> should.equal([forget.Computador])

  // Still down: still pending.
  forget.retry(dir, "sim:ana", None) |> should.equal(Ok([forget.Computador]))

  // Back up: the computer is deleted, the pending note goes.
  let fake = start_fake(fn(_) { #(200, "{\"ok\":true,\"apagado\":true}") })
  envoy.set(
    "SUPERNOVA_COMPUTER_URL",
    "http://127.0.0.1:" <> int.to_string(port_of(1, fake)),
  )
  forget.retry_all(dir, None, fn(principal) {
    principal |> should.equal("sim:ana")
  })
  forget.pending(dir, "sim:ana") |> should.equal([])
  file_exists(forget.pending_path(dir, "sim:ana")) |> should.equal(Ok(False))
  requests(fake)
  |> list.any(fn(raw) {
    string.starts_with(raw, "POST /v1/apagar ")
    && string.contains(raw, computer.person_hash("sim:ana"))
  })
  |> should.be_true
  stop(fake)
}

pub fn an_inbox_log_not_rewritten_is_not_forgotten_yet_test() {
  let dir = test_workspace.create_temp_dir("forget_caixa")
  let assert Ok(box) = inbox.start(dir)
  inbox.set_global(box)
  let message =
    port.ChannelMessage(
      id: "m1",
      channel: "sim",
      channel_id: "dm-ana",
      user_id: "ana",
      username: "ana",
      content: "um segredo",
      is_bot: False,
      reply_to_id: None,
    )
  inbox.receive(box, message, 1) |> should.be_true
  // The rewrite cannot happen: its temporary file's place is taken.
  let blocker = dir <> "/inbox.jsonl.tmp"
  let assert Ok(Nil) = ensure_dir(blocker)
  let assert Ok(counts) = forget.forget(dir, "sim:ana", None)
  counts.pendente |> should.equal([forget.Caixa])
  string.contains(forget.receipt(counts), "fila") |> should.be_true

  // The rewrite can happen again: tried, done.
  let _ = clear_dir(blocker)
  let _ = del_dir(blocker)
  forget.retry(dir, "sim:ana", None) |> should.equal(Ok([]))
  inbox.stop(box)
}

pub fn nothing_left_says_forgotten_test() {
  let dir = test_workspace.create_temp_dir("forget_tudo")
  let assert Ok(counts) = forget.forget(dir, "sim:ana", None)
  counts.pendente |> should.equal([])
  forget.receipt(counts) |> should.equal("Esqueci.")
}

pub fn an_unreadable_note_means_everything_is_left_test() {
  let dir = test_workspace.create_temp_dir("forget_ilegivel")
  let assert Ok(_) = forget.forget(dir, "sim:ana", None)
  let path = forget.pending_path(dir, "sim:ana")
  let assert Ok(Nil) = write(path, "{nope")
  forget.pending(dir, "sim:ana")
  |> should.equal([forget.Computador, forget.Caixa, forget.Sessoes])
}

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write(path: String, content: String) -> Result(Nil, String)

/// PRD-K, K-I7: after /esquecer, nothing of the person's is left: no
/// request, grant or permission, no vault, and the computer (container,
/// volume with the browser sessions, network) deleted at the dispatcher.
pub fn nothing_of_the_person_is_left_test() {
  let dir = test_workspace.create_temp_dir("forget_nada_sobra")
  let assert Ok(_) =
    aprovacoes.ask(
      dir,
      "sim:ana",
      0,
      aprovacoes.Draft(
        kind: aprovacoes.Send,
        target: "site:a.com",
        summary: "Usar o site a.com.",
        explanation: "",
        task: None,
        approve: aprovacoes.Window(aprovacoes.one_hour_ms),
        always: True,
        origin: aprovacoes.Chat("sim", "dm-ana", "ana"),
      ),
    )
  let assert Ok(_) =
    aprovacoes.decide(
      dir,
      "sim:ana",
      0,
      1,
      aprovacoes.Approve(aprovacoes.Permanent),
    )
  let assert Ok(Nil) =
    cofre.guardar(dir, "sim:ana", "chave", "gov.br", "123", "segredo")
  let fake = start_fake(fn(_) { #(200, "{\"ok\":true,\"apagado\":true}") })
  envoy.set(
    "SUPERNOVA_COMPUTER_URL",
    "http://127.0.0.1:" <> int.to_string(port_of(1, fake)),
  )
  use <- exception.defer(fn() {
    envoy.unset("SUPERNOVA_COMPUTER_URL")
    stop(fake)
  })
  let assert Ok(counts) = forget.forget(dir, "sim:ana", None)
  counts.pendente |> should.equal([])
  file_exists(aprovacoes.path(dir, "sim:ana")) |> should.equal(Ok(False))
  file_exists(cofre.path(dir, "sim:ana")) |> should.equal(Ok(False))
  aprovacoes.permissions(dir, "sim:ana") |> should.equal(Ok([]))
  cofre.sites(dir, "sim:ana") |> should.equal(Ok([]))
  requests(fake)
  |> list.any(fn(raw) {
    string.starts_with(raw, "POST /v1/apagar ")
    && string.contains(raw, computer.person_hash("sim:ana"))
  })
  |> should.be_true
}
