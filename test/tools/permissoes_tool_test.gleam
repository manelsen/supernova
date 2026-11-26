import gleam/option.{None}
import gleam/string
import gleeunit/should
import supernova/self/aprovacoes.{Approve, Draft, Permanent, Send}
import supernova/tools/permissoes
import test_workspace

fn with_permission(name: String) -> String {
  let dir = test_workspace.create_temp_dir("permissoes_tool_" <> name)
  let assert Ok(_) =
    aprovacoes.ask(
      dir,
      "telegram:1",
      0,
      Draft(
        kind: Send,
        target: "a.com",
        summary: "Usar o site a.com.",
        explanation: "",
        task: None,
        approve: aprovacoes.Once,
        always: True,
        origin: aprovacoes.Chat("telegram", "1", "1"),
      ),
    )
  let assert Ok(_) =
    aprovacoes.decide(dir, "telegram:1", 0, 1, Approve(Permanent))
  dir
}

pub fn the_agent_lists_its_person_s_permissions_test() {
  let dir = with_permission("listar")
  let assert Ok(text) =
    permissoes.execute_for(dir, "telegram:1", "{\"action\":\"list\"}")
  string.contains(text, "a.com") |> should.be_true
  // Someone else's agent sees none of them.
  let assert Ok(other) =
    permissoes.execute_for(dir, "telegram:2", "{\"action\":\"list\"}")
  string.contains(other, "a.com") |> should.be_false
}

pub fn the_agent_revokes_when_asked_test() {
  let dir = with_permission("revogar")
  let assert Ok(text) =
    permissoes.execute_for(
      dir,
      "telegram:1",
      "{\"action\":\"revoke\",\"id\":1}",
    )
  string.starts_with(text, "Revogada") |> should.be_true
  aprovacoes.permissions(dir, "telegram:1") |> should.equal(Ok([]))
  let assert Ok(again) =
    permissoes.execute_for(
      dir,
      "telegram:1",
      "{\"action\":\"revoke\",\"id\":1}",
    )
  string.contains(again, "Não há permissão 1") |> should.be_true
}

pub fn the_agent_cannot_grant_test() {
  let dir = with_permission("conceder")
  permissoes.execute_for(dir, "telegram:1", "{\"action\":\"grant\",\"id\":1}")
  |> should.be_error
  permissoes.execute_for(dir, "telegram:1", "not json") |> should.be_error
}
