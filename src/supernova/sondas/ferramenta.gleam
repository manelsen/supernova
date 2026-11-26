//// The definition of the `sonda` tool, apart from the probe itself, so the
//// list of built-in tools does not depend on the executor.

import supernova/llm/provider

pub const name = "sonda"

/// The longest instructions a probe takes.
pub const max_instructions = 2000

/// The tool as a person sees it: the code probe only for those who have
/// the computer (S15).
pub fn tool(may_code: Bool) -> provider.ToolDefinition {
  let kinds = case may_code {
    True -> "web, disco, codigo"
    False -> "web, disco"
  }
  provider.new_tool(
    name: name,
    description: "Send a probe: a machine that does one job for your person and reports back, while you keep talking. Kinds: "
      <> kinds
      <> ". web searches and reads pages; disco organizes and reads the files kept for your person on your computer"
      <> case may_code {
      True -> "; codigo writes, runs and tests code on your computer"
      False -> ""
    }
      <> ". The probe does not see this conversation: put in the instructions everything it needs to know. You answer your person now; the result arrives later as a message [Sonda …] in this chat. Never invent the result before it arrives. List or cancel probes with `tarefa`.",
    parameters: [
      provider.string_param("tipo", "Kind: " <> kinds, True),
      provider.string_param(
        "instrucoes",
        "What the probe must do, complete, in up to 2000 characters.",
        True,
      ),
      provider.string_param(
        "motivo",
        "In a few words, what it is for; you will see it when the result arrives.",
        False,
      ),
      provider.string_param(
        "teto_usd",
        "Cost ceiling in US$, such as 1.50 (default 0.20, at most 5.00). Above 0.50 your person is asked first, and the probe starts only after they say yes: send it again with the same ceiling.",
        False,
      ),
    ],
  )
}
