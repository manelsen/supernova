//// Approvals: what a person allowed their agent to do outside the machine
//// (PRD-K, K-01).
////
//// ```
//// gate refuses ──ask──► request #N (pending, 24 h) ──► the person's DM (K-02)
////                            │ 3 h: one reminder (tick)
////                            │ 24 h: expired, as refused (tick)
////                            ▼
////         decide(Approve(scope)) ──► grant ──► gate: allowed(…) consumes Once
//// ```
////
//// - **Requests** are pending, approved, refused, expired or cancelled.
//// - **Grants** are what an approval leaves: for one use, for the task that
////   asked, or permanent (K4: by kind and target, listable, revocable). The
////   permanent ones are the person's permissions.
//// - **Only the code decides.** Nothing here reads model text: `decide` is
////   called by the channel code that recognised the person's answer (K1, K3).
//// - **On disk.** Everything is in `<self>/aprovacoes.json`, written under a
////   per-person lock before anything is answered, so it survives a restart.
////   The clock is a parameter: tests drive time by hand.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import supernova/core/agent_identity
import supernova/metrics/record

/// A request waits this long for an answer, then expires as refused (K6).
pub const expires_after_ms = 86_400_000

/// One reminder, this long after the request (K6).
pub const remind_after_ms = 10_800_000

/// A one-use grant not used in this time is dropped.
pub const once_valid_ms = 86_400_000

/// Decided requests kept in the file, besides the pending ones.
const kept_decided = 30

/// What needs approval (K2, K10, K21).
pub type Kind {
  /// An effect outside the machine: sending a form, using a site (K10).
  Send
  /// Entering an account.
  Login
  /// Deleting or overwriting a person's file.
  Overwrite
  /// A task whose cost ceiling is above US$ 0.50 (K8).
  Spend
  /// A site the shell may download from, for this person (K21).
  ShellSite
}

pub type Status {
  Pending
  Approved
  Refused
  Expired
  Cancelled
}

pub type Scope {
  Once
  ForTask
  Permanent
}

/// What the gate asks about, built by the code from the refused action.
pub type Draft {
  Draft(
    kind: Kind,
    /// The target: a site, a file path, an amount. Grants match on it.
    target: String,
    /// The code's first sentence (K7), fixed and short.
    summary: String,
    /// The agent's explanation, shown after the summary.
    explanation: String,
    /// The task that asked, if any; its grants end with it.
    task: Option(Int),
  )
}

pub type Request {
  Request(
    id: Int,
    kind: Kind,
    target: String,
    summary: String,
    explanation: String,
    task: Option(Int),
    status: Status,
    created_at: Int,
    reminded: Bool,
    decided_at: Option(Int),
  )
}

pub type Grant {
  Grant(
    id: Int,
    request: Int,
    kind: Kind,
    target: String,
    scope: Scope,
    task: Option(Int),
    created_at: Int,
  )
}

/// The person's answer, as the code recognised it.
pub type Decision {
  Approve(Scope)
  Refuse
}

/// What the passing of time did, for the channel to tell.
pub type Event {
  Remind(Request)
  Expire(Request)
}

// ============================================================================
// Requests
// ============================================================================

/// Open a request. Asking again for what is already pending returns that
/// request instead of a second one.
pub fn ask(
  data_dir: String,
  principal: String,
  now: Int,
  draft: Draft,
) -> Result(Request, String) {
  update(data_dir, principal, fn(file) {
    let same =
      list.find(file.requests, fn(r) {
        // A request past its deadline is left for `tick` to expire and tell.
        r.status == Pending
        && now - r.created_at < expires_after_ms
        && r.kind == draft.kind
        && r.target == draft.target
        && r.task == draft.task
      })
    case same {
      Ok(request) -> Ok(#(file, request))
      Error(Nil) -> {
        let request =
          Request(
            id: file.next_id,
            kind: draft.kind,
            target: draft.target,
            summary: draft.summary,
            explanation: draft.explanation,
            task: draft.task,
            status: Pending,
            created_at: now,
            reminded: False,
            decided_at: None,
          )
        record.count("approvals_total", [
          #("kind", kind_name(draft.kind)),
          #("outcome", "asked"),
        ])
        Ok(#(
          File(..file, next_id: file.next_id + 1, requests: [
            request,
            ..file.requests
          ]),
          request,
        ))
      }
    }
  })
}

/// Record the person's answer to a pending request. An answer that comes
/// after the deadline finds the request expired.
pub fn decide(
  data_dir: String,
  principal: String,
  now: Int,
  id: Int,
  decision: Decision,
) -> Result(Request, String) {
  update(data_dir, principal, fn(file) {
    let file = expire(file, now).0
    use request <- result.try(
      list.find(file.requests, fn(r) { r.id == id })
      |> result.replace_error("no request #" <> int.to_string(id)),
    )
    case request.status {
      Pending -> {
        let #(status, grants, next_grant) = case decision {
          Refuse -> #(Refused, file.grants, file.next_grant)
          Approve(scope) -> {
            let grant =
              Grant(
                id: file.next_grant,
                request: id,
                kind: request.kind,
                target: request.target,
                scope: scope_for(scope, request.task),
                task: request.task,
                created_at: now,
              )
            #(Approved, [grant, ..file.grants], file.next_grant + 1)
          }
        }
        let decided = Request(..request, status: status, decided_at: Some(now))
        record.count("approvals_total", [
          #("kind", kind_name(request.kind)),
          #("outcome", status_name(status)),
        ])
        record.duration_ms("approval_answer_seconds", now - request.created_at, [
          #("outcome", status_name(status)),
        ])
        Ok(#(
          File(..replace(file, decided), grants: grants, next_grant: next_grant),
          decided,
        ))
      }
      _ ->
        Error(
          "request #"
          <> int.to_string(id)
          <> " is "
          <> status_name(request.status),
        )
    }
  })
}

/// A task-scoped approval for a request with no task is good for one use.
fn scope_for(scope: Scope, task: Option(Int)) -> Scope {
  case scope, task {
    ForTask, None -> Once
    _, _ -> scope
  }
}

/// The pending requests, oldest first.
pub fn pending(
  data_dir: String,
  principal: String,
) -> Result(List(Request), String) {
  use file <- result.map(load(data_dir, principal))
  file.requests
  |> list.filter(fn(r) { r.status == Pending })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

pub fn request(
  data_dir: String,
  principal: String,
  id: Int,
) -> Result(Request, String) {
  use file <- result.try(load(data_dir, principal))
  list.find(file.requests, fn(r) { r.id == id })
  |> result.replace_error("no request #" <> int.to_string(id))
}

/// Let time pass: send the 3 h reminders and expire what waited 24 h.
pub fn tick(
  data_dir: String,
  principal: String,
  now: Int,
) -> Result(List(Event), String) {
  update(data_dir, principal, fn(file) {
    let #(file, expired) = expire(file, now)
    let #(file, reminded) = remind(file, now)
    Ok(#(
      file,
      list.append(list.map(reminded, Remind), list.map(expired, Expire)),
    ))
  })
}

fn expire(file: File, now: Int) -> #(File, List(Request)) {
  let #(requests, expired) =
    list.map_fold(file.requests, [], fn(expired, r) {
      case r.status == Pending && now - r.created_at >= expires_after_ms {
        True -> {
          let done = Request(..r, status: Expired, decided_at: Some(now))
          record.count("approvals_total", [
            #("kind", kind_name(r.kind)),
            #("outcome", "expired"),
          ])
          #([done, ..expired], done)
        }
        False -> #(expired, r)
      }
    })
    |> fn(pair) { #(pair.1, list.reverse(pair.0)) }
  #(File(..file, requests: requests), expired)
}

fn remind(file: File, now: Int) -> #(File, List(Request)) {
  let #(requests, reminded) =
    list.map_fold(file.requests, [], fn(reminded, r) {
      case
        r.status == Pending
        && !r.reminded
        && now - r.created_at >= remind_after_ms
      {
        True -> {
          let marked = Request(..r, reminded: True)
          #([marked, ..reminded], marked)
        }
        False -> #(reminded, r)
      }
    })
    |> fn(pair) { #(pair.1, list.reverse(pair.0)) }
  #(File(..file, requests: requests), reminded)
}

// ============================================================================
// Grants
// ============================================================================

/// Whether an action of this kind on this target is allowed, consuming a
/// one-use grant when that is what allows it. A permanent or task grant is
/// preferred, so a one-use grant is not spent when it is not needed.
pub fn allowed(
  data_dir: String,
  principal: String,
  now: Int,
  kind: Kind,
  target: String,
  task: Option(Int),
) -> Result(Bool, String) {
  update(data_dir, principal, fn(file) {
    let file = drop_stale(file, now)
    let matching =
      list.filter(file.grants, fn(g) {
        g.kind == kind
        && g.target == target
        && case g.scope {
          Permanent -> True
          ForTask -> g.task == task && task != None
          Once -> g.task == None || g.task == task
        }
      })
    let lasting = list.find(matching, fn(g) { g.scope != Once })
    case lasting, matching {
      Ok(_), _ -> Ok(#(file, True))
      Error(Nil), [] -> Ok(#(file, False))
      Error(Nil), [once, ..] -> {
        let file =
          File(
            ..file,
            grants: list.filter(file.grants, fn(g) { g.id != once.id }),
          )
        Ok(#(file, True))
      }
    }
  })
}

fn drop_stale(file: File, now: Int) -> File {
  File(
    ..file,
    grants: list.filter(file.grants, fn(g) {
      g.scope != Once || now - g.created_at < once_valid_ms
    }),
  )
}

/// The person's permanent permissions (K4), newest first.
pub fn permissions(
  data_dir: String,
  principal: String,
) -> Result(List(Grant), String) {
  use file <- result.map(load(data_dir, principal))
  list.filter(file.grants, fn(g) { g.scope == Permanent })
}

/// Revoke a grant. Revoking what is not there is an error the caller tells.
pub fn revoke(
  data_dir: String,
  principal: String,
  id: Int,
) -> Result(Grant, String) {
  update(data_dir, principal, fn(file) {
    use grant <- result.try(
      list.find(file.grants, fn(g) { g.id == id })
      |> result.replace_error("no permission " <> int.to_string(id)),
    )
    record.count("approvals_revoked_total", [#("kind", kind_name(grant.kind))])
    Ok(#(
      File(..file, grants: list.filter(file.grants, fn(g) { g.id != id })),
      grant,
    ))
  })
}

/// A task ended: its grants go, and its pending requests are cancelled.
pub fn task_ended(
  data_dir: String,
  principal: String,
  now: Int,
  task: Int,
) -> Result(List(Request), String) {
  update(data_dir, principal, fn(file) {
    let grants =
      list.filter(file.grants, fn(g) {
        g.scope == Permanent || g.task != Some(task)
      })
    let #(cancelled, requests) =
      list.map_fold(file.requests, [], fn(cancelled, r) {
        case r.status == Pending && r.task == Some(task) {
          True -> {
            let done = Request(..r, status: Cancelled, decided_at: Some(now))
            #([done, ..cancelled], done)
          }
          False -> #(cancelled, r)
        }
      })
    Ok(#(
      File(..file, requests: requests, grants: grants),
      list.reverse(cancelled),
    ))
  })
}

// ============================================================================
// Names
// ============================================================================

pub fn kind_name(kind: Kind) -> String {
  case kind {
    Send -> "envio"
    Login -> "conta"
    Overwrite -> "arquivo"
    Spend -> "gasto"
    ShellSite -> "site_shell"
  }
}

fn kind_from(name: String) -> Result(Kind, Nil) {
  case name {
    "envio" -> Ok(Send)
    "conta" -> Ok(Login)
    "arquivo" -> Ok(Overwrite)
    "gasto" -> Ok(Spend)
    "site_shell" -> Ok(ShellSite)
    _ -> Error(Nil)
  }
}

pub fn status_name(status: Status) -> String {
  case status {
    Pending -> "pendente"
    Approved -> "aprovado"
    Refused -> "recusado"
    Expired -> "expirado"
    Cancelled -> "cancelado"
  }
}

fn status_from(name: String) -> Result(Status, Nil) {
  case name {
    "pendente" -> Ok(Pending)
    "aprovado" -> Ok(Approved)
    "recusado" -> Ok(Refused)
    "expirado" -> Ok(Expired)
    "cancelado" -> Ok(Cancelled)
    _ -> Error(Nil)
  }
}

fn scope_name(scope: Scope) -> String {
  case scope {
    Once -> "uso_unico"
    ForTask -> "tarefa"
    Permanent -> "permanente"
  }
}

fn scope_from(name: String) -> Result(Scope, Nil) {
  case name {
    "uso_unico" -> Ok(Once)
    "tarefa" -> Ok(ForTask)
    "permanente" -> Ok(Permanent)
    _ -> Error(Nil)
  }
}

pub fn declare_metrics() -> Nil {
  let kinds = [Send, Login, Overwrite, Spend, ShellSite]
  list.each(kinds, fn(kind) {
    list.each(["asked", "aprovado", "recusado", "expirado"], fn(outcome) {
      record.declare("approvals_total", [
        #("kind", kind_name(kind)),
        #("outcome", outcome),
      ])
    })
    record.declare("approvals_revoked_total", [#("kind", kind_name(kind))])
  })
  list.each(["aprovado", "recusado"], fn(outcome) {
    record.declare_duration("approval_answer_seconds", [#("outcome", outcome)])
  })
}

// ============================================================================
// Persistence: <self>/aprovacoes.json, under a per-person lock
// ============================================================================

type File {
  File(
    next_id: Int,
    next_grant: Int,
    requests: List(Request),
    grants: List(Grant),
  )
}

pub fn path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/aprovacoes.json"
}

fn replace(file: File, request: Request) -> File {
  File(
    ..file,
    requests: list.map(file.requests, fn(r) {
      case r.id == request.id {
        True -> request
        False -> r
      }
    }),
  )
}

fn update(
  data_dir: String,
  principal: String,
  change: fn(File) -> Result(#(File, a), String),
) -> Result(a, String) {
  with_lock("aprovacoes:" <> principal, fn() {
    use current <- result.try(load(data_dir, principal))
    use #(file, value) <- result.try(change(current))
    use _ <- result.try(save(data_dir, principal, prune(file)))
    Ok(value)
  })
}

/// Keep the pending requests and the last decided ones, newest first.
fn prune(file: File) -> File {
  let #(open, closed) =
    list.partition(file.requests, fn(r) { r.status == Pending })
  let newest = fn(a: Request, b: Request) { int.compare(b.id, a.id) }
  File(
    ..file,
    requests: list.append(
        open,
        list.take(list.sort(closed, newest), kept_decided),
      )
      |> list.sort(newest),
  )
}

fn load(data_dir: String, principal: String) -> Result(File, String) {
  let target = path(data_dir, principal)
  case file_exists(target) {
    Ok(False) -> Ok(File(next_id: 1, next_grant: 1, requests: [], grants: []))
    Error(reason) -> Error(reason)
    Ok(True) -> {
      use text <- result.try(read_file(target))
      json.parse(text, file_decoder())
      |> result.replace_error("approvals file is damaged: " <> target)
    }
  }
}

fn save(
  data_dir: String,
  principal: String,
  file: File,
) -> Result(Nil, String) {
  let target = path(data_dir, principal)
  use _ <- result.try(ensure_dir(agent_identity.self_dir(data_dir, principal)))
  use _ <- result.try(write_file(target <> ".tmp", encode(file)))
  rename(target <> ".tmp", target)
}

fn optional_int(value: Option(Int)) -> json.Json {
  json.nullable(value, json.int)
}

fn encode(file: File) -> String {
  json.object([
    #("next_id", json.int(file.next_id)),
    #("next_grant", json.int(file.next_grant)),
    #(
      "requests",
      json.array(file.requests, fn(r) {
        json.object([
          #("id", json.int(r.id)),
          #("kind", json.string(kind_name(r.kind))),
          #("target", json.string(r.target)),
          #("summary", json.string(r.summary)),
          #("explanation", json.string(r.explanation)),
          #("task", optional_int(r.task)),
          #("status", json.string(status_name(r.status))),
          #("created_at", json.int(r.created_at)),
          #("reminded", json.bool(r.reminded)),
          #("decided_at", optional_int(r.decided_at)),
        ])
      }),
    ),
    #(
      "grants",
      json.array(file.grants, fn(g) {
        json.object([
          #("id", json.int(g.id)),
          #("request", json.int(g.request)),
          #("kind", json.string(kind_name(g.kind))),
          #("target", json.string(g.target)),
          #("scope", json.string(scope_name(g.scope))),
          #("task", optional_int(g.task)),
          #("created_at", json.int(g.created_at)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn named(from: fn(String) -> Result(a, Nil), zero: a) -> decode.Decoder(a) {
  use name <- decode.then(decode.string)
  case from(name) {
    Ok(value) -> decode.success(value)
    Error(Nil) -> decode.failure(zero, "known name")
  }
}

fn file_decoder() -> decode.Decoder(File) {
  let request = {
    use id <- decode.field("id", decode.int)
    use kind <- decode.field("kind", named(kind_from, Send))
    use target <- decode.field("target", decode.string)
    use summary <- decode.field("summary", decode.string)
    use explanation <- decode.field("explanation", decode.string)
    use task <- decode.field("task", decode.optional(decode.int))
    use status <- decode.field("status", named(status_from, Pending))
    use created_at <- decode.field("created_at", decode.int)
    use reminded <- decode.field("reminded", decode.bool)
    use decided_at <- decode.field("decided_at", decode.optional(decode.int))
    decode.success(Request(
      id:,
      kind:,
      target:,
      summary:,
      explanation:,
      task:,
      status:,
      created_at:,
      reminded:,
      decided_at:,
    ))
  }
  let grant = {
    use id <- decode.field("id", decode.int)
    use request <- decode.field("request", decode.int)
    use kind <- decode.field("kind", named(kind_from, Send))
    use target <- decode.field("target", decode.string)
    use scope <- decode.field("scope", named(scope_from, Once))
    use task <- decode.field("task", decode.optional(decode.int))
    use created_at <- decode.field("created_at", decode.int)
    decode.success(Grant(
      id:,
      request:,
      kind:,
      target:,
      scope:,
      task:,
      created_at:,
    ))
  }
  use next_id <- decode.field("next_id", decode.int)
  use next_grant <- decode.field("next_grant", decode.int)
  use requests <- decode.field("requests", decode.list(request))
  use grants <- decode.field("grants", decode.list(grant))
  decode.success(File(next_id:, next_grant:, requests:, grants:))
}

@external(erlang, "supernova_self_ffi", "with_lock")
fn with_lock(key: String, body: fn() -> a) -> a

@external(erlang, "supernova_self_ffi", "rename_file")
fn rename(from: String, to: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)
