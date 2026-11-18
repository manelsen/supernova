import gleam/erlang/process
import gleeunit/should
import supernova/core/safe_call

pub fn dead_actor_is_unavailable_test() {
  let parent = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let dead = process.new_subject()
      process.send(parent, dead)
    })
  let assert Ok(dead) = process.receive(parent, within: 1000)
  process.sleep(20)
  safe_call.call(dead, 100, fn(reply) { reply })
  |> should.equal(Error(safe_call.Unavailable))
}

pub fn unresponsive_actor_times_out_test() {
  let parent = process.new_subject()
  let blocker =
    process.spawn_unlinked(fn() {
      let silent = process.new_subject()
      process.send(parent, silent)
      process.sleep(5000)
    })
  let assert Ok(silent) = process.receive(parent, within: 1000)
  safe_call.call(silent, 50, fn(reply) { reply })
  |> should.equal(Error(safe_call.Timeout))
  process.kill(blocker)
}
