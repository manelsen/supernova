#!/usr/bin/env bash
# PRD-K, K-04: from one shared computer to one computer per person.
#
# The shared computer kept each person's files in
# /home/pwuser/pessoas/<hash>/ of one volume. Each person now has a volume
# of their own, computador-<hash>, made the way the dispatcher makes it
# (same labels), with their folder at the same path. Run it once, after
# `docker compose up -d --build` and before the first person uses the new
# computers. It copies; the old volume is left as it was, to delete by hand
# once you are satisfied.
#
#   scripts/migrar-computadores-por-pessoa.sh [old volume] [computer image]
#
# Not moved: the shared ~/trabalho (the admins' shell work area) and the
# shared browser profile. Each person's computer starts with its own.
set -euo pipefail

old="${1:-$(docker volume ls --format '{{.Name}}' | grep '_computador_home$' | head -1)}"
image="${2:-supernova-computador:latest}"
if [[ -z "$old" ]] || ! docker volume inspect "$old" >/dev/null 2>&1; then
  echo "no old volume (looked for *_computador_home); nothing to migrate" >&2
  exit 0
fi
uid=$(docker run --rm --entrypoint id "$image" -u)
gid=$(docker run --rm --entrypoint id "$image" -g)

people=$(docker run --rm -v "$old":/old:ro alpine:3.20 \
  sh -c 'ls /old/pessoas 2>/dev/null' | grep -E '^[0-9a-f]{16}$' || true)
if [[ -z "$people" ]]; then
  echo "no people's folders in $old; nothing to migrate"
  exit 0
fi

for person in $people; do
  volume="computador-$person"
  if docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "skip $person: $volume already exists"
    continue
  fi
  docker volume create \
    --label supernova.despachante=1 --label "supernova.pessoa=$person" \
    "$volume" >/dev/null
  # The home the computer image expects (a new empty volume would get it
  # from the image; a filled one does not), then the person's folder.
  docker run --rm -v "$old":/old:ro -v "$volume":/new alpine:3.20 sh -c "
    mkdir -p /new/pessoas /new/trabalho /new/.navegador &&
    cp -a /old/pessoas/$person /new/pessoas/ &&
    chown -R $uid:$gid /new"
  echo "moved $person to $volume"
done
echo "done. The old volume $old is untouched; delete it when you are satisfied:"
echo "  docker volume rm $old"
