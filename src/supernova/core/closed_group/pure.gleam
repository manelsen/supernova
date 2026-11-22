//// Closed Group — Pure logic
////
//// Command parsing, role/capability mapping, and Portuguese reply text.
//// No actor calls, no clock access: callers pass timestamps.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/config
import supernova/core/access/pure as access_pure
import supernova/core/access/types as access_types
import supernova/core/audit_log/types as audit_types
import supernova/core/budget_policy/types as budget_types
import supernova/core/capability_manifest/types as cap_types
import supernova/core/closed_group/types
import supernova/core/principal
import supernova/core/resource_ledger/pure as ledger_pure
import supernova/core/resource_ledger/types as ledger_types
import supernova/llm/provider

// ============================================================================
// Constants and replies
// ============================================================================

pub const fail_closed_reply =
  "Estou com um problema interno e não posso responder agora. Tente de novo em alguns minutos."

pub const rate_limited_reply = "Muitas mensagens seguidas. Espere um pouco."

pub const instance_cap_reply =
  "O limite diário desta instância foi atingido. Volto amanhã."

pub const budget_reply_prefix =
  "Seu limite de uso desta hora acabou. Ele renova às "

/// True when `content` is one of the kernel's fixed refusals: fail-closed,
/// rate limit, instance cap, hourly budget or the configured access denial.
/// The `sim` channel uses it to report a refused turn as `denied`, so a test
/// can never pass on refusals while believing the agent answered.
pub fn is_kernel_refusal(content: String, denied_reply: String) -> Bool {
  let text = string.trim(content)
  text == fail_closed_reply
  || text == rate_limited_reply
  || text == instance_cap_reply
  || string.starts_with(text, budget_reply_prefix)
  || { denied_reply != "" && text == string.trim(denied_reply) }
}

pub fn budget_exhausted_reply(now_ms: Int) -> String {
  budget_reply_prefix <> next_hour_label(now_ms) <> "."
}

pub fn next_hour_label(now_ms: Int) -> String {
  let seconds = now_ms / 1000 |> int.max(0)
  let hours = seconds / 3600 |> int.max(0)
  let next = hours + 1
  pad2(next % 24) <> ":" <> pad2(0)
}

fn pad2(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}

// ============================================================================
// Config conversion
// ============================================================================

pub fn access_config(config: config.AccessConfig) -> access_types.AccessConfig {
  access_types.AccessConfig(
    mode: case config.mode {
      config.Allowlist -> access_types.Allowlist
      config.Open -> access_types.Open
    },
    admins: config.admins,
    members: config.members,
    denied_reply: config.denied_reply,
    allowed_chats: config.allowed_chats,
  )
}

pub fn role_name(role: access_types.Role) -> String {
  case role {
    access_types.Admin -> "admin"
    access_types.Member -> "membro"
  }
}

/// Stable machine key for a role. Used as the `PrincipalContext.role` and as
/// the capability-manifest key in the syscall gateway. `role_name` is the
/// Portuguese display name and must never be used as a key.
pub fn role_key(role: access_types.Role) -> String {
  case role {
    access_types.Admin -> "admin"
    access_types.Member -> "member"
  }
}

pub fn role_from_string(role: String) -> access_types.Role {
  case role {
    "admin" -> access_types.Admin
    _ -> access_types.Member
  }
}

pub fn budget_config(
  config: config.RoleBudgetConfig,
) -> budget_types.BudgetConfig {
  budget_types.BudgetConfig(
    tokens_per_hour: config.tokens_per_hour,
    tool_calls_per_minute: -1,
    tool_calls_per_hour: config.tool_calls_per_hour,
    max_recursion_depth: 5,
    max_sub_agents: 10,
  )
}

pub fn role_budget_config(
  config: config.RoleBudgetsConfig,
  role: access_types.Role,
) -> config.RoleBudgetConfig {
  case role {
    access_types.Admin -> config.admin
    access_types.Member -> config.member
  }
}

pub fn rate_limit_for(
  config: config.RateLimitConfig,
  role: access_types.Role,
) -> Int {
  case role {
    access_types.Admin -> config.admin.messages_per_minute
    access_types.Member -> config.member.messages_per_minute
  }
}

pub fn manifest_for(
  config: config.CapabilitiesConfig,
  role: access_types.Role,
) -> cap_types.CapabilityManifest {
  let role_config = capability_for(config, role)
  cap_types.CapabilityManifest(
    allowed_tools: role_config.allowed,
    denied_tools: role_config.denied,
  )
}

pub fn capability_for(
  config: config.CapabilitiesConfig,
  role: access_types.Role,
) -> config.RoleCapabilitiesConfig {
  case role {
    access_types.Admin -> config.admin
    access_types.Member -> config.member
  }
}

/// Filter the tool list sent to the LLM for a role.
pub fn tools_for(
  capabilities: config.CapabilitiesConfig,
  role: access_types.Role,
  tools: List(provider.ToolDefinition),
) -> List(provider.ToolDefinition) {
  let role_config = capability_for(capabilities, role)
  list.filter(tools, fn(tool) { allowed_name(role_config, tool.name) })
}

fn allowed_name(
  role_config: config.RoleCapabilitiesConfig,
  name: String,
) -> Bool {
  let canonical = canonical_tool_name(name)
  case
    list.contains(role_config.denied, name)
    || list.contains(role_config.denied, canonical)
  {
    True -> False
    False ->
      case list.contains(role_config.allowed, "*") {
        True -> True
        False ->
          list.contains(role_config.allowed, name)
          || list.contains(role_config.allowed, canonical)
      }
  }
}

pub fn canonical_tool_name(name: String) -> String {
  case name {
    "web" -> "web_fetch"
    _ -> name
  }
}

// ============================================================================
// Chat authorization
// ============================================================================

pub fn chat_key(channel: String, chat_id: String) -> String {
  principal.chat_principal(channel, chat_id)
}

pub fn is_private_chat(channel: String, chat_id: String) -> Bool {
  principal.is_private_chat(channel, chat_id)
}

// ============================================================================
// Command parsing
// ============================================================================

pub type UsageCommand {
  UsageSelf
  UsageAll
}

pub type AuditQuery {
  AuditAll(limit: Int)
  AuditPrincipal(principal_id: String, limit: Int)
}

pub type TetCommand {
  RaiseCap(usd: Float)
}

pub fn command_text(text: String) -> String {
  let trimmed = string.trim(text)
  case string.split(trimmed, " ") {
    [first, ..] -> first
    [] -> ""
  }
}

pub type ForgetCommand {
  ForgetStart
  ForgetConfirm
}

/// Parse `/esquecer` and `/esquecer confirmo`, also in the `/esquecer@Bot`
/// form Telegram uses in groups.
pub fn forget_command(content: String) -> Option(ForgetCommand) {
  let words =
    string.trim(content)
    |> string.lowercase
    |> string.split(" ")
    |> list.filter(fn(word) { word != "" })
  case words {
    [first] ->
      case normalize_command(first) {
        "/esquecer" -> Some(ForgetStart)
        _ -> None
      }
    [first, "confirmo"] ->
      case normalize_command(first) {
        "/esquecer" -> Some(ForgetConfirm)
        _ -> None
      }
    _ -> None
  }
}

pub type AgendaCommand {
  AgendaList
  AgendaRemove(id: Int)
  AgendaUsage
}

/// Parse `/agenda` and `/agenda remover N`, also as `/agenda@Bot`.
pub fn agenda_command(content: String) -> Option(AgendaCommand) {
  let words =
    string.trim(content)
    |> string.lowercase
    |> string.split(" ")
    |> list.filter(fn(word) { word != "" })
  case words {
    [first, ..rest] ->
      case normalize_command(first), rest {
        "/agenda", [] -> Some(AgendaList)
        "/agenda", ["remover", id] ->
          case int.parse(id) {
            Ok(id) -> Some(AgendaRemove(id))
            Error(_) -> Some(AgendaUsage)
          }
        "/agenda", _ -> Some(AgendaUsage)
        _, _ -> None
      }
    [] -> None
  }
}

pub fn is_agenda_command(content: String) -> Bool {
  agenda_command(content) != None
}

pub fn is_forget_command(content: String) -> Bool {
  forget_command(content) != None
}

pub fn is_eu_command(text: String) -> Bool {
  let command = command_text(text) |> normalize_command
  command == "/eu"
}

pub fn eu_reply(
  principal_id: String,
  chat_key: String,
  is_private: Bool,
) -> String {
  let chat_kind = case is_private {
    True -> "Conversa privada"
    False -> "Chat atual"
  }
  "Seu identificador: " <> principal_id <> "\n" <> chat_kind <> ": " <> chat_key
}

pub fn parse_usage_command(text: String) -> Option(UsageCommand) {
  let tokens = tokens(text)
  case tokens {
    [command] ->
      case normalize_command(command) {
        "/uso" -> Some(UsageSelf)
        _ -> None
      }
    [command, arg] ->
      case normalize_command(command), string.lowercase(arg) {
        "/uso", "todos" -> Some(UsageAll)
        _, _ -> None
      }
    _ -> None
  }
}

pub fn parse_teto_command(text: String) -> Option(TetCommand) {
  let tokens = tokens(text)
  case tokens {
    [command, action, value] ->
      case normalize_command(command), string.lowercase(action) {
        "/teto", "liberar" ->
          case float.parse(value) {
            Ok(usd) if usd >. 0.0 -> Some(RaiseCap(usd))
            Ok(_) -> None
            Error(_) ->
              case int.parse(value) {
                Ok(usd) if usd > 0 -> Some(RaiseCap(int.to_float(usd)))
                _ -> None
              }
          }
        _, _ -> None
      }
    _ -> None
  }
}

pub fn parse_audit_command(text: String) -> Option(AuditQuery) {
  let tokens = tokens(text)
  case tokens {
    [command] ->
      case normalize_command(command) {
        "/auditoria" -> Some(AuditAll(20))
        _ -> None
      }
    [command, arg] ->
      case normalize_command(command) {
        "/auditoria" ->
          case int.parse(arg) {
            Ok(limit) -> Some(AuditAll(clamp_audit_limit(limit)))
            Error(_) ->
              case principal.parse(arg) {
                Ok(parsed) -> Some(AuditPrincipal(principal_id(parsed), 20))
                Error(_) -> None
              }
          }
        _ -> None
      }
    [command, filter, arg] ->
      case normalize_command(command) {
        "/auditoria" ->
          case principal.parse(filter) {
            Ok(parsed) ->
              case int.parse(arg) {
                Ok(limit) ->
                  Some(AuditPrincipal(
                    principal_id(parsed),
                    clamp_audit_limit(limit),
                  ))
                Error(_) -> None
              }
            Error(_) -> None
          }
        _ -> None
      }
    _ -> None
  }
}

fn principal_id(parsed: principal.Principal) -> String {
  principal.principal_id(parsed)
}

fn clamp_audit_limit(limit: Int) -> Int {
  case limit < 1 {
    True -> 1
    False -> int.min(limit, 100)
  }
}

fn tokens(text: String) -> List(String) {
  text
  |> string.trim
  |> string.split(" ")
  |> list.filter(fn(token) { token != "" })
}

fn normalize_command(token: String) -> String {
  let lowered = string.lowercase(token)
  case string.split(lowered, "@") {
    [command, ..] -> command
    [] -> lowered
  }
}

// ============================================================================
// Usage formatting
// ============================================================================

pub type UsageSummary {
  UsageSummary(
    prompt_tokens: Int,
    completion_tokens: Int,
    tool_calls: Int,
    cost_usd: Float,
  )
}

pub fn empty_usage() -> UsageSummary {
  UsageSummary(0, 0, 0, 0.0)
}

pub fn summarize(events: List(ledger_types.UsageEvent)) -> UsageSummary {
  list.fold(events, empty_usage(), fn(summary, event) {
    case event {
      ledger_types.LLMUsage(
        prompt_tokens: prompt,
        completion_tokens: completion,
        cost_usd: cost,
        ..,
      ) ->
        UsageSummary(
          prompt_tokens: summary.prompt_tokens + prompt,
          completion_tokens: summary.completion_tokens + completion,
          tool_calls: summary.tool_calls,
          cost_usd: summary.cost_usd +. cost,
        )
      ledger_types.ToolUsage(..) ->
        UsageSummary(..summary, tool_calls: summary.tool_calls + 1)
    }
  })
}

pub fn usage_self_reply(
  principal_id: String,
  events: List(ledger_types.UsageEvent),
  now_ms: Int,
) -> String {
  let mine = ledger_pure.usage_for(events, principal_id)
  let hour = summarize(filter_since(mine, now_ms - 3_600_000))
  let day = summarize(filter_since(mine, now_ms - 86_400_000))
  "Uso de "
  <> principal_id
  <> "\n"
  <> "Última hora: "
  <> summary_line(hour)
  <> "\n"
  <> "Últimas 24 h: "
  <> summary_line(day)
}

fn summary_line(summary: UsageSummary) -> String {
  int.to_string(summary.prompt_tokens + summary.completion_tokens)
  <> " tokens (entrada "
  <> int.to_string(summary.prompt_tokens)
  <> ", saída "
  <> int.to_string(summary.completion_tokens)
  <> "), "
  <> int.to_string(summary.tool_calls)
  <> " chamadas de ferramenta, US$ "
  <> float.to_string(summary.cost_usd)
}

pub fn usage_all_reply(
  events: List(ledger_types.UsageEvent),
  now_ms: Int,
  daily_cost: Float,
  cap_usd: Float,
) -> String {
  let recent = filter_since(events, now_ms - 86_400_000)
  let rows = aggregate_by_principal(recent)
  let table =
    rows
    |> list.map(fn(row) {
      let #(principal_id, summary) = row
      principal_id <> " | " <> summary_line(summary)
    })
    |> string.join("\n")
  let table = case table {
    "" -> "(sem uso nas últimas 24 h)"
    _ -> table
  }
  "Uso por pessoa (24 h):\n"
  <> table
  <> "\n\nInstância hoje: US$ "
  <> float.to_string(daily_cost)
  <> " de "
  <> cap_text(cap_usd)
}

fn cap_text(cap_usd: Float) -> String {
  case cap_usd == -1.0 {
    True -> "sem teto"
    False -> "US$ " <> float.to_string(cap_usd)
  }
}

fn aggregate_by_principal(
  events: List(ledger_types.UsageEvent),
) -> List(#(String, UsageSummary)) {
  let principals =
    events
    |> list.map(ledger_pure.event_principal_id)
    |> list.unique

  principals
  |> list.map(fn(principal_id) {
    #(principal_id, summarize(ledger_pure.usage_for(events, principal_id)))
  })
  |> list.sort(fn(a, b) {
    let #(_, sa) = a
    let #(_, sb) = b
    int.compare(tokens_of(sb), tokens_of(sa))
  })
}

fn tokens_of(summary: UsageSummary) -> Int {
  summary.prompt_tokens + summary.completion_tokens
}

pub fn filter_since(
  events: List(ledger_types.UsageEvent),
  since_ms: Int,
) -> List(ledger_types.UsageEvent) {
  list.filter(events, fn(event) {
    ledger_pure.event_timestamp(event) >= since_ms
  })
}

// ============================================================================
// Audit formatting
// ============================================================================

pub fn audit_reply(
  entries: List(audit_types.AuditEntry),
  query: AuditQuery,
) -> String {
  let #(filtered, limit) = case query {
    AuditAll(limit) -> #(entries, limit)
    AuditPrincipal(principal_id, limit) -> #(
      list.filter(entries, fn(entry) { entry.agent_id == principal_id }),
      limit,
    )
  }

  let lines =
    filtered
    |> list.take(limit)
    |> list.map(audit_line)
    |> string.join("\n")

  case lines {
    "" -> "(nenhum evento)"
    _ -> lines
  }
}

pub fn audit_line(entry: audit_types.AuditEntry) -> String {
  int.to_string(entry.timestamp)
  <> " | "
  <> entry.agent_id
  <> " | "
  <> entry.operation
  <> " | "
  <> entry.target
  <> " | "
  <> audit_types.result_to_string(entry.result)
  <> " | "
  <> entry.details
}

// ============================================================================
// Alerts
// ============================================================================

pub fn budget_alert_text(principal_id: String) -> String {
  "⚠️ " <> principal_id <> " usou 80% do limite da hora."
}

pub fn instance_alert_text(percent: Int, cap_usd: Float) -> String {
  "⚠️ A instância usou "
  <> int.to_string(percent)
  <> "% do teto diário de US$ "
  <> float.to_string(cap_usd)
  <> "."
}

pub fn abuse_alert_text(chat_key: String) -> String {
  "⚠️ Mais de 5 tentativas negadas em 10 minutos em " <> chat_key <> "."
}

pub fn fail_closed_alert_text(component: String) -> String {
  "⚠️ Componente indisponível: "
  <> component
  <> ". Requisições estão sendo negadas."
}

// ============================================================================
// Access command help
// ============================================================================

pub fn access_list_reply(
  admins: List(String),
  members: List(String),
) -> String {
  "Admins: " <> list_text(admins) <> "\nMembros: " <> list_text(members)
}

pub fn chat_list_reply(chats: List(String)) -> String {
  "Chats autorizados: " <> list_text(chats)
}

fn list_text(items: List(String)) -> String {
  case items {
    [] -> "(nenhum)"
    _ -> string.join(items, ", ")
  }
}

pub fn access_help() -> String {
  "Comandos: /acesso listar | /acesso adicionar <principal> [admin|membro] | /acesso remover <principal> | /acesso chat adicionar|remover|listar <id>"
}

/// Whether a command may bypass the chat allowlist check.
///
/// Only chat management may run in a not-yet-authorized group; report and
/// principal-management commands still require the chat to be authorized.
pub fn is_chat_management_command(content: String) -> Bool {
  case access_pure.parse_command(content) {
    Some(access_types.AddChat(_)) -> True
    Some(access_types.RemoveChat(_)) -> True
    Some(access_types.ListChats) -> True
    _ -> False
  }
}

/// Label of a gate decision, for metrics. `content` is the inbound text and
/// `denied_reply` the configured refusal.
pub fn decision_label(
  result: types.GateResult,
  content: String,
  denied_reply: String,
) -> String {
  case result {
    types.Allowed(_) -> "allowed"
    types.Ignored("missing sender") -> "missing_sender"
    types.Ignored("access denied") -> "denied"
    types.Ignored("chat denied") -> "chat_denied"
    types.Ignored("rate limited") -> "rate_limited"
    types.Ignored(_) -> "ignored"
    types.Reply(text) -> reply_label(text, content, denied_reply)
  }
}

fn reply_label(text: String, content: String, denied_reply: String) -> String {
  case
    text == fail_closed_reply,
    text == rate_limited_reply,
    text == instance_cap_reply,
    string.starts_with(text, budget_reply_prefix),
    is_eu_command(content),
    text == denied_reply
  {
    True, _, _, _, _, _ -> "fail_closed"
    _, True, _, _, _, _ -> "rate_limited"
    _, _, True, _, _, _ -> "instance_cap"
    _, _, _, True, _, _ -> "budget"
    _, _, _, _, True, _ -> "eu"
    _, _, _, _, _, True -> "denied"
    _, _, _, _, _, _ -> "command"
  }
}
