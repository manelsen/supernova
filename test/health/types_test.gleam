import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/health/types as health

pub fn main() {
  gleeunit.main()
}

pub fn health_status_to_json_test() {
  let json =
    health.health_status_to_json(health.HealthStatus(
      status: "ok",
      uptime_seconds: 42,
    ))

  string.contains(json, "\"status\":\"ok\"") |> should.equal(True)
  string.contains(json, "\"uptime_seconds\":42") |> should.equal(True)
}

pub fn readiness_status_to_json_with_channels_test() {
  let json =
    health.readiness_status_to_json(
      health.ReadinessStatus(status: "ok", uptime_seconds: 99, channels_ready: [
        health.ChannelStatus(name: "discord", ready: True, error: None),
        health.ChannelStatus(
          name: "telegram",
          ready: False,
          error: Some("token missing"),
        ),
      ]),
    )

  string.contains(json, "\"channels_ready\"") |> should.equal(True)
  string.contains(json, "\"name\":\"discord\"") |> should.equal(True)
  string.contains(json, "\"ready\":true") |> should.equal(True)
  string.contains(json, "\"error\":null") |> should.equal(True)
  string.contains(json, "\"name\":\"telegram\"") |> should.equal(True)
  string.contains(json, "\"ready\":false") |> should.equal(True)
  string.contains(json, "\"error\":\"token missing\"") |> should.equal(True)
}
