#!/bin/sh
if [ -n "$FAKE_RECORD_DIR" ]; then
  mkdir -p "$FAKE_RECORD_DIR"
  prev=""
  for arg in "$@"; do
    case "$arg" in
      @*) cp "${arg#@}" "$FAKE_RECORD_DIR/transcript.md" ;;
    esac
    if [ "$prev" = "--system-prompt" ]; then
      cp "$arg" "$FAKE_RECORD_DIR/system.md"
    fi
    prev="$arg"
  done
fi
cat "$FAKE_FIXTURE"
