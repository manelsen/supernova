#!/usr/bin/env bash
# PRD-K, K-09: the tunnel publishes only the people's screens. Asks
# cloudflared itself which rule each URL matches, with our config.
set -euo pipefail
cd "$(dirname "$0")/.."
image="cloudflare/cloudflared:2025.11.1@sha256:89ee50efb1e9cb2ae30281a8a404fed95eb8f02f0a972617526f8c5b417acae2"
rule() {
  docker run --rm -v "$PWD/cloudflared/config.yml:/etc/cloudflared/config.yml:ro" "$image" \
    tunnel --config /etc/cloudflared/config.yml ingress rule "$1" 2>&1 | grep -o 'service: .*'
}
fail=0
expect() { # url service
  got=$(rule "$1")
  if [[ "$got" == "service: $2" ]]; then echo "ok   $1 -> $2"; else echo "FAIL $1: $got"; fail=1; fi
}
docker run --rm -v "$PWD/cloudflared/config.yml:/etc/cloudflared/config.yml:ro" "$image" \
  tunnel --config /etc/cloudflared/config.yml ingress validate >/dev/null
expect "https://tela.example.org/tela/abcdefabcdefabcdefabcdefabcdefab/" "http://despachante:7073"
expect "https://tela.example.org/tela/abcdefabcdefabcdefabcdefabcdefab/websockify" "http://despachante:7073"
expect "https://tela.example.org/" "http_status:404"
expect "https://tela.example.org/v1/estado" "http_status:404"
expect "https://tela.example.org/v1/pessoas/0123456789abcdef/run" "http_status:404"
expect "https://tela.example.org/health" "http_status:404"
expect "https://tela.example.org/telas/x/" "http_status:404"
expect "https://tela.example.org/tela/" "http_status:404"
exit $fail
