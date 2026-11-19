#!/bin/sh
# Atalho para o harness: valida variáveis e executáveis antes de rodar.
set -eu

CONFIG="${HARNESS_CONFIG:-harness.yaml}"

if [ ! -f "$CONFIG" ]; then
  echo "missing $CONFIG (copy harness.yaml.example)" >&2
  exit 1
fi

key_var=$(sed -n 's/^[[:space:]]*api_key_env:[[:space:]]*["]*\([^" ]*\).*/\1/p' "$CONFIG" | head -1)
if [ -n "${key_var:-}" ]; then
  eval "key_value=\${$key_var:-}"
  if [ -z "${key_value:-}" ]; then
    echo "missing environment variable: $key_var" >&2
    exit 1
  fi
fi

for exe in omp claude; do
  path=$(sed -n "s/^[[:space:]]*executable:[[:space:]]*//p" "$CONFIG" | grep -E "(^|/)$exe$" | head -1)
  # A bare name (claude) is looked up in PATH; a path must be executable.
  if [ -n "${path:-}" ] && ! command -v "$path" >/dev/null 2>&1; then
    echo "executable not found: $path" >&2
    exit 1
  fi
done

exec gleam run -m supernova/harness/run -- --config "$CONFIG" "$@"
