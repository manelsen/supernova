//// Health check HTTP server.
//// Serves /health, /health/live, /health/ready, and /metrics endpoints
//// for Kubernetes liveness/readiness probes and Docker healthchecks.

///
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import mist.{type Connection, type ResponseData}

import supernova/health/types as health_types
import supernova/metrics/actor as metrics_actor

pub type HealthServer {
  HealthServer(start_time_ms: Int, port: Int, metrics: metrics_actor.Metrics)
}

@external(erlang, "supernova_ledger_ffi", "current_timestamp")
fn current_timestamp() -> Int

fn uptime_seconds(start_time_ms: Int) -> Int {
  let now_ms = current_timestamp()
  { now_ms - start_time_ms } / 1000
}

fn handle_request(
  req: request.Request(Connection),
  metrics: metrics_actor.Metrics,
) -> response.Response(ResponseData) {
  case request.path_segments(req) {
    ["health"] -> handle_health(req)
    ["health", "live"] -> handle_live(req)
    ["health", "ready"] -> handle_ready(req)
    ["metrics"] -> handle_metrics(req, metrics)
    _ -> handle_not_found()
  }
}

fn handle_health(
  req: request.Request(Connection),
) -> response.Response(ResponseData) {
  let _ = req
  let start_ms = current_timestamp()
  let status =
    health_types.HealthStatus(
      status: "ok",
      uptime_seconds: uptime_seconds(start_ms),
    )
  let body = health_types.health_status_to_json(status)
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
  |> response.set_header("content-type", "application/json")
}

fn handle_live(
  req: request.Request(Connection),
) -> response.Response(ResponseData) {
  let _ = req
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
}

fn handle_ready(
  req: request.Request(Connection),
) -> response.Response(ResponseData) {
  let _ = req
  let start_ms = current_timestamp()
  let status =
    health_types.ReadinessStatus(
      status: "ok",
      uptime_seconds: uptime_seconds(start_ms),
      channels_ready: [],
    )
  let body = health_types.readiness_status_to_json(status)
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
  |> response.set_header("content-type", "application/json")
}

fn handle_metrics(
  req: request.Request(Connection),
  metrics: metrics_actor.Metrics,
) -> response.Response(ResponseData) {
  let _ = req
  let body = metrics_actor.get_metrics(metrics)
  response.new(200)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
  |> response.set_header("content-type", "text/plain; version=0.0.4")
}

fn handle_not_found() -> response.Response(ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found")))
}

pub fn start(port: Int, metrics: metrics_actor.Metrics) -> HealthServer {
  let start_time_ms = current_timestamp()

  let assert Ok(_) =
    fn(req: request.Request(Connection)) -> response.Response(ResponseData) {
      handle_request(req, metrics)
    }
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(port)
    |> mist.start

  io.println("Health server listening on port " <> int.to_string(port))

  HealthServer(start_time_ms: start_time_ms, port: port, metrics: metrics)
}

pub fn stop(server: HealthServer) -> Nil {
  let _ = server
  Nil
}
