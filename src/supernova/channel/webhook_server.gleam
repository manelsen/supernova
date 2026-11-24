//// Webhook server — one HTTP listener for every channel that receives by
//// webhook (PRD-C, C-02).
////
//// Each channel registers its route, `POST /webhook/<channel>`, with what
//// only it knows: how to verify a request (a signature, a token) and how
//// to read the body. The server knows no channel by name. A verified
//// message goes to `dispatch` (the channel kit: durable inbox, chat lane,
//// router) before the answer, so a 200 means the message is kept.

import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/otp/actor
import mist
import supernova/channel/port

/// What a route made of a verified body.
pub type Outcome {
  /// Messages to answer.
  Deliver(List(port.ChannelInbound))
  /// An event the channel took care of itself (an alert, a status).
  Handled
  /// The body is not what the channel sends.
  Malformed
}

pub type Route {
  Route(
    channel: String,
    /// True when the request really comes from the channel. Headers are
    /// lowercase.
    verify: fn(List(#(String, String)), BitArray) -> Bool,
    translate: fn(BitArray) -> Outcome,
    dispatch: fn(port.ChannelInbound) -> Nil,
  )
}

/// Largest body accepted, in bytes.
pub const max_body_bytes = 1_000_000

/// The status for one request. Messages are dispatched before it returns.
pub fn respond(
  routes: List(Route),
  method: String,
  path: List(String),
  headers: List(#(String, String)),
  body: BitArray,
) -> Int {
  case path {
    ["webhook", channel] ->
      case list.find(routes, fn(route) { route.channel == channel }) {
        Error(Nil) -> 404
        Ok(route) ->
          case method {
            "POST" ->
              case route.verify(headers, body) {
                False -> 401
                True ->
                  case route.translate(body) {
                    Deliver(inbound) -> {
                      list.each(inbound, route.dispatch)
                      200
                    }
                    Handled -> 200
                    Malformed -> 400
                  }
              }
            _ -> 405
          }
      }
    _ -> 404
  }
}

/// `sha256=<hex>` HMAC-SHA256 of the body with the shared secret, compared
/// in constant time (the `X-Hub-Signature-256` convention). An empty secret
/// verifies nothing.
@external(erlang, "supernova_webhook_ffi", "hub_signature_valid")
pub fn hub_signature_valid(
  secret: String,
  body: BitArray,
  header: String,
) -> Bool

// --- Registered routes -------------------------------------------------------

const routes_key = "supernova_webhook_routes"

@external(erlang, "supernova_global_ffi", "global_put")
fn put_routes(key: String, routes: Dict(String, Route)) -> Nil

@external(erlang, "supernova_tool_limits_ffi", "get")
fn get_routes(key: String) -> Result(Dict(String, Route), Nil)

fn current() -> Dict(String, Route) {
  case get_routes(routes_key) {
    Ok(routes) -> routes
    Error(Nil) -> dict.new()
  }
}

/// Add (or replace) the route of a channel.
pub fn register(route: Route) -> Nil {
  put_routes(routes_key, dict.insert(current(), route.channel, route))
}

pub fn unregister(channel: String) -> Nil {
  put_routes(routes_key, dict.delete(current(), channel))
}

/// The registered routes.
pub fn routes() -> List(Route) {
  dict.values(current())
}

// --- Listener ----------------------------------------------------------------

pub opaque type Server {
  Server(pid: process.Pid)
}

/// Listen on `bind:port`; routes are looked up per request, so channels may
/// register before or after.
pub fn start(bind: String, port: Int) -> Result(Server, String) {
  let started =
    fn(req) { serve(req) }
    |> mist.new
    |> mist.bind(bind)
    |> mist.port(port)
    |> mist.start
  case started {
    Ok(actor.Started(pid: pid, ..)) -> Ok(Server(pid))
    Error(_) -> Error("webhook server failed to listen on port " <> int(port))
  }
}

const server_key = "supernova_webhook_server"

@external(erlang, "supernova_global_ffi", "global_put")
fn put_server(key: String, server: Result(Server, Nil)) -> Nil

@external(erlang, "supernova_tool_limits_ffi", "get")
fn get_server(key: String) -> Result(Result(Server, Nil), Nil)

/// Start the listener the running instance uses (boot).
pub fn start_global(bind: String, port: Int) -> Result(Nil, String) {
  case start(bind, port) {
    Ok(server) -> {
      put_server(server_key, Ok(server))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

/// Stop the listener started by `start_global`, if any (shutdown).
pub fn stop_global() -> Nil {
  case get_server(server_key) {
    Ok(Ok(server)) -> {
      stop(server)
      put_server(server_key, Error(Nil))
    }
    _ -> Nil
  }
}

pub fn stop(server: Server) -> Nil {
  process.unlink(server.pid)
  process.kill(server.pid)
}

fn serve(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let status = case mist.read_body(req, max_body_bytes) {
    Error(mist.ExcessBody) -> 413
    Error(mist.MalformedBody) -> 400
    Ok(read) ->
      respond(
        routes(),
        http.method_to_string(req.method),
        request.path_segments(req),
        req.headers,
        read.body,
      )
  }
  response.new(status)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

@external(erlang, "erlang", "integer_to_binary")
fn int(value: Int) -> String
