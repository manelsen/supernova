#!/bin/sh
if [ -n "$FAKE_RECORD_DIR" ]; then
  mkdir -p "$FAKE_RECORD_DIR"
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "--system-prompt-file" ]; then
      cp "$arg" "$FAKE_RECORD_DIR/system.md"
    fi
    prev="$arg"
  done
  printf '%s' "$*" > "$FAKE_RECORD_DIR/args.txt"
fi
cat "$FAKE_FIXTURE"
