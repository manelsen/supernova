#!/usr/bin/env bash
# PRD-K, K-03: with real Docker, the network shape of docker-compose.yml.
# Supernova's network holds "supernova" and the dispatcher; the computers'
# network holds the dispatcher and a computer. Checks:
#   - the computer reaches neither Supernova nor the dispatcher;
#   - Supernova reaches the dispatcher, and through it the computer.
# Leaves nothing behind. Needs Docker and the despachante image built
# (docker build -t sn-despachante despachante/).
set -euo pipefail

tag="sn-rede-$$"
lado="${tag}-supernova"
rede="${tag}-computador"
token="t-$$"
cleanup() {
  docker rm -f "${tag}-sn" "${tag}-desp" "${tag}-pc" >/dev/null 2>&1 || true
  docker network rm "$lado" "$rede" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$lado" >/dev/null
docker network create "$rede" >/dev/null

# "Supernova": a small HTTP server on its own network only.
docker run -d --name "${tag}-sn" --network "$lado" --network-alias supernova \
  node:24.13.0-alpine3.23 node -e \
  "require('http').createServer((q,s)=>s.end('supernova')).listen(8080)" >/dev/null

# The computer: a small HTTP server on the computers' network only, playing
# the computer service (answers /v1/run).
docker run -d --name "${tag}-pc" --network "$rede" --network-alias computador \
  node:24.13.0-alpine3.23 node -e \
  "require('http').createServer((q,s)=>{s.setHeader('content-type','application/json');s.end(JSON.stringify({ok:true,auth:q.headers.authorization}))}).listen(7070)" >/dev/null

# The dispatcher, on both networks, with the socket, as in the compose file.
docker create --name "${tag}-desp" --network "$lado" --network-alias despachante \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e DESPACHANTE_TOKEN="$token" -e COMPUTADOR_TOKEN=interno \
  -e DESPACHANTE_IMAGEM=node:24.13.0-alpine3.23 -e DESPACHANTE_REDE="$rede" \
  -e DESPACHANTE_COMPUTADOR_URL=http://computador:7070 \
  sn-despachante >/dev/null
docker network connect "$rede" "${tag}-desp"
docker start "${tag}-desp" >/dev/null

desp_lado=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$lado\").IPAddress}}" "${tag}-desp")
desp_rede=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$rede\").IPAddress}}" "${tag}-desp")
sn_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$lado\").IPAddress}}" "${tag}-sn")

probe() { # container url -> prints the answer or FAIL
  docker exec "$1" node -e "
    fetch('$2',{method:'$3',headers:{authorization:'Bearer $token','content-type':'application/json'},body:'$3'==='POST'?'{}':undefined,signal:AbortSignal.timeout(3000)})
      .then(r=>r.text()).then(t=>console.log(t)).catch(()=>console.log('FAIL'))"
}

# Wait until the dispatcher answers Supernova and the computer is up (at
# most 30 s), instead of a fixed pause.
for _ in $(seq 1 30); do
  if [[ "$(probe "${tag}-sn" "http://despachante:7071/health" GET)" == *'"ok":true'* ]] \
    && docker exec "${tag}-pc" node -e "fetch('http://127.0.0.1:7070/').then(()=>process.exit(0)).catch(()=>process.exit(1))" 2>/dev/null; then
    break
  fi
  sleep 1
done
fail=0
check() { # description expected actual
  if [[ "$3" == *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1: got $3"; fail=1; fi
}

check "Supernova reaches the dispatcher" '"ok":true' "$(probe "${tag}-sn" "http://despachante:7071/v1/estado" GET)"
check "Supernova reaches the computer through the dispatcher" '"auth":"Bearer interno"' "$(probe "${tag}-sn" "http://despachante:7071/v1/run" POST)"
check "Supernova does not reach the computer directly" FAIL "$(probe "${tag}-sn" "http://computador:7070/v1/run" POST)"
check "the computer does not reach Supernova by name" FAIL "$(probe "${tag}-pc" "http://supernova:8080/" GET)"
check "the computer does not reach Supernova by address" FAIL "$(probe "${tag}-pc" "http://${sn_ip}:8080/" GET)"
check "the computer does not reach the dispatcher on its network" FAIL "$(probe "${tag}-pc" "http://${desp_rede}:7071/health" GET)"
check "the computer does not reach the dispatcher on Supernova's side" FAIL "$(probe "${tag}-pc" "http://${desp_lado}:7071/health" GET)"

exit $fail
