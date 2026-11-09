import gleeunit
import gleeunit/should
import supernova/health/server
import supernova/metrics/actor as metrics_actor

pub fn main() {
  gleeunit.main()
}

pub fn start_and_stop_health_server_test() {
  let assert Ok(metrics) = metrics_actor.start()
  let health_server = server.start(0, metrics, fn() { ["discord", "telegram"] })

  health_server.port |> should.equal(0)
  server.stop(health_server) |> should.equal(Nil)
}
