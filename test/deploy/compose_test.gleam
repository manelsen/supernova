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

pub fn the_computers_network_holds_no_secret_holder_test() {
  // On the computers' network: the computer, the dispatcher (listening only
  // on Supernova's side) and the search engine. Nothing else.
  services()
  |> list.filter(fn(service) {
    list.contains(strings(service.1, "networks"), "computador_net")
  })
  |> list.map(fn(service) { service.0 })
  |> list.sort(string.compare)
  |> should.equal(["computador", "despachante", "searxng"])
}
