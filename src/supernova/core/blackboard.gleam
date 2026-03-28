//// Core Blackboard module for Supernova
//// Implements a shared memory pattern using Gleam's actor system.
////
//// The Blackboard provides a shared key-value store that multiple processes
//// can read from and write to. It supports optional TTL (time-to-live) for
//// entries and subscription-based notifications when values change.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string

// ============================================================================
// Types
// ============================================================================

/// A unique key for blackboard entries
pub type Key =
  String

/// A value stored in the blackboard
pub type Value =
  String

/// An entry in the blackboard with optional TTL
pub type Entry {
  Entry(
    /// The stored value
    value: Value,
    /// Optional time-to-live in milliseconds (None = no expiry)
    ttl: Option(Int),
    /// Timestamp when the entry was created (milliseconds)
    created_at: Int,
  )
}

/// A subscription to blackboard changes
pub type Subscription {
  Subscription(
    /// The subject to receive notifications
    subscriber: Subject(ChangeNotification),
    /// Optional key pattern to filter notifications (None = all changes)
    key_filter: Option(String),
  )
}

/// Notification sent to subscribers when a change occurs
pub type ChangeNotification {
  /// A value was set
  ValueSet(key: Key, value: Value)
  /// A value was deleted
  ValueDeleted(key: Key)
  /// A value expired due to TTL
  ValueExpired(key: Key)
}

/// Internal state of the blackboard
pub type BlackboardState {
  BlackboardState(
    /// The stored entries
    entries: Dict(Key, Entry),
    /// Active subscriptions
    subscriptions: Dict(Int, Subscription),
    /// Counter for generating subscription IDs
    subscription_counter: Int,
    /// Current timestamp (for TTL checks)
    current_time: Int,
  )
}

/// Messages that can be sent to the blackboard
pub type Message {
  /// Set a value with optional TTL
  Set(reply_to: Subject(Nil), key: Key, value: Value, ttl: Option(Int))
  /// Get a value by key
  Get(reply_to: Subject(Option(Entry)), key: Key)
  /// Delete a value by key
  Delete(reply_to: Subject(Bool), key: Key)
  /// List all keys
  ListKeys(reply_to: Subject(List(Key)))
  /// Subscribe to change notifications
  Subscribe(
    reply_to: Subject(Int),
    subscriber: Subject(ChangeNotification),
    key_filter: Option(String),
  )
  /// Unsubscribe from notifications
  Unsubscribe(reply_to: Subject(Bool), subscription_id: Int)
  /// Stop the blackboard
  Stop(reply_to: Subject(Nil))
  /// Internal: check and expire entries
  CheckExpiry(reply_to: Subject(Int))
}

/// A handle to a running blackboard
pub type Blackboard =
  Subject(Message)

/// Error type for blackboard operations
pub type BlackboardError {
  /// The blackboard operation timed out
  TimeoutError
  /// The subscription was not found
  SubscriptionNotFoundError
}

// ============================================================================
// Logging Helpers
// ============================================================================

/// Log level for structured logging
type LogLevel {
  Debug
  Info
  Warning
  LogError
}

/// Format log level to string
fn log_level_to_string(level: LogLevel) -> String {
  case level {
    Debug -> "DEBUG"
    Info -> "INFO"
    Warning -> "WARN"
    LogError -> "ERROR"
  }
}

/// Log a structured message (internal helper)
fn log(
  level: LogLevel,
  component: String,
  message: String,
  attrs: List(#(String, String)),
) -> String {
  let level_str = log_level_to_string(level)

  let attrs_str =
    attrs
    |> list.map(fn(pair) {
      let #(key, value) = pair
      key <> "=" <> value
    })
    |> string.join(" ")

  case attrs_str {
    "" -> "[" <> level_str <> "] [" <> component <> "] " <> message
    _ ->
      "["
      <> level_str
      <> "] ["
      <> component
      <> "] "
      <> message
      <> " | "
      <> attrs_str
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if an entry has expired
fn is_expired(entry: Entry, current_time: Int) -> Bool {
  case entry.ttl {
    None -> False
    Some(ttl) -> current_time >= entry.created_at + ttl
  }
}
fn get_current_time() -> Int {
  0
}

/// Notify all relevant subscribers of a change
fn notify_subscribers(
  subscriptions: Dict(Int, Subscription),
  notification: ChangeNotification,
) -> Nil {
  let key = case notification {
    ValueSet(k, _) -> Some(k)
    ValueDeleted(k) -> Some(k)
    ValueExpired(k) -> Some(k)
  }

  subscriptions
  |> dict.values()
  |> list.each(fn(sub) {
    // Check if subscriber should receive this notification
    let should_notify = case sub.key_filter, key {
      None, _ -> True
      Some(filter), Some(k) -> k == filter
      Some(_), None -> False
    }

    case should_notify {
      True -> actor.send(sub.subscriber, notification)
      False -> Nil
    }
  })
}

/// Remove expired entries from state
fn cleanup_expired(state: BlackboardState) -> BlackboardState {
  let current_time = state.current_time

  let valid_entries =
    state.entries
    |> dict.filter(fn(_, entry) { !is_expired(entry, current_time) })

  // Find expired keys and notify
  let expired_keys =
    state.entries
    |> dict.filter(fn(_, entry) { is_expired(entry, current_time) })
    |> dict.keys()

  list.each(expired_keys, fn(key) {
    notify_subscribers(state.subscriptions, ValueExpired(key))
  })

  BlackboardState(..state, entries: valid_entries)
}

// ============================================================================
// Actor Implementation
// ============================================================================

/// Handle incoming messages and update state
fn handle_message(
  state: BlackboardState,
  message: Message,
) -> actor.Next(BlackboardState, Message) {
  // First, clean up any expired entries
  let state = cleanup_expired(state)

  case message {
    Set(reply_to, key, value, ttl) -> {
      let ttl_str = case ttl {
        Some(ms) -> int.to_string(ms)
        None -> "none"
      }
      let _ =
        log(Debug, "blackboard", "Set", [
          #("key", key),
          #("ttl", ttl_str),
        ])

      let entry = Entry(value: value, ttl: ttl, created_at: state.current_time)

      let new_entries = dict.insert(state.entries, key, entry)
      let new_state = BlackboardState(..state, entries: new_entries)

      // Notify subscribers
      notify_subscribers(state.subscriptions, ValueSet(key, value))

      actor.send(reply_to, Nil)
      actor.continue(new_state)
    }

    Get(reply_to, key) -> {
      let _ = log(Debug, "blackboard", "Get", [#("key", key)])

      let result =
        dict.get(state.entries, key)
        |> option.from_result()

      actor.send(reply_to, result)
      actor.continue(state)
    }

    Delete(reply_to, key) -> {
      let _ = log(Debug, "blackboard", "Delete", [#("key", key)])

      case dict.get(state.entries, key) {
        Ok(_) -> {
          let new_entries = dict.delete(state.entries, key)
          let new_state = BlackboardState(..state, entries: new_entries)

          // Notify subscribers
          notify_subscribers(state.subscriptions, ValueDeleted(key))

          actor.send(reply_to, True)
          actor.continue(new_state)
        }
        Error(_) -> {
          actor.send(reply_to, False)
          actor.continue(state)
        }
      }
    }

    ListKeys(reply_to) -> {
      let keys = dict.keys(state.entries)
      let _ =
        log(Debug, "blackboard", "ListKeys", [
          #("count", int.to_string(list.length(keys))),
        ])

      actor.send(reply_to, keys)
      actor.continue(state)
    }

    Subscribe(reply_to, subscriber, key_filter) -> {
      let subscription_id = state.subscription_counter
      let subscription =
        Subscription(subscriber: subscriber, key_filter: key_filter)

      let new_subscriptions =
        dict.insert(state.subscriptions, subscription_id, subscription)

      let new_state =
        BlackboardState(
          ..state,
          subscriptions: new_subscriptions,
          subscription_counter: subscription_id + 1,
        )

      let key_filter_str = case key_filter {
        Some(k) -> k
        None -> "none"
      }
      let _ =
        log(Info, "blackboard", "Subscribe", [
          #("subscription_id", int.to_string(subscription_id)),
          #("key_filter", key_filter_str),
        ])

      actor.send(reply_to, subscription_id)
      actor.continue(new_state)
    }

    Unsubscribe(reply_to, subscription_id) -> {
      let _ =
        log(Info, "blackboard", "Unsubscribe", [
          #("subscription_id", int.to_string(subscription_id)),
        ])

      case dict.get(state.subscriptions, subscription_id) {
        Ok(_) -> {
          let new_subscriptions =
            dict.delete(state.subscriptions, subscription_id)
          let new_state =
            BlackboardState(..state, subscriptions: new_subscriptions)

          actor.send(reply_to, True)
          actor.continue(new_state)
        }
        Error(_) -> {
          actor.send(reply_to, False)
          actor.continue(state)
        }
      }
    }

    CheckExpiry(reply_to) -> {
      let state = cleanup_expired(state)
      let expired_count = dict.size(state.entries) - dict.size(state.entries)

      let _ =
        log(Debug, "blackboard", "CheckExpiry", [
          #("expired", int.to_string(expired_count)),
        ])

      actor.send(reply_to, expired_count)
      actor.continue(state)
    }

    Stop(reply_to) -> {
      let _ = log(Info, "blackboard", "Stop", [])
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new blackboard.
/// Returns a Subject that can be used to interact with the blackboard.
pub fn start() -> Result(Blackboard, actor.StartError) {
  let initial_state =
    BlackboardState(
      entries: dict.new(),
      subscriptions: dict.new(),
      subscription_counter: 0,
      current_time: get_current_time(),
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Set a value in the blackboard without TTL.
pub fn set(blackboard: Blackboard, key: Key, value: Value) -> Nil {
  actor.call(blackboard, waiting: 1000, sending: Set(_, key, value, None))
}

/// Set a value in the blackboard with a TTL (time-to-live in milliseconds).
pub fn set_with_ttl(
  blackboard: Blackboard,
  key: Key,
  value: Value,
  ttl: Int,
) -> Nil {
  actor.call(blackboard, waiting: 1000, sending: Set(_, key, value, Some(ttl)))
}

/// Get a value from the blackboard.
/// Returns Some(Entry) if the key exists, None otherwise.
pub fn get(blackboard: Blackboard, key: Key) -> Option(Entry) {
  actor.call(blackboard, waiting: 1000, sending: Get(_, key))
}

/// Delete a value from the blackboard.
/// Returns True if the key existed and was deleted, False otherwise.
pub fn delete(blackboard: Blackboard, key: Key) -> Bool {
  actor.call(blackboard, waiting: 1000, sending: Delete(_, key))
}

/// List all keys in the blackboard.
pub fn list(blackboard: Blackboard) -> List(Key) {
  actor.call(blackboard, waiting: 1000, sending: ListKeys)
}

/// Subscribe to change notifications from the blackboard.
/// Returns a subscription ID that can be used to unsubscribe.
/// The subscriber will receive ChangeNotification messages for all changes
/// unless a key_filter is provided.
pub fn subscribe(
  blackboard: Blackboard,
  subscriber: Subject(ChangeNotification),
) -> Int {
  actor.call(blackboard, waiting: 1000, sending: Subscribe(_, subscriber, None))
}

/// Subscribe to change notifications for a specific key.
/// Returns a subscription ID that can be used to unsubscribe.
pub fn subscribe_to_key(
  blackboard: Blackboard,
  subscriber: Subject(ChangeNotification),
  key: Key,
) -> Int {
  actor.call(blackboard, waiting: 1000, sending: Subscribe(
    _,
    subscriber,
    Some(key),
  ))
}

/// Unsubscribe from blackboard notifications.
/// Returns True if the subscription existed and was removed, False otherwise.
pub fn unsubscribe(blackboard: Blackboard, subscription_id: Int) -> Bool {
  actor.call(blackboard, waiting: 1000, sending: Unsubscribe(_, subscription_id))
}

/// Stop the blackboard gracefully.
pub fn stop(blackboard: Blackboard) -> Nil {
  actor.call(blackboard, waiting: 1000, sending: Stop)
}

/// Get the value directly from an entry (convenience function)
pub fn entry_value(entry: Entry) -> Value {
  entry.value
}

/// Get the TTL from an entry (convenience function)
pub fn entry_ttl(entry: Entry) -> Option(Int) {
  entry.ttl
}

/// Check if an entry has a TTL (convenience function)
pub fn entry_has_ttl(entry: Entry) -> Bool {
  case entry.ttl {
    Some(_) -> True
    None -> False
  }
}
