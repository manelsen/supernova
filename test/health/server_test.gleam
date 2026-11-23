import gleam/http/response
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/health/server
import supernova/health/types as health_types
import supernova/metrics/actor as metrics_actor

pub fn main() {
  gleeunit.main()
}

pub fn start_and_stop_health_server_test() {
  let assert Ok(metrics) = metrics_actor.start()
  let health_server = server.start(0, metrics, fn() { [] })

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

fn channel(name: String, ready: Bool, error) -> health_types.ChannelStatus {
  health_types.ChannelStatus(name: name, ready: ready, error: error)
}

pub fn ready_reports_channel_state_from_callback_test() {
  let start_ms = server.current_timestamp() - 2000
  let #(code, json) =
    server.ready_response(start_ms, fn() {
      [channel("discord", True, None), channel("slack", True, None)]
    })

  code |> should.equal(200)
  string.contains(json, "\"status\":\"ok\"") |> should.equal(True)
  string.contains(json, "\"name\":\"discord\"") |> should.equal(True)
  string.contains(json, "\"name\":\"slack\"") |> should.equal(True)
  string.contains(json, "\"ready\":true") |> should.equal(True)
}

pub fn ready_is_503_when_a_channel_is_down_test() {
  let start_ms = server.current_timestamp()
  let #(code, json) =
    server.ready_response(start_ms, fn() {
      [
        channel("discord", True, None),
        channel("telegram", False, Some("telegram api error 401")),
      ]
    })

  code |> should.equal(503)
  string.contains(json, "\"status\":\"degraded\"") |> should.equal(True)
  string.contains(json, "telegram api error 401") |> should.equal(True)
}

pub fn metrics_response_has_a_content_type_prometheus_accepts_test() {
  let assert Ok(metrics) = metrics_actor.start()
  metrics_actor.inc_counter(metrics, "channel_messages_total", [
    #("channel", "telegram"),
    #("kind", "message"),
  ])
  let resp = server.metrics_response(metrics)

  resp.status |> should.equal(200)
  response.get_header(resp, "content-type")
  |> should.equal(Ok("text/plain; version=0.0.4"))
}
