//// Tests for the Blackboard module

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import supernova/core/blackboard.{
  Entry, ValueDeleted, ValueSet, delete, entry_has_ttl, entry_ttl, entry_value,
  get, list, set, set_with_ttl, start, stop, subscribe, subscribe_to_key,
  unsubscribe,
}

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Lifecycle Tests
// ============================================================================

pub fn start_creates_blackboard_test() {
  let result = start()
  let assert Ok(blackboard) = result

  // Verify we can interact with it
  set(blackboard, "test_key", "test_value")
  let value = get(blackboard, "test_key")
  let assert Some(entry) = value
  let assert "test_value" = entry_value(entry)

  stop(blackboard)
}

pub fn stop_gracefully_shuts_down_test() {
  let assert Ok(blackboard) = start()
  stop(blackboard)
  // Blackboard is now stopped
}

// ============================================================================
// CRUD Operations Tests
// ============================================================================

pub fn set_and_get_value_test() {
  let assert Ok(blackboard) = start()

  set(blackboard, "key1", "value1")

  let result = get(blackboard, "key1")
  let assert Some(entry) = result
  let assert "value1" = entry_value(entry)

  stop(blackboard)
}

pub fn get_nonexistent_key_returns_none_test() {
  let assert Ok(blackboard) = start()

  let result = get(blackboard, "nonexistent")
  let assert None = result

  stop(blackboard)
}

pub fn set_overwrites_existing_value_test() {
  let assert Ok(blackboard) = start()

  set(blackboard, "key1", "value1")
  set(blackboard, "key1", "value2")

  let result = get(blackboard, "key1")
  let assert Some(entry) = result
  let assert "value2" = entry_value(entry)

  stop(blackboard)
}

pub fn delete_existing_key_test() {
  let assert Ok(blackboard) = start()

  set(blackboard, "key1", "value1")
  let deleted = delete(blackboard, "key1")

  let assert True = deleted

  let result = get(blackboard, "key1")
  let assert None = result

  stop(blackboard)
}

pub fn delete_nonexistent_key_returns_false_test() {
  let assert Ok(blackboard) = start()

  let deleted = delete(blackboard, "nonexistent")
  let assert False = deleted

  stop(blackboard)
}

pub fn list_keys_returns_all_keys_test() {
  let assert Ok(blackboard) = start()

  set(blackboard, "key1", "value1")
  set(blackboard, "key2", "value2")
  set(blackboard, "key3", "value3")

  let keys = list(blackboard)
  let assert 3 = list.length(keys)

  stop(blackboard)
}

pub fn list_empty_blackboard_returns_empty_list_test() {
  let assert Ok(blackboard) = start()

  let keys = list(blackboard)
  let assert [] = keys

  stop(blackboard)
}

// ============================================================================
// TTL Tests
// ============================================================================

pub fn set_with_ttl_creates_entry_with_ttl_test() {
  let assert Ok(blackboard) = start()

  set_with_ttl(blackboard, "key1", "value1", 1000)

  let result = get(blackboard, "key1")
  let assert Some(entry) = result

  let assert "value1" = entry_value(entry)
  let assert True = entry_has_ttl(entry)
  let assert Some(1000) = entry_ttl(entry)

  stop(blackboard)
}

pub fn set_without_ttl_has_no_ttl_test() {
  let assert Ok(blackboard) = start()

  set(blackboard, "key1", "value1")

  let result = get(blackboard, "key1")
  let assert Some(entry) = result

  let assert False = entry_has_ttl(entry)
  let assert None = entry_ttl(entry)

  stop(blackboard)
}

// ============================================================================
// Subscription Tests
// ============================================================================

pub fn subscribe_receives_value_set_notification_test() {
  let assert Ok(blackboard) = start()

  let subscriber = process.new_subject()
  let _subscription_id = subscribe(blackboard, subscriber)

  set(blackboard, "key1", "value1")

  let notification = process.receive(subscriber, 1000)
  let assert Ok(ValueSet("key1", "value1")) = notification

  stop(blackboard)
}

pub fn subscribe_receives_value_deleted_notification_test() {
  let assert Ok(blackboard) = start()

  set(blackboard, "key1", "value1")

  let subscriber = process.new_subject()
  let _subscription_id = subscribe(blackboard, subscriber)

  let _ = delete(blackboard, "key1")

  let notification = process.receive(subscriber, 1000)
  let assert Ok(ValueDeleted("key1")) = notification

  stop(blackboard)
}

pub fn subscribe_to_key_filters_notifications_test() {
  let assert Ok(blackboard) = start()

  let subscriber = process.new_subject()
  let _subscription_id = subscribe_to_key(blackboard, subscriber, "key1")

  // Set a different key - should not receive notification
  set(blackboard, "key2", "value2")

  let result = process.receive(subscriber, 100)
  let assert Error(Nil) = result

  // Set the subscribed key - should receive notification
  set(blackboard, "key1", "value1")

  let notification = process.receive(subscriber, 1000)
  let assert Ok(ValueSet("key1", "value1")) = notification

  stop(blackboard)
}

pub fn unsubscribe_removes_subscription_test() {
  let assert Ok(blackboard) = start()

  let subscriber = process.new_subject()
  let subscription_id = subscribe(blackboard, subscriber)

  let unsubscribed = unsubscribe(blackboard, subscription_id)
  let assert True = unsubscribed

  // Set a value - should not receive notification
  set(blackboard, "key1", "value1")

  let result = process.receive(subscriber, 100)
  let assert Error(Nil) = result

  stop(blackboard)
}

pub fn unsubscribe_nonexistent_returns_false_test() {
  let assert Ok(blackboard) = start()

  let unsubscribed = unsubscribe(blackboard, 9999)
  let assert False = unsubscribed

  stop(blackboard)
}

pub fn multiple_subscribers_all_receive_notifications_test() {
  let assert Ok(blackboard) = start()

  let subscriber1 = process.new_subject()
  let subscriber2 = process.new_subject()

  let _id1 = subscribe(blackboard, subscriber1)
  let _id2 = subscribe(blackboard, subscriber2)

  set(blackboard, "key1", "value1")

  let notification1 = process.receive(subscriber1, 1000)
  let notification2 = process.receive(subscriber2, 1000)

  let assert Ok(ValueSet("key1", "value1")) = notification1
  let assert Ok(ValueSet("key1", "value1")) = notification2

  stop(blackboard)
}

// ============================================================================
// Entry Helper Tests
// ============================================================================

pub fn entry_value_extracts_value_test() {
  let entry = Entry(value: "test", ttl: None, created_at: 0)
  let assert "test" = entry_value(entry)
}

pub fn entry_ttl_extracts_ttl_test() {
  let entry_with_ttl = Entry(value: "test", ttl: Some(1000), created_at: 0)
  let entry_without_ttl = Entry(value: "test", ttl: None, created_at: 0)

  let assert Some(1000) = entry_ttl(entry_with_ttl)
  let assert None = entry_ttl(entry_without_ttl)
}

pub fn entry_has_ttl_checks_ttl_presence_test() {
  let entry_with_ttl = Entry(value: "test", ttl: Some(1000), created_at: 0)
  let entry_without_ttl = Entry(value: "test", ttl: None, created_at: 0)

  let assert True = entry_has_ttl(entry_with_ttl)
  let assert False = entry_has_ttl(entry_without_ttl)
}
