import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/self/aprovacoes.{
  Approve, Approved, Cancelled, Draft, Expire, Expired, ForTask, Login, Once,
  Overwrite, Pending, Permanent, Refuse, Refused, Remind, Send, Spend,
}
import supernova/self/forget
import test_workspace

const hour = 3_600_000

fn draft(target: String, task) {
  Draft(
    kind: Send,
    target: target,
    summary: "Enviar o formulário em " <> target <> ".",
    explanation: "Para marcar a consulta.",
    task: task,
  )
}

fn setup(name: String) -> String {
  test_workspace.create_temp_dir("aprovacoes_" <> name)
}

pub fn a_request_waits_reminds_once_and_expires_as_refused_test() {
  let dir = setup("ciclo")
  let assert Ok(asked) =
    aprovacoes.ask(dir, "ana", 0, draft("saude.gov.br", None))
  asked.id |> should.equal(1)
  asked.status |> should.equal(Pending)

  aprovacoes.tick(dir, "ana", 2 * hour) |> should.equal(Ok([]))
  let assert Ok([Remind(reminded)]) = aprovacoes.tick(dir, "ana", 3 * hour)
  reminded.id |> should.equal(1)
  // One reminder only.
  aprovacoes.tick(dir, "ana", 10 * hour) |> should.equal(Ok([]))

  let assert Ok([Expire(expired)]) = aprovacoes.tick(dir, "ana", 24 * hour)
  expired.status |> should.equal(Expired)
  aprovacoes.pending(dir, "ana") |> should.equal(Ok([]))
  // An expired request allows nothing.
  aprovacoes.allowed(dir, "ana", 24 * hour, Send, "saude.gov.br", None)
  |> should.equal(Ok(False))
}

pub fn an_answer_after_the_deadline_finds_it_expired_test() {
  let dir = setup("tarde")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  aprovacoes.decide(dir, "ana", 25 * hour, 1, Approve(Once))
  |> should.be_error
  aprovacoes.allowed(dir, "ana", 25 * hour, Send, "a.com", None)
  |> should.equal(Ok(False))
}

pub fn asking_again_returns_the_pending_request_test() {
  let dir = setup("repetido")
  let assert Ok(first) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  let assert Ok(again) = aprovacoes.ask(dir, "ana", 5, draft("a.com", None))
  again.id |> should.equal(first.id)
  let assert Ok(other) = aprovacoes.ask(dir, "ana", 5, draft("b.com", None))
  other.id |> should.equal(2)
  let assert Ok(open) = aprovacoes.pending(dir, "ana")
  list.map(open, fn(r) { r.id }) |> should.equal([1, 2])
}

pub fn asking_after_the_deadline_opens_a_new_request_test() {
  let dir = setup("vencido")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  let assert Ok(fresh) =
    aprovacoes.ask(dir, "ana", 24 * hour, draft("a.com", None))
  fresh.id |> should.equal(2)
  // The old one is still expired and told by the tick.
  let assert Ok([Expire(old)]) = aprovacoes.tick(dir, "ana", 24 * hour)
  old.id |> should.equal(1)
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 24 * hour, 2, Approve(Once))
}

pub fn a_one_use_grant_bound_to_a_task_stays_with_it_test() {
  let dir = setup("uso_unico_tarefa")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", Some(7)))
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 0, 1, Approve(Once))
  aprovacoes.allowed(dir, "ana", 1, Send, "a.com", None)
  |> should.equal(Ok(False))
  aprovacoes.allowed(dir, "ana", 1, Send, "a.com", Some(8))
  |> should.equal(Ok(False))
  aprovacoes.allowed(dir, "ana", 1, Send, "a.com", Some(7))
  |> should.equal(Ok(True))
}

pub fn a_one_use_grant_is_spent_by_its_use_test() {
  let dir = setup("uso_unico")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  aprovacoes.allowed(dir, "ana", 1, Send, "a.com", None)
  |> should.equal(Ok(False))
  let assert Ok(decided) = aprovacoes.decide(dir, "ana", 2, 1, Approve(Once))
  decided.status |> should.equal(Approved)
  // Another kind or target is not covered.
  aprovacoes.allowed(dir, "ana", 3, Login, "a.com", None)
  |> should.equal(Ok(False))
  aprovacoes.allowed(dir, "ana", 3, Send, "b.com", None)
  |> should.equal(Ok(False))
  aprovacoes.allowed(dir, "ana", 3, Send, "a.com", None)
  |> should.equal(Ok(True))
  aprovacoes.allowed(dir, "ana", 4, Send, "a.com", None)
  |> should.equal(Ok(False))
  // A decided request takes no second answer.
  aprovacoes.decide(dir, "ana", 5, 1, Refuse) |> should.be_error
}

pub fn an_unused_one_use_grant_lapses_test() {
  let dir = setup("caduca")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 0, 1, Approve(Once))
  aprovacoes.allowed(dir, "ana", 24 * hour, Send, "a.com", None)
  |> should.equal(Ok(False))
}

pub fn a_refusal_allows_nothing_test() {
  let dir = setup("recusa")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  let assert Ok(decided) = aprovacoes.decide(dir, "ana", 1, 1, Refuse)
  decided.status |> should.equal(Refused)
  decided.decided_at |> should.equal(Some(1))
  aprovacoes.allowed(dir, "ana", 2, Send, "a.com", None)
  |> should.equal(Ok(False))
}

pub fn a_task_takes_its_grants_and_requests_when_it_ends_test() {
  let dir = setup("tarefa")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", Some(7)))
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 1, 1, Approve(ForTask))
  // Good for every use within the task, and only within it.
  aprovacoes.allowed(dir, "ana", 2, Send, "a.com", Some(7))
  |> should.equal(Ok(True))
  aprovacoes.allowed(dir, "ana", 3, Send, "a.com", Some(7))
  |> should.equal(Ok(True))
  aprovacoes.allowed(dir, "ana", 3, Send, "a.com", Some(8))
  |> should.equal(Ok(False))
  aprovacoes.allowed(dir, "ana", 3, Send, "a.com", None)
  |> should.equal(Ok(False))

  let assert Ok(_) = aprovacoes.ask(dir, "ana", 4, draft("b.com", Some(7)))
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 4, draft("c.com", Some(8)))
  let assert Ok([cancelled]) = aprovacoes.task_ended(dir, "ana", 5, 7)
  cancelled.target |> should.equal("b.com")
  cancelled.status |> should.equal(Cancelled)
  aprovacoes.allowed(dir, "ana", 6, Send, "a.com", Some(7))
  |> should.equal(Ok(False))
  let assert Ok([left]) = aprovacoes.pending(dir, "ana")
  left.target |> should.equal("c.com")
}

pub fn a_task_approval_with_no_task_is_good_once_test() {
  let dir = setup("tarefa_sem")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 1, 1, Approve(ForTask))
  aprovacoes.allowed(dir, "ana", 2, Send, "a.com", None)
  |> should.equal(Ok(True))
  aprovacoes.allowed(dir, "ana", 3, Send, "a.com", None)
  |> should.equal(Ok(False))
}

pub fn a_permanent_permission_lasts_lists_and_revokes_test() {
  let dir = setup("permanente")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", Some(1)))
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 1, 1, Approve(Permanent))
  let assert Ok(_) = aprovacoes.task_ended(dir, "ana", 2, 1)
  aprovacoes.allowed(dir, "ana", 100 * hour, Send, "a.com", Some(9))
  |> should.equal(Ok(True))
  aprovacoes.allowed(dir, "ana", 100 * hour, Send, "a.com", None)
  |> should.equal(Ok(True))
  let assert Ok([permission]) = aprovacoes.permissions(dir, "ana")
  permission.target |> should.equal("a.com")
  permission.scope |> should.equal(Permanent)

  let assert Ok(_) = aprovacoes.revoke(dir, "ana", permission.id)
  aprovacoes.permissions(dir, "ana") |> should.equal(Ok([]))
  aprovacoes.allowed(dir, "ana", 101 * hour, Send, "a.com", None)
  |> should.equal(Ok(False))
  aprovacoes.revoke(dir, "ana", permission.id) |> should.be_error
}

pub fn a_lasting_grant_spares_the_one_use_grant_test() {
  let dir = setup("prefere")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 0, 1, Approve(Once))
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 0, 2, Approve(Permanent))
  aprovacoes.allowed(dir, "ana", 1, Send, "a.com", None)
  |> should.equal(Ok(True))
  let assert Ok(_) = aprovacoes.revoke(dir, "ana", 2)
  // The one-use grant was not spent while the permanent one allowed it.
  aprovacoes.allowed(dir, "ana", 2, Send, "a.com", None)
  |> should.equal(Ok(True))
  aprovacoes.allowed(dir, "ana", 3, Send, "a.com", None)
  |> should.equal(Ok(False))
}

pub fn people_do_not_share_approvals_test() {
  let dir = setup("pessoas")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 0, 1, Approve(Permanent))
  aprovacoes.allowed(dir, "bia", 1, Send, "a.com", None)
  |> should.equal(Ok(False))
  aprovacoes.decide(dir, "bia", 1, 1, Approve(Once)) |> should.be_error
}

pub fn everything_survives_a_restart_test() {
  // The state is only the file: reading it back is what a restart does.
  let dir = setup("reinicio")
  let assert Ok(_) =
    aprovacoes.ask(
      dir,
      "ana",
      0,
      Draft(
        kind: Overwrite,
        target: "notas.txt",
        summary: "Apagar notas.txt.",
        explanation: "",
        task: Some(3),
      ),
    )
  let assert Ok(_) =
    aprovacoes.ask(
      dir,
      "ana",
      0,
      Draft(
        kind: Spend,
        target: "2.00",
        summary: "Gastar até US$ 2,00.",
        explanation: "",
        task: None,
      ),
    )
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 1, 2, Approve(Permanent))
  let assert Ok([Remind(_)]) = aprovacoes.tick(dir, "ana", 3 * hour)
  let assert Ok(one) = aprovacoes.request(dir, "ana", 1)
  one.reminded |> should.be_true
  one.task |> should.equal(Some(3))
  one.kind |> should.equal(Overwrite)
  let assert Ok(two) = aprovacoes.request(dir, "ana", 2)
  two.status |> should.equal(Approved)
  two.decided_at |> should.equal(Some(1))
  // Numbering goes on where it stopped.
  let assert Ok(three) = aprovacoes.ask(dir, "ana", 4, draft("x.com", None))
  three.id |> should.equal(3)
}

pub fn a_damaged_file_fails_closed_test() {
  let dir = setup("estragado")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 0, 1, Approve(Permanent))
  let assert Ok(_) = write_file(aprovacoes.path(dir, "ana"), "{nope")
  aprovacoes.allowed(dir, "ana", 1, Send, "a.com", None) |> should.be_error
}

pub fn forgetting_deletes_the_approvals_test() {
  let dir = setup("esquecer")
  let assert Ok(_) = aprovacoes.ask(dir, "ana", 0, draft("a.com", None))
  let assert Ok(_) = aprovacoes.decide(dir, "ana", 0, 1, Approve(Permanent))
  let assert Ok(_) = forget.forget(dir, "ana", None)
  file_exists(aprovacoes.path(dir, "ana")) |> should.equal(Ok(False))
  aprovacoes.allowed(dir, "ana", 1, Send, "a.com", None)
  |> should.equal(Ok(False))
}

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)
