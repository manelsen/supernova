import gleam/string
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

pub fn health_reports_real_uptime_from_start_time_test() {
  let five_seconds_ago = server.current_timestamp() - 5000
  let uptime = server.uptime_seconds(five_seconds_ago)
  should.equal(uptime >= 5, True)

  let json = server.render_health_json(five_seconds_ago)
  string.contains(json, "\"status\":\"ok\"") |> should.equal(True)
  string.contains(json, "\"uptime_seconds\":5") |> should.equal(True)
}

pub fn ready_reports_active_channels_from_callback_test() {
  let start_ms = server.current_timestamp() - 2000
  let json = server.render_ready_json(start_ms, fn() { ["discord", "slack"] })

  string.contains(json, "\"status\":\"ok\"") |> should.equal(True)
  string.contains(json, "\"name\":\"discord\"") |> should.equal(True)
  string.contains(json, "\"name\":\"slack\"") |> should.equal(True)
  string.contains(json, "\"ready\":true") |> should.equal(True)
}
