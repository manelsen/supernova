//// Health check types for Kubernetes/Docker Compose probes.
////
//// Provides /health (basic), /health/live (liveness), and /health/ready (readiness).

import gleam/json
import gleam/option.{type Option, None, Some}

pub type HealthStatus {
  HealthStatus(status: String, uptime_seconds: Int)
}

pub type ReadinessStatus {
  ReadinessStatus(
    status: String,
    uptime_seconds: Int,
    channels_ready: List(ChannelStatus),
  )
}

pub type ChannelStatus {
  ChannelStatus(name: String, ready: Bool, error: Option(String))
}

pub fn health_status_to_json(status: HealthStatus) -> String {
  json.object([
    #("status", json.string(status.status)),
    #("uptime_seconds", json.int(status.uptime_seconds)),
  ])
  |> json.to_string
}

fn channel_status_to_json(ch: ChannelStatus) -> json.Json {
  let error_json = case ch.error {
    Some(e) -> json.string(e)
    None -> json.null()
  }
  json.object([
    #("name", json.string(ch.name)),
    #("ready", json.bool(ch.ready)),
    #("error", error_json),
  ])
}

pub fn readiness_status_to_json(status: ReadinessStatus) -> String {
  let channels_json =
    status.channels_ready
    |> json.array(channel_status_to_json)

  json.object([
    #("status", json.string(status.status)),
    #("uptime_seconds", json.int(status.uptime_seconds)),
    #("channels_ready", channels_json),
  ])
  |> json.to_string
}
