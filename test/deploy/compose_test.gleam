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
