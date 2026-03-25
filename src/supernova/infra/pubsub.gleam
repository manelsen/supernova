//// PubSub — publish/subscribe infrastructure for inter-process communication.
////
//// Provides topic-based message broadcasting. Processes subscribe to topics
//// and receive messages broadcast to those topics.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(ps) = pubsub.start()
//// let my_subject = process.new_subject()
//// pubsub.subscribe(ps, "events", my_subject)
//// pubsub.broadcast(ps, "events", "something happened")
//// // my_subject receives "something happened"
//// ```

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor

// ============================================================================
// Types
// ============================================================================

pub type PubSubMessage {
  SubscribeTo(
    reply_to: Subject(Nil),
    topic: String,
    subscriber: Subject(String),
  )
  UnsubscribeFrom(
    reply_to: Subject(Result(Nil, String)),
    topic: String,
    subscriber: Subject(String),
  )
  BroadcastMsg(topic: String, message: String)
  ListTopics(reply_to: Subject(List(String)))
}

type PubSubState {
  PubSubState(topics: Dict(String, List(Subject(String))))
}

pub type PubSub =
  Subject(PubSubMessage)

// ============================================================================
// Actor Handler
// ============================================================================

fn handle_message(
  state: PubSubState,
  message: PubSubMessage,
) -> actor.Next(PubSubState, PubSubMessage) {
  case message {
    SubscribeTo(reply_to, topic, subscriber) -> {
      let current_subs = case dict.get(state.topics, topic) {
        Ok(subs) -> subs
        Error(_) -> []
      }
      let new_topics =
        dict.insert(state.topics, topic, [subscriber, ..current_subs])
      actor.send(reply_to, Nil)
      actor.continue(PubSubState(topics: new_topics))
    }

    UnsubscribeFrom(reply_to, topic, subscriber) -> {
      case dict.get(state.topics, topic) {
        Ok(subs) -> {
          let filtered = list.filter(subs, fn(s) { s != subscriber })
          let new_topics = dict.insert(state.topics, topic, filtered)
          actor.send(reply_to, Ok(Nil))
          actor.continue(PubSubState(topics: new_topics))
        }
        Error(_) -> {
          actor.send(reply_to, Error("Topic not found: " <> topic))
          actor.continue(state)
        }
      }
    }

    BroadcastMsg(topic, message) -> {
      case dict.get(state.topics, topic) {
        Ok(subs) -> {
          list.each(subs, fn(sub) { process.send(sub, message) })
        }
        Error(_) -> Nil
      }
      actor.continue(state)
    }

    ListTopics(reply_to) -> {
      let topics = dict.keys(state.topics)
      actor.send(reply_to, topics)
      actor.continue(state)
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new PubSub instance.
pub fn start() -> Result(PubSub, actor.StartError) {
  let initial_state = PubSubState(topics: dict.new())

  case
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(reason) -> Error(reason)
  }
}

/// Subscribe a subject to a topic.
///
/// The subscriber subject will receive messages broadcast to this topic.
/// Create the subject with `process.new_subject()` in the subscribing process.
pub fn subscribe(
  pubsub: PubSub,
  topic: String,
  subscriber: Subject(String),
) -> Nil {
  actor.call(pubsub, waiting: 5000, sending: SubscribeTo(_, topic, subscriber))
}

/// Unsubscribe from a topic.
pub fn unsubscribe(
  pubsub: PubSub,
  topic: String,
  subscriber: Subject(String),
) -> Result(Nil, String) {
  actor.call(pubsub, waiting: 5000, sending: UnsubscribeFrom(
    _,
    topic,
    subscriber,
  ))
}

/// Broadcast a message to all subscribers of a topic.
pub fn broadcast(pubsub: PubSub, topic: String, message: String) -> Nil {
  actor.send(pubsub, BroadcastMsg(topic: topic, message: message))
}

/// List all topics with subscribers.
pub fn list_topics(pubsub: PubSub) -> List(String) {
  actor.call(pubsub, waiting: 5000, sending: ListTopics)
}
