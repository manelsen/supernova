import gleam/option.{None, Some}
import gleeunit/should
import supernova/core/closed_group/pure

pub fn agenda_command_test() {
  pure.agenda_command("/agenda") |> should.equal(Some(pure.AgendaList))
  pure.agenda_command("/Agenda@SupernovaBot")
  |> should.equal(Some(pure.AgendaList))
  pure.agenda_command("/agenda remover 3")
  |> should.equal(Some(pure.AgendaRemove(3)))
  pure.agenda_command("/agenda remover três")
  |> should.equal(Some(pure.AgendaUsage))
  pure.agenda_command("/agenda apagar tudo")
  |> should.equal(Some(pure.AgendaUsage))
  pure.agenda_command("minha agenda") |> should.equal(None)
  pure.agenda_command("/agendar") |> should.equal(None)
}
