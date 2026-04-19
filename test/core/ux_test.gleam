import gleeunit/should
import supernova/core/ux

pub fn resolve_shortcut_accepts_portuguese_help_test() {
  ux.resolve_shortcut("ajuda")
  |> should.equal(Ok(ux.Help))
}

pub fn resolve_shortcut_accepts_slash_models_test() {
  ux.resolve_shortcut("/models")
  |> should.equal(Ok(ux.Models))
}

pub fn resolve_shortcut_accepts_think_aliases_test() {
  ux.resolve_shortcut("raciocina")
  |> should.equal(Ok(ux.Think))
}
