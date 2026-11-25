//// The agenda clock: every half minute, run what is due.
////
//// A due entry becomes a message in the person's private chat, handed to
//// the same router as any message they send, so access, budgets, history,
//// tools and delivery all apply unchanged. The entry is advanced and saved
//// before the message is handed over.

import exception
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/string
import supernova/agenda/schedule
import supernova/agenda/store
import supernova/channel/catalog
import supernova/channel/port
import supernova/core/agent_identity
import supernova/metrics/record
import supernova/self/epoch
import supernova/self/incidents

pub const interval_ms = 30_000

/// Publish every agenda outcome at zero (see `record.declare`).
pub fn declare_metrics() -> Nil {
  list.each(["ran", "dropped", "missed", "sweep_crashed"], fn(outcome) {
    record.declare("agenda_runs_total", [#("outcome", outcome)])
  })
}

/// The message the agent receives when an entry comes due.
pub fn wake_message(
  principal: String,
  entry: store.Entry,
  offset: Int,
) -> port.ChannelMessage {
  let channel = case string.split(principal, ":") {
    [channel, ..] -> channel
    [] -> principal
  }
  let user_id = agent_identity.user_id_from_principal(principal)
  port.ChannelMessage(
    id: "agenda:"
      <> int.to_string(entry.id)
      <> ":"
      <> int.to_string(entry.next_run_at),
    channel: channel,
    // The agenda always answers in the private chat, as the channel names
    // it (Telegram: the user id; Discord: `dm:<user_id>`).
    channel_id: catalog.get(channel).private_chat_for(user_id),
    user_id: user_id,
    username: "",
    content: wake_text(entry, offset),
    is_bot: False,
    reply_to_id: None,
  )
}

pub fn wake_text(entry: store.Entry, offset: Int) -> String {
  "[Agenda] Chegou a hora da tarefa "
  <> int.to_string(entry.id)
  <> " que você combinou com sua pessoa em "
  <> schedule.format_local(entry.created_at, offset)
  <> ": "
  <> entry.request
  <> "\nSua pessoa não escreveu agora. Faça o que foi pedido e escreva para ela."
}

/// Run every entry due at `now`. Returns how many were handed over.
///
/// An entry taken while its person runs /esquecer is dropped, not run: the
/// forget epoch is read before taking and checked again at each handoff.
pub fn sweep(
  data_dir: String,
  offset: Int,
  now: Int,
  deliver: fn(port.ChannelMessage) -> Nil,
) -> Int {
  store.owners(data_dir)
  |> list.fold(0, fn(count, principal) {
    let epoch_before = epoch.read(data_dir, principal)
    let #(due, skipped) =
      store.take_due_and_skipped(data_dir, principal, now, offset)
    let still_current = fn() {
      case epoch_before, epoch.read(data_dir, principal) {
        Ok(before), Ok(now_epoch) -> before == now_epoch
        _, _ -> False
      }
    }
    list.each(skipped, fn(entry) {
      record.count("agenda_runs_total", [#("outcome", "missed")])
      let _ =
        incidents.record_if(
          data_dir,
          principal,
          now,
          "a tarefa "
            <> int.to_string(entry.id)
            <> " da agenda não rodou às "
            <> schedule.format_local(entry.next_run_at, offset)
            <> ": o serviço estava fora do ar nessa hora",
          still_current,
        )
      Nil
    })
    due
    |> list.fold(count, fn(count, entry) {
      // Fail closed: an unreadable epoch never counts as unchanged.
      case still_current() {
        False -> {
          record.count("agenda_runs_total", [#("outcome", "dropped")])
          io.println(
            "agenda: dropped after forget entry="
            <> int.to_string(entry.id)
            <> " principal="
            <> principal,
          )
          count
        }
        True -> {
          io.println(
            "agenda: running entry="
            <> int.to_string(entry.id)
            <> " principal="
            <> principal,
          )
          deliver(wake_message(principal, entry, offset))
          record.count("agenda_runs_total", [#("outcome", "ran")])
          count + 1
        }
      }
    })
  })
}

/// Start the half-minute clock. A crash in one sweep is logged and the clock
/// keeps going.
pub fn start(
  data_dir: String,
  offset: Int,
  clock: fn() -> Int,
  deliver: fn(port.ChannelMessage) -> Nil,
) -> Nil {
  let _ =
    process.spawn_unlinked(fn() { loop(data_dir, offset, clock, deliver) })
  Nil
}

fn loop(
  data_dir: String,
  offset: Int,
  clock: fn() -> Int,
  deliver: fn(port.ChannelMessage) -> Nil,
) -> Nil {
  process.sleep(interval_ms)
  case exception.rescue(fn() { sweep(data_dir, offset, clock(), deliver) }) {
    Ok(_) -> Nil
    Error(error) -> {
      record.count("agenda_runs_total", [#("outcome", "sweep_crashed")])
      io.println_error("error: agenda sweep crashed: " <> string.inspect(error))
    }
  }
  loop(data_dir, offset, clock, deliver)
}
