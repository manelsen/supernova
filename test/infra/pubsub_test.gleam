//// Tests for PubSub module.

import gleam/erlang/process
import gleeunit/should
import supernova/infra/pubsub

pub fn start_pubsub_test() {
  let result = pubsub.start()
  result
  |> should.be_ok
}

pub fn subscribe_and_broadcast_test() {
  let assert Ok(ps) = pubsub.start()

  let subject = process.new_subject()
  pubsub.subscribe(ps, "test-topic", subject)

  pubsub.broadcast(ps, "test-topic", "hello")

  let received = process.receive(subject, within: 1000)
  received
  |> should.equal(Ok("hello"))
}

pub fn broadcast_to_multiple_subscribers_test() {
  let assert Ok(ps) = pubsub.start()

  let sub1 = process.new_subject()
  let sub2 = process.new_subject()
  pubsub.subscribe(ps, "topic", sub1)
  pubsub.subscribe(ps, "topic", sub2)

  pubsub.broadcast(ps, "topic", "msg")

  process.receive(sub1, within: 1000)
  |> should.equal(Ok("msg"))

  process.receive(sub2, within: 1000)
  |> should.equal(Ok("msg"))
}

pub fn no_cross_topic_delivery_test() {
  let assert Ok(ps) = pubsub.start()

  let sub_a = process.new_subject()
  let sub_b = process.new_subject()
  pubsub.subscribe(ps, "topic-a", sub_a)
  pubsub.subscribe(ps, "topic-b", sub_b)

  pubsub.broadcast(ps, "topic-a", "for-a")

  process.receive(sub_a, within: 1000)
  |> should.equal(Ok("for-a"))

  // sub_b should NOT receive
  process.receive(sub_b, within: 500)
  |> should.equal(Error(Nil))
}

pub fn unsubscribe_test() {
  let assert Ok(ps) = pubsub.start()

  let subject = process.new_subject()
  pubsub.subscribe(ps, "topic", subject)
  let assert Ok(Nil) = pubsub.unsubscribe(ps, "topic", subject)

  pubsub.broadcast(ps, "topic", "should-not-receive")

  process.receive(subject, within: 500)
  |> should.equal(Error(Nil))
}

pub fn list_topics_test() {
  let assert Ok(ps) = pubsub.start()

  let sub = process.new_subject()
  pubsub.subscribe(ps, "topic-a", sub)
  pubsub.subscribe(ps, "topic-b", sub)

  let topics = pubsub.list_topics(ps)
  topics
  |> should.equal(["topic-a", "topic-b"])
}
