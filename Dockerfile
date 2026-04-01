FROM erlang:28-alpine

ARG GLEAM_VERSION=1.15.0
ARG TARGETARCH

RUN apk add --no-cache curl tar rebar3

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

COPY . .
RUN gleam build

CMD ["gleam", "run"]