//// PRD-A, A-06: what a voice reads, without what only eyes need.

import gleeunit/should
import supernova/channel/voice_text

pub fn decorations_tables_and_marks_are_not_read_aloud_test() {
  voice_text.for_speech(
    "## Resumo\n\n**Olá**, tudo `certo`?\n-----\n| Dia | Hora |\n|---|---|\n| seg | 9h |\n👏👏👏👏 fim",
  )
  |> should.equal("Resumo\n\nOlá, tudo certo?\nDia — Hora\nseg — 9h\n👏👏 fim")
}
