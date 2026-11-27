FROM erlang:28.5.0.8-alpine

ARG GLEAM_VERSION=1.19.2
ARG TARGETARCH

RUN apk add --no-cache curl tar rebar3

# Animated stickers are split into frames with Pillow before the reader sees
# them (priv/media/sticker_frames.py, PRD-A A-10): Gemini sees only the first
# frame of an animated WebP.
RUN apk add --no-cache python3 py3-pillow

RUN case "$TARGETARCH" in \
  amd64) GLEAM_ARCH="x86_64-unknown-linux-musl" ;; \
  arm64) GLEAM_ARCH="aarch64-unknown-linux-musl" ;; \
  "") GLEAM_ARCH="x86_64-unknown-linux-musl" ;; \
  *) echo "Unsupported architecture: $TARGETARCH" && exit 1 ;; \
  esac \
  && curl -fsSL \
    -o /tmp/gleam.tar.gz \
    "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-${GLEAM_ARCH}.tar.gz" \
  && tar -xzf /tmp/gleam.tar.gz -C /usr/local/bin gleam \
  && chmod +x /usr/local/bin/gleam

WORKDIR /app

COPY gleam.toml manifest.toml ./
RUN gleam deps download

# Compile the dependencies in their own layer, with a placeholder module, so a
# change to src/ or priv/ only recompiles Supernova itself.
RUN mkdir -p src \
 && echo 'pub fn main() { Nil }' > src/supernova.gleam \
 && gleam build \
 && rm -rf src build/dev/erlang/supernova

COPY . .
RUN gleam build

# Patch hackney FFI to increase recv_timeout to 120s (30s for Telegram poller)
# The FFI source lives in build/packages, beam gets compiled to build/dev/erlang
# The build fails if the patch did not apply (Qwen 4, B8): a new gleam_hackney
# that changes the text would otherwise bring back the default timeout.
RUN sed -i "s/{with_body, true}/{with_body, true}, {recv_timeout, 120000}/" /app/build/packages/gleam_hackney/src/gleam_hackney_ffi.erl \
 && grep -q "{recv_timeout, 120000}" /app/build/packages/gleam_hackney/src/gleam_hackney_ffi.erl \
 && erlc -o /app/build/dev/erlang/gleam_hackney/ebin /app/build/packages/gleam_hackney/src/gleam_hackney_ffi.erl \
 && erlc -o /app/build/packages/gleam_hackney/src /app/build/packages/gleam_hackney/src/gleam_hackney_ffi.erl

# Not root (Qwen 4, A1): the BEAM holds every secret, so it runs as an
# unprivileged user that owns only what it writes: /data (the volume) and
# workspaces/. A new volume takes this ownership from the image; an old one,
# made when Supernova ran as root, is handed over once (DEPLOY.md).
RUN addgroup -S -g 10001 supernova \
 && adduser -S -D -H -u 10001 -G supernova supernova \
 && mkdir -p /data /app/workspaces \
 && chown supernova:supernova /data /app/workspaces
USER supernova

# Run the BEAM itself as PID 1, not under `gleam run`: as PID 1, `gleam run`
# ignores the SIGTERM of `docker stop`, and the container was killed after the
# grace period without draining its chat lanes. The BEAM handles SIGTERM, and
# Supernova turns it into its own shutdown (supernova_signal_ffi).
CMD ["sh", "-c", "exec erl -pa build/dev/erlang/*/ebin -noshell -eval 'supernova@@main:run(supernova)'"]
