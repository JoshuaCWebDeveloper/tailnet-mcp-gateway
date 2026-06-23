# syntax=docker/dockerfile:1

ARG GO_VERSION=1.26.2

FROM golang:${GO_VERSION}-bookworm AS tunnel-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src/tunnel-client
RUN git clone --depth=1 https://github.com/openai/tunnel-client.git .
RUN go build -o /out/tunnel-client ./cmd/client

FROM golang:${GO_VERSION}-bookworm AS terminal-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    make \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src/terminal_mcp
RUN git clone --depth=1 https://github.com/iris-networks/terminal_mcp.git .
RUN make build
RUN test -x ./mcp-terminal-server
RUN cp ./mcp-terminal-server /out/mcp-terminal-server

FROM debian:bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV MCP_SHELL=/bin/bash
ENV MCP_COMMAND_TIMEOUT=300

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    gnupg \
    iproute2 \
    iputils-ping \
    jq \
    openssh-client \
    procps \
    tini \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://tailscale.com/install.sh | sh

COPY --from=tunnel-builder /out/tunnel-client /usr/local/bin/tunnel-client
COPY --from=terminal-builder /out/mcp-terminal-server /usr/local/bin/mcp-terminal-server
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/tunnel-client /usr/local/bin/mcp-terminal-server /usr/local/bin/entrypoint.sh \
 && mkdir -p /work /root/.ssh /var/lib/tailscale /var/run/tailscale /var/log/tunnel-client

WORKDIR /work

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
