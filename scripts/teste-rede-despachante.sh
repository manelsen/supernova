#!/usr/bin/env bash
# PRD-K, K-03 and K-04: with real Docker, the network shape the dispatcher
# builds. Supernova's network holds "supernova" and the dispatcher; the
# dispatcher makes two people's computers, each on a network of its own.
# Checks:
#   - Supernova reaches each computer only through the dispatcher;
#   - a computer reaches neither Supernova, nor the dispatcher, nor the
#     other person's computer (K-I4);
#   - /v1/apagar leaves no container, volume or network behind.
# Leaves nothing behind. Needs Docker and the despachante image built
# (docker build -t sn-despachante despachante/). Runs the computers on runc
# unless DESPACHANTE_RUNTIME says otherwise (CI has no gVisor).
set -euo pipefail

tag="sn-rede-$$"
lado="${tag}-supernova"
token="t-$$"
image="${tag}-pc:latest"
ana=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
bia=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

cleanup() {
  docker rm -f "${tag}-sn" "${tag}-desp" "${tag}-saida" "computador-$ana" "computador-$bia" >/dev/null 2>&1 || true
  docker network rm "computador-$ana" "computador-$bia" "$lado" >/dev/null 2>&1 || true
  docker volume rm "computador-$ana" "computador-$bia" >/dev/null 2>&1 || true
  docker image rm -f "$image" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A stand-in for the computer image: answers /health and /v1/run.
docker build -q -t "$image" - >/dev/null <<'EOF'
FROM node:24.13.0-alpine3.23
CMD ["node", "-e", "require('http').createServer((q,s)=>{s.setHeader('content-type','application/json');s.end(JSON.stringify({ok:true,auth:q.headers.authorization,host:require('os').hostname()}))}).listen(7070)"]
EOF

docker network create "$lado" >/dev/null

# The proxy, as in the compose file (its own way out is not needed here).
docker build -q -t sn-saida saida >/dev/null
docker run -d --name "${tag}-saida" --network "$lado" --network-alias saida \
  --cap-drop ALL --read-only -e SAIDA_TOKEN=adm -e SAIDA_CREDENCIAL=mestre sn-saida >/dev/null

# "Supernova": a small HTTP server on its own network only.
docker run -d --name "${tag}-sn" --network "$lado" --network-alias supernova \
  node:24.13.0-alpine3.23 node -e \
  "require('http').createServer((q,s)=>s.end('supernova')).listen(8080)" >/dev/null

# The dispatcher, on Supernova's network, with the socket, as in the compose file.
docker run -d --name "${tag}-desp" --network "$lado" --network-alias despachante \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(cd "$(dirname "$0")/.." && pwd)/computador/resolv.conf:/etc/computador/resolv.conf:ro" \
  -e DESPACHANTE_TOKEN="$token" -e COMPUTADOR_TOKEN=interno \
  -e DESPACHANTE_IMAGEM="$image" -e DESPACHANTE_RUNTIME="${DESPACHANTE_RUNTIME:-runc}" \
  -e DESPACHANTE_SAIDA="${tag}-saida" -e DESPACHANTE_SAIDA_ADMIN=http://saida:7072 \
  -e SAIDA_TOKEN=adm -e SAIDA_CREDENCIAL=mestre \
  sn-despachante >/dev/null

probe() { # container url method -> prints the answer or FAIL
  docker exec "$1" node -e "
    fetch('$2',{method:'$3',headers:{authorization:'Bearer $token','content-type':'application/json'},body:'$3'==='POST'?'{}':undefined,signal:AbortSignal.timeout(${4:-3000})})
      .then(r=>r.text()).then(t=>console.log(t)).catch(()=>console.log('FAIL'))"
}

for _ in $(seq 1 30); do
  [[ "$(probe "${tag}-sn" "http://despachante:7071/health" GET)" == *'"ok":true'* ]] && break
  sleep 1
done

fail=0
check() { # description expected actual
  if [[ "$3" == *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1: got $3"; fail=1; fi
}
lacks() { # description unexpected actual
  if [[ "$3" != *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1: got $3"; fail=1; fi
}

check "Supernova reaches Ana's computer through the dispatcher" '"auth":"Bearer interno"' \
  "$(probe "${tag}-sn" "http://despachante:7071/v1/pessoas/$ana/run" POST 90000)"
check "Supernova reaches Bia's computer through the dispatcher" '"auth":"Bearer interno"' \
  "$(probe "${tag}-sn" "http://despachante:7071/v1/pessoas/$bia/run" POST 90000)"

ip_of() { docker inspect -f "{{(index .NetworkSettings.Networks \"$2\").IPAddress}}" "$1"; }
ana_ip=$(ip_of "computador-$ana" "computador-$ana")
bia_ip=$(ip_of "computador-$bia" "computador-$bia")
sn_ip=$(ip_of "${tag}-sn" "$lado")
desp_lado=$(ip_of "${tag}-desp" "$lado")
desp_ana=$(ip_of "${tag}-desp" "computador-$ana")

check "Ana's computer has no way out but the proxy" FAIL "$(probe "computador-$ana" "https://example.com/" GET 8000)"
saida_ip=$(ip_of "${tag}-saida" "computador-$ana")
check "the proxy is on Ana's network at its fixed address" ".0.2" "$saida_ip"
check "Ana's computer does not reach the proxy's admin door" FAIL "$(probe "computador-$ana" "http://$saida_ip:7072/health" GET)"
check "Supernova does not reach Ana's computer directly" FAIL "$(probe "${tag}-sn" "http://$ana_ip:7070/" GET)"
check "Ana's computer does not reach Bia's computer" FAIL "$(probe "computador-$ana" "http://$bia_ip:7070/" GET)"
check "Ana's computer does not reach Bia's computer by name" FAIL "$(probe "computador-$ana" "http://computador-$bia:7070/" GET)"
check "Ana's computer does not reach Supernova by name" FAIL "$(probe "computador-$ana" "http://supernova:8080/" GET)"
check "Ana's computer does not reach Supernova by address" FAIL "$(probe "computador-$ana" "http://$sn_ip:8080/" GET)"
check "Ana's computer does not reach the dispatcher on its network" FAIL "$(probe "computador-$ana" "http://$desp_ana:7071/health" GET)"
check "Ana's computer does not reach the dispatcher on Supernova's side" FAIL "$(probe "computador-$ana" "http://$desp_lado:7071/health" GET)"

check "forgetting Ana deletes her computer" '"apagado":true' \
  "$(docker exec "${tag}-sn" node -e "
    fetch('http://despachante:7071/v1/apagar',{method:'POST',headers:{authorization:'Bearer $token','content-type':'application/json'},body:JSON.stringify({pessoa:'$ana'})})
      .then(r=>r.text()).then(t=>console.log(t)).catch(()=>console.log('FAIL'))")"
lacks "no container of Ana's left" "computador-$ana" "$(docker ps -a --format '{{.Names}}')"
lacks "no volume of Ana's left" "computador-$ana" "$(docker volume ls --format '{{.Name}}')"
lacks "no network of Ana's left" "computador-$ana" "$(docker network ls --format '{{.Name}}')"
check "Bia's computer is still there" "computador-$bia" "$(docker ps --format '{{.Names}}')"

exit $fail
