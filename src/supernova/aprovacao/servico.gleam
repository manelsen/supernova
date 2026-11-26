//// Approvals in the channels (PRD-K, K-02): where `self/aprovacoes` meets
//// the person and the agent.
////
//// ```
//// gate ──pedir──► aprovacoes.ask ──► the person's DM (text + buttons)
////                 └─► the tool tells the agent to wait
//// person ──"sim 3" / button / voice──► answer ──► aprovacoes.decide
////                 ├─► the person hears what was decided
////                 └─► the agent hears "[Aprovação 3] aprovada" in the chat
////                     the request was born in
//// clock ──tick──► 3 h reminder in the DM; 24 h expiry told to both
//// ```
////
//// Only the person decides (K3, K-I2): the router hands answers here only
//// from the person's own private chat, and each person's requests are in
//// their own file, so nobody else's answer can reach them.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import supernova/aprovacao/pedido.{Decide, Explain}
import supernova/channel/catalog as channel_catalog
import supernova/channel/port
import supernova/core/agent_identity
import supernova/core/principal
import supernova/self/aprovacoes.{type Request, Expire, Remind}

/// How often the clock looks for reminders and expiries.
pub const tick_every_ms = 60_000

pub type Context {
  Context(
    data_dir: String,
    clock: fn() -> Int,
    /// Send to the person's private chat. Channels without buttons drop
    /// them; the text says how to answer anyway.
    send_private: fn(String, String, Option(port.ChannelInteractiveReply)) ->
      Result(Nil, String),
    /// Hand a message to the agent, in the chat lane it names.
    inject: fn(port.ChannelMessage) -> Result(Nil, String),
  )
}

const key = "supernova_aprovacao_context"

pub fn configure(context: Context) -> Nil {
  global_put(key, context)
}

pub fn clear() -> Nil {
  global_erase(key)
}

pub fn get() -> Option(Context) {
  case global_has(key) {
    True -> Some(global_get(key))
    False -> None
  }
}

/// Where and how a request reaches a person's private chat: the channel,
/// and the reply. Channels without buttons get the text alone; it says how
/// to answer by text or voice.
pub fn private_reply(
  principal_id: String,
  text: String,
  buttons: Option(port.ChannelInteractiveReply),
) -> Result(#(String, port.ChannelReply), String) {
  case principal.parse(principal_id) {
    Error(Nil) -> Error("not a person: " <> principal_id)
    Ok(person) -> {
      let traits = channel_catalog.get(person.channel)
      let interactive = case traits.supports_interactions {
        True -> buttons
        False -> None
      }
      Ok(#(
        person.channel,
        port.ChannelReply(
          channel_id: traits.private_chat_for(person.user_id),
          content: text,
          reply_to_id: None,
          thread_id: None,
          typing: False,
          edit_message_id: None,
          interactive: interactive,
          media: [],
        ),
      ))
    }
  }
}

// ============================================================================
// Asking
// ============================================================================

/// Open a request and send it to the person's private chat. Returns what
/// the tool answers the agent. Asking again for what is pending sends
/// nothing new.
pub fn pedir(
  context: Context,
  principal: String,
  draft: aprovacoes.Draft,
  in_group in_group: Bool,
) -> Result(String, String) {
  use #(request, new) <- result.try(aprovacoes.ask(
    context.data_dir,
    principal,
    context.clock(),
    draft,
  ))
  use _ <- result.try(case new {
    False -> Ok(Nil)
    True -> send_request(context, principal, request, pedido.message)
  })
  Ok(pedido.asked_note(request, in_group: in_group))
}

fn send_request(
  context: Context,
  principal: String,
  request: Request,
  render: fn(Request, Bool) -> String,
) -> Result(Nil, String) {
  let alone = case aprovacoes.pending(context.data_dir, principal) {
    Ok([_]) -> True
    _ -> False
  }
  context.send_private(
    principal,
    render(request, alone),
    Some(pedido.buttons(request)),
  )
}

// ============================================================================
// Answering
// ============================================================================

/// A message in the person's private chat. Some(reply) when it was an
/// answer to a pending request (decided, or explained); None when it is
/// any other message, for the agent.
pub fn answer_text(
  context: Context,
  principal: String,
  content: String,
) -> Option(String) {
  case aprovacoes.pending(context.data_dir, principal) {
    Ok([_, ..] as pending) ->
      case pedido.parse(content) {
        Some(answer) -> Some(settle(context, principal, answer, pending))
        None -> None
      }
    _ -> None
  }
}

/// A pressed button. Some(reply) when it was an approval button.
pub fn answer_button(
  context: Context,
  principal: String,
  action_id: String,
) -> Option(String) {
  case pedido.parse_action(action_id) {
    None -> None
    Some(answer) ->
      case aprovacoes.pending(context.data_dir, principal) {
        Ok(pending) -> Some(settle(context, principal, answer, pending))
        Error(reason) -> Some(failed(reason))
      }
  }
}

fn settle(
  context: Context,
  principal: String,
  answer: pedido.Answer,
  pending: List(Request),
) -> String {
  case pedido.resolve(answer, pending) {
    Explain(text) -> text
    Decide(id, decision) ->
      case
        aprovacoes.decide(
          context.data_dir,
          principal,
          context.clock(),
          id,
          decision,
        )
      {
        Ok(request) -> {
          tell_agent(context, principal, request)
          pedido.decided_text(request)
        }
        Error(reason) -> failed(reason)
      }
  }
}

fn failed(reason: String) -> String {
  "Não consegui registrar a resposta (" <> reason <> "). Tente de novo."
}

/// The outcome goes to the agent in the chat the request was born in, as
/// the person, like a task's result.
fn tell_agent(context: Context, principal: String, request: Request) -> Nil {
  let _ =
    context.inject(port.ChannelMessage(
      id: "aprovacao:"
        <> int.to_string(request.id)
        <> ":"
        <> aprovacoes.status_name(request.status)
        <> ":"
        <> principal,
      channel: request.origin.channel,
      channel_id: request.origin.channel_id,
      user_id: request.origin.user_id,
      username: "",
      content: pedido.outcome_note(request),
      is_bot: False,
      reply_to_id: None,
    ))
  Nil
}

// ============================================================================
// The clock
// ============================================================================

/// Remind and expire for one person. Reading first keeps the file
/// untouched for a person with nothing pending.
pub fn tick(context: Context, principal: String) -> Nil {
  case aprovacoes.pending(context.data_dir, principal) {
    Ok([_, ..]) -> tick_pending(context, principal)
    _ -> Nil
  }
}

fn tick_pending(context: Context, principal: String) -> Nil {
  case aprovacoes.tick(context.data_dir, principal, context.clock()) {
    Error(_) -> Nil
    Ok(events) ->
      list.each(events, fn(event) {
        case event {
          Remind(request) -> {
            let _ =
              send_request(context, principal, request, fn(r, alone) {
                pedido.reminder(r, alone: alone)
              })
            Nil
          }
          Expire(request) -> {
            let _ =
              context.send_private(
                principal,
                pedido.decided_text(request),
                None,
              )
            tell_agent(context, principal, request)
          }
        }
      })
  }
}

/// Remind and expire for everyone who has requests.
pub fn tick_all(context: Context) -> Nil {
  list_agent_dirs(context.data_dir <> "/agents")
  |> list.map(agent_identity.decode_principal)
  |> list.filter(fn(principal) {
    file_exists(aprovacoes.path(context.data_dir, principal)) == Ok(True)
  })
  |> list.each(tick(context, _))
}

/// The clock, in its own process.
pub fn start_clock(context: Context) -> Nil {
  process.spawn_unlinked(fn() { clock_loop(context) })
  Nil
}

fn clock_loop(context: Context) -> Nil {
  process.sleep(tick_every_ms)
  tick_all(context)
  clock_loop(context)
}

/// A task ended: its grants go, and its pending requests are cancelled
/// and the person told.
pub fn task_ended(context: Context, principal: String, task: Int) -> Nil {
  case
    aprovacoes.task_ended(context.data_dir, principal, context.clock(), task)
  {
    Ok(cancelled) ->
      list.each(cancelled, fn(request) {
        let _ =
          context.send_private(principal, pedido.decided_text(request), None)
        Nil
      })
    Error(_) -> Nil
  }
}

@external(erlang, "supernova_self_ffi", "list_agent_dirs")
fn list_agent_dirs(path: String) -> List(String)

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put(key: String, value: a) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn global_get(key: String) -> a

@external(erlang, "supernova_global_ffi", "global_has")
fn global_has(key: String) -> Bool

@external(erlang, "supernova_global_ffi", "global_erase")
fn global_erase(key: String) -> Nil
