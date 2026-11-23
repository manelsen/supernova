//// The commands a person can use in closed-group mode, in one list: the
//// `/help` text and the Telegram command menu are both made from it, so
//// they cannot drift apart from each other.

import gleam/list
import gleam/string

pub type Command {
  Command(
    /// Without the slash; Telegram accepts a-z, 0-9 and _ (1 to 32).
    name: String,
    /// Short line for the menu (Telegram: at most 256 characters).
    description: String,
    /// Longer line for `/help`, with the arguments it takes.
    usage: String,
    admin_only: Bool,
  )
}

pub const all = [
  Command(
    name: "agenda",
    description: "O que você pediu para depois",
    usage: "/agenda — o que você pediu para depois. /agenda remover <id> tira um item.",
    admin_only: False,
  ),
  Command(
    name: "uso",
    description: "Quanto você gastou",
    usage: "/uso — quanto você gastou.",
    admin_only: False,
  ),
  Command(
    name: "model",
    description: "Escolher o modelo",
    usage: "/model — ver e trocar o modelo; /model <modelo> troca direto.",
    admin_only: False,
  ),
  Command(
    name: "status",
    description: "Estado da sessão",
    usage: "/status — provedor e modelo em uso.",
    admin_only: False,
  ),
  Command(
    name: "esquecer",
    description: "Apagar o que você contou",
    usage: "/esquecer — explica o que é apagado. /esquecer confirmo apaga as conversas, as lembranças, os arquivos e a agenda; o nome e o jeito da agente ficam.",
    admin_only: False,
  ),
  Command(
    name: "eu",
    description: "Seu id, para um admin autorizar",
    usage: "/eu — seu id, para um admin autorizar você.",
    admin_only: False,
  ),
  Command(
    name: "help",
    description: "Esta ajuda",
    usage: "/help — esta ajuda.",
    admin_only: False,
  ),
  Command(
    name: "acesso",
    description: "Quem pode usar a instância",
    usage: "/acesso listar | adicionar <principal> [admin|membro] | remover <principal> — quem pode usar a instância. /acesso chat adicionar|remover|listar <id> — grupos liberados.",
    admin_only: True,
  ),
  Command(
    name: "teto",
    description: "Teto de gasto do dia",
    usage: "/teto liberar <usd> — sobe o teto de gasto de hoje. /uso todos mostra o gasto de todos.",
    admin_only: True,
  ),
  Command(
    name: "auditoria",
    description: "Últimos eventos de auditoria",
    usage: "/auditoria [n] — os últimos eventos de auditoria (20 por padrão).",
    admin_only: True,
  ),
]

/// The commands a member, or an admin, can use.
pub fn for_role(is_admin: Bool) -> List(Command) {
  list.filter(all, fn(command) { is_admin || !command.admin_only })
}

/// The `/help` answer for a member or an admin.
pub fn help_text(is_admin: Bool) -> String {
  let #(admin, member) =
    for_role(is_admin) |> list.partition(fn(command) { command.admin_only })
  let lines = fn(commands: List(Command)) {
    list.map(commands, fn(command) { command.usage }) |> string.join("\n")
  }
  let intro =
    "Fale comigo normalmente; os comandos abaixo são para o que não é conversa.\n\n"
  case admin {
    [] -> intro <> lines(member)
    _ -> intro <> lines(member) <> "\n\nAdmin:\n" <> lines(admin)
  }
}
