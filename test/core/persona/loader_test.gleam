import gleam/int
import gleam/string
import gleeunit/should
import supernova/core/persona/loader
import supernova/core/persona/types

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn now_ms() -> Int

fn unique_workspace(prefix: String) -> String {
  "/tmp/supernova-persona-" <> prefix <> "-" <> int.to_string(now_ms())
}

pub fn load_returns_bootstrap_required_when_persona_is_missing_test() {
  let workspace = unique_workspace("missing")
  loader.load(workspace)
  |> should.equal(Error(types.BootstrapRequired))
}

pub fn write_bootstrap_files_then_load_returns_persona_files_test() {
  let workspace = unique_workspace("write-read")

  let assert Ok(_) =
    loader.write_bootstrap_files(
      workspace,
      name: "Aurora",
      soul: "Curiosa, direta e honesta.",
      style: "Respostas curtas em pt-BR.",
      user: "Me chame de Micelio.",
      timestamp: "2026-04-19T00:00:00Z",
    )

  let assert Ok(persona) = loader.load(workspace)
  string.contains(persona.identity, "**Nome:** Aurora")
  |> should.equal(True)
  string.contains(persona.soul, "Curiosa, direta e honesta.")
  |> should.equal(True)
  string.contains(persona.style, "Respostas curtas em pt-BR.")
  |> should.equal(True)
  string.contains(persona.user, "Me chame de Micelio.")
  |> should.equal(True)
}

pub fn extract_name_reads_identity_name_test() {
  let name =
    loader.extract_name(
      "# Identidade\n\n**Nome:** Aurora\n\n**Papel:** Agente de IA do Supernova\n",
    )
  name
  |> should.equal("Aurora")
}
