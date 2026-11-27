//// PRD-K, K-I6 and section 3.3: the shape of docker-compose.yml. Supernova
//// never has the Docker socket and is not on the computers' network; only
//// the dispatcher has the socket.

import gleam/list
import gleam/string
import gleeunit/should
import yay

fn compose() -> yay.Node {
  let assert Ok([yay.Document(root)]) = yay.parse_file("docker-compose.yml")
  root
}

fn services() -> List(#(String, yay.Node)) {
  let assert Ok(yay.NodeMap(pairs)) = yay.select_sugar(compose(), "services")
  list.map(pairs, fn(pair) {
    let assert #(yay.NodeStr(name), node) = pair
    #(name, node)
  })
}

fn strings(node: yay.Node, key: String) -> List(String) {
  case yay.select_sugar(node, key) {
    Ok(yay.NodeSeq(items)) ->
      list.filter_map(items, fn(item) {
        case item {
          yay.NodeStr(text) -> Ok(text)
          _ -> Error(Nil)
        }
      })
    Ok(yay.NodeMap(pairs)) ->
      list.filter_map(pairs, fn(pair) {
        case pair {
          #(yay.NodeStr(text), _) -> Ok(text)
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

fn mounts_socket(service: yay.Node) -> Bool {
  strings(service, "volumes")
  |> list.any(fn(volume) { string.contains(volume, "docker.sock") })
}

pub fn supernova_never_has_the_docker_socket_test() {
  let assert Ok(supernova) = list.key_find(services(), "supernova")
  mounts_socket(supernova) |> should.be_false
}

pub fn only_the_dispatcher_has_the_docker_socket_test() {
  services()
  |> list.filter(fn(service) { mounts_socket(service.1) })
  |> list.map(fn(service) { service.0 })
  |> should.equal(["despachante"])
}

pub fn supernova_is_not_on_the_computers_network_test() {
  let assert Ok(supernova) = list.key_find(services(), "supernova")
  strings(supernova, "networks") |> should.equal(["default"])
}

pub fn only_the_search_engine_goes_out_through_the_old_network_test() {
  // People's computers have networks of their own, made by the dispatcher
  // (K-04); the fixed network is SearXNG's way out. Nothing else is on it.
  services()
  |> list.filter(fn(service) {
    list.contains(strings(service.1, "networks"), "computador_net")
  })
  |> list.map(fn(service) { service.0 })
  |> should.equal(["searxng"])
}

pub fn only_the_proxy_is_on_its_way_out_test() {
  services()
  |> list.filter(fn(service) {
    list.contains(strings(service.1, "networks"), "saida_net")
  })
  |> list.map(fn(service) { service.0 })
  |> should.equal(["saida"])
  // And it holds no Docker socket.
  let assert Ok(saida) = list.key_find(services(), "saida")
  mounts_socket(saida) |> should.be_false
}

pub fn the_computer_image_is_built_and_never_run_here_test() {
  let assert Ok(pc) = list.key_find(services(), "computador")
  yay.select_sugar(pc, "deploy.replicas") |> should.equal(Ok(yay.NodeInt(0)))
}

pub fn the_tunnel_holds_nothing_but_its_config_test() {
  let assert Ok(tunnel) = list.key_find(services(), "cloudflared")
  mounts_socket(tunnel) |> should.be_false
  strings(tunnel, "networks") |> should.equal(["default"])
  strings(tunnel, "volumes")
  |> list.all(fn(volume) {
    string.starts_with(volume, "./cloudflared/")
    && string.ends_with(volume, ":ro")
  })
  |> should.be_true
}

// Qwen 4, A1: the process with every secret runs without privileges.
pub fn supernova_runs_without_privileges_test() {
  let assert Ok(supernova) = list.key_find(services(), "supernova")
  strings(supernova, "cap_drop") |> should.equal(["ALL"])
  strings(supernova, "cap_add") |> should.equal([])
  strings(supernova, "security_opt")
  |> should.equal(["no-new-privileges:true"])
  let assert Ok(dockerfile) = read("Dockerfile")
  string.contains(dockerfile, "\nUSER supernova\n") |> should.be_true
}

// Qwen 4, M6: Grafana never gets Supernova's bot token, not even as a
// fallback for the alerts' own.
pub fn grafana_never_gets_supernovas_bot_token_test() {
  let assert Ok(grafana) = list.key_find(services(), "grafana")
  let assert Ok(yay.NodeMap(env)) = yay.select_sugar(grafana, "environment")
  list.any(env, fn(pair) {
    case pair {
      #(_, yay.NodeStr(value)) ->
        string.contains(value, "SUPERNOVA_TELEGRAM_TOKEN")
      _ -> False
    }
  })
  |> should.be_false
}

// Qwen 4, M2: `COPY . .` never takes a secret into the image.
pub fn the_image_leaves_the_secrets_out_test() {
  let assert Ok(ignore) = read(".dockerignore")
  let lines = string.split(ignore, "\n") |> list.map(string.trim)
  [
    ".env", "supernova.yaml", "cloudflared/credentials.json", "*.pem", "*.key",
    "data", "workspaces",
  ]
  |> list.filter(fn(entry) { !list.contains(lines, entry) })
  |> should.equal([])
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read(path: String) -> Result(String, String)

// Qwen 4, B6: no two services take the same port of the host, so every
// profile can run together (GOWA and Grafana both wanted 3000).
pub fn no_two_services_share_a_host_port_test() {
  let host_ports =
    services()
    |> list.flat_map(fn(service) { strings(service.1, "ports") })
    |> list.map(fn(port) {
      case string.split(port, ":") {
        [address, host, _] -> address <> ":" <> host
        [host, _] -> host
        _ -> port
      }
    })
  list.length(host_ports) |> should.equal(list.length(list.unique(host_ports)))
}
