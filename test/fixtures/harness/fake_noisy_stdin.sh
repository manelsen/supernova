#!/bin/sh
# Behaves like a real CLI that reads stdin until EOF and logs to stderr.
cat > /dev/null
echo "warning: something noisy on stderr" >&2
cat "$FAKE_FIXTURE"
