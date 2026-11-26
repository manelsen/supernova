#!/bin/bash
# run.sh engine mode n  -> prints step lines with container memory
name=sn-medida-$1-$2
docker rm -f $name >/dev/null 2>&1
docker run -d --name $name --runtime=runsc --cap-drop ALL --security-opt no-new-privileges \
  --shm-size 1g -m 4g --cpus 2 --pids-limit 512 \
  -v "$(git rev-parse --show-toplevel)"/computador/resolv.conf:/etc/resolv.conf:ro \
  sn-medida node /opt/m/measure.mjs $1 $2 $3 >/dev/null
seen=-1
while true; do
  logs=$(docker logs $name 2>&1)
  last=$(echo "$logs" | grep -c '^READY')
  if [ "$last" -gt $((seen+1)) ] || { [ "$last" -gt 0 ] && [ $((last-1)) -gt $seen ]; }; then
    sleep 5
    mem=$(docker stats --no-stream --format '{{.MemUsage}}' $name)
    line=$(echo "$logs" | grep '^READY' | sed -n "${last}p")
    echo "$1/$2 | $mem | $line"
    seen=$((last-1))
  fi
  if echo "$logs" | grep -q '^DONE'; then echo "$logs" | grep DONE; break; fi
  if ! docker ps -q -f name=$name | grep -q .; then echo "EXITED"; docker logs --tail 5 $name; break; fi
  sleep 1
done
docker rm -f $name >/dev/null 2>&1
