#!/usr/bin/env bash
# PRD-K, K-05: the computers' way out, with real Docker and the real images.
# Two people's computers, made by the dispatcher on internal networks, with
# the proxy as the only way out. Checks, inside the computers:
#   - the shell reaches the factory list (pip, npm) and nothing else;
#   - a site Ana approved opens for Ana's shell and not for Bia's;
#   - there is no way out around the proxy;
#   - the shell (user sh) finds the proxy credential nowhere;
#   - the browser (user svc) goes out with it.
# Needs Docker, internet, and gVisor unless DESPACHANTE_RUNTIME=runc. Builds
# the three images. Leaves nothing behind.
set -euo pipefail
cd "$(dirname "$0")/.."

tag="sn-saida-$$"
lado="${tag}-supernova"
fora="${tag}-fora"
token="t-$$"
ana=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
bia=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
image="supernova-computador:${tag}"

cleanup() {
  docker rm -f "${tag}-cli" "${tag}-desp" "${tag}-saida" "computador-$ana" "computador-$bia" >/dev/null 2>&1 || true
  docker network rm "computador-$ana" "computador-$bia" "$lado" "$fora" >/dev/null 2>&1 || true
  docker volume rm "computador-$ana" "computador-$bia" >/dev/null 2>&1 || true
  docker image rm "$image" >/dev/null 2>&1 || true
}
[[ -n "${KEEP:-}" ]] || trap cleanup EXIT

docker build -q -t "$image" computador >/dev/null
docker build -q -t sn-despachante despachante >/dev/null
docker build -q -t sn-saida saida >/dev/null

docker network create "$lado" >/dev/null
docker network create "$fora" >/dev/null

docker create --name "${tag}-saida" --network "$fora" --network-alias saida \
  --cap-drop ALL --read-only \
  -e SAIDA_TOKEN=adm -e SAIDA_CREDENCIAL=mestre sn-saida >/dev/null
docker network connect --alias saida "$lado" "${tag}-saida"
docker start "${tag}-saida" >/dev/null

docker run -d --name "${tag}-desp" --network "$lado" --network-alias despachante \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD/computador/resolv.conf:/etc/computador/resolv.conf:ro" \
  -e DESPACHANTE_TOKEN="$token" -e COMPUTADOR_TOKEN=interno \
  -e DESPACHANTE_IMAGEM="$image" -e DESPACHANTE_RUNTIME="${DESPACHANTE_RUNTIME:-runsc}" \
  -e DESPACHANTE_SAIDA="${tag}-saida" -e DESPACHANTE_SAIDA_ADMIN=http://saida:7072 \
  -e SAIDA_TOKEN=adm -e SAIDA_CREDENCIAL=mestre \
  sn-despachante >/dev/null

docker run -d --name "${tag}-cli" --network "$lado" node:24.13.0-alpine3.23 sleep 900 >/dev/null

call() { # path json -> answer
  docker exec "${tag}-cli" node -e "
    fetch('http://despachante:7071$1',{method:'POST',headers:{authorization:'Bearer $token','content-type':'application/json'},body:JSON.stringify($2),signal:AbortSignal.timeout(240000)})
      .then(r=>r.text()).then(t=>console.log(t)).catch(e=>console.log('FAIL',e.message))"
}
shell() { # person command -> stdout + stderr of the command
  call "/v1/pessoas/$1/run" "{op:'exec',command:$(printf '%s' "$2" | node -e 'process.stdout.write(JSON.stringify(require("fs").readFileSync(0,"utf8")))'),timeout_s:120}" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);console.log(a.stdout+a.stderr+"exit="+a.exit_code)}catch{console.log(s)}})'
}

for _ in $(seq 1 30); do
  [[ "$(call /v1/estado '{}' 2>/dev/null)" != FAIL* ]] && break
  sleep 1
done

fail=0
check() { # description expected actual
  if [[ "$3" == *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1: got $(echo "$3" | tail -c 300)"; fail=1; fi
}

call "/v1/pessoas/$ana/sites" "{sites:['example.com']}" >/dev/null
check "Ana's shell reaches a site she approved" "200" "$(shell "$ana" "curl -sS -o /dev/null -w '%{http_code}' https://example.com/")"
check "Ana's shell does not reach a site off the list" "exit=" "$(shell "$ana" "curl -sS -o /dev/null -w '%{http_code}' https://www.wikipedia.org/ && echo SAIU")"
lacks_out=$(shell "$ana" "curl -sS -o /dev/null -w '%{http_code}' https://www.wikipedia.org/ && echo SAIU")
[[ "$lacks_out" != *SAIU* ]] && echo "ok   (and nothing came back from it)" || { echo "FAIL Ana's shell reached wikipedia"; fail=1; }
check "pip works" "Saved" "$(shell "$ana" "python3 -m pip download --no-deps --no-cache-dir -d /tmp/pip six 2>&1 | tail -2")"
check "npm works" "1.3.0" "$(shell "$ana" "npm view left-pad version 2>&1")"
check "no way out around the proxy" "SEM-SAIDA" "$(shell "$ana" "curl -sS --noproxy '*' --max-time 8 -o /dev/null https://example.com/ || echo SEM-SAIDA")"
secret_hunt="env; cat /proc/1/environ /proc/*/environ 2>/dev/null | tr '\\0' '\\n'; grep -rs SAIDA_SENHA /home /tmp /run 2>/dev/null; echo FIM"
hunt=$(shell "$ana" "$secret_hunt")
check "the shell searched" "FIM" "$hunt"
if [[ "$hunt" == *SAIDA_SENHA* ]]; then echo "FAIL the shell found the proxy credential"; fail=1; else echo "ok   the shell finds the proxy credential nowhere"; fi
check "the shell runs as sh" "1002" "$(shell "$ana" "id -u")"
check "Bia's shell does not reach Ana's approved site" "exit=" "$(shell "$bia" "curl -sS -o /dev/null https://example.com/ && echo SAIU")"
bia_out=$(shell "$bia" "curl -sS -o /dev/null https://example.com/ && echo SAIU")
[[ "$bia_out" != *SAIU* ]] && echo "ok   (Bia got nothing from it)" || { echo "FAIL Bia's shell reached Ana's site"; fail=1; }
check "the browser goes out with the credential" '"status":200' "$(call "/v1/pessoas/$bia/run" "{op:'goto',url:'https://www.wikipedia.org/'}")"

exit $fail
