#!/usr/bin/env bash
# Fetch Gleam package documentation from HexDocs for RAG ingestion.
# Usage: ./scripts/fetch_docs.sh

set -e

DOCS_DIR="docs/rag"
mkdir -p "$DOCS_DIR"

PACKAGES=(
  "gleam_stdlib"
  "gleam_otp"
  "wisp"
  "mist"
  "yay"
  "envoy"
  "gleam_json"
  "gleam_http"
  "gleam_hackney"
  "gleam_time"
  "pog"
)

echo "Fetching Gleam package documentation for RAG..."

for pkg in "${PACKAGES[@]}"; do
  echo "  Fetching $pkg..."
  
  # Try to get the latest version from Hex
  VERSION=$(curl -s "https://hex.pm/api/packages/$pkg" 2>/dev/null | grep -o '"latest_version":"[^"]*' | cut -d'"' -f4 || echo "latest")
  
  if [ "$VERSION" = "latest" ] || [ -z "$VERSION" ]; then
    VERSION="latest"
  fi
  
  URL="https://hexdocs.pm/$pkg/$VERSION/index.html"
  OUTPUT="$DOCS_DIR/${pkg}.html"
  
  # Download with fallback
  if curl -sL --max-time 30 "$URL" -o "$OUTPUT" 2>/dev/null; then
    echo "    ✓ $pkg ($VERSION) -> $OUTPUT"
  else
    echo "    ✗ Failed to fetch $pkg"
  fi
done

# Also fetch Gleam language documentation
echo "Fetching Gleam language documentation..."
curl -sL --max-time 30 "https://gleam.run/documentation/" -o "$DOCS_DIR/gleam_language.html" 2>/dev/null && \
  echo "    ✓ gleam_language.html" || echo "    ✗ Failed to fetch Gleam docs"

# Fetch Erlang/OTP overview for BEAM context
echo "Fetching Erlang/OTP overview..."
curl -sL --max-time 30 "https://www.erlang.org/doc/index.html" -o "$DOCS_DIR/erlang_otp.html" 2>/dev/null && \
  echo "    ✓ erlang_otp.html" || echo "    ✗ Failed to fetch Erlang docs"

echo ""
echo "Done. Documentation saved to $DOCS_DIR/"
ls -la "$DOCS_DIR/" | grep -v "^total" | grep -v "^d"
