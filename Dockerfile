# syntax=docker/dockerfile:1.7
#
# buzz-pair-relay image built from peteroleary/hvgapp source.
#
# The upstream image (ghcr.io/block/buzz) ships the stock relay, whose ingest
# allowlist rejects Board event kinds. This Dockerfile builds the same binaries
# from the hvgapp fork instead, so the deployed relay matches the desktop app.
#
# Railway auto-deploys this service on every push to this repo's main branch.
# To deploy a newer hvgapp commit, bump HVGAPP_SHA below and push — the SHA is
# the deploy pin, and each bump is an auditable deploy in this repo's history.

ARG HVGAPP_SHA=4ecf111fe5b78506afda7719c5bf3fe1fb99a41b

ARG RUST_VERSION=1.95
ARG NODE_VERSION=24
ARG DEBIAN_VERSION=bookworm

# ─── Stage 0: fetch pinned hvgapp source ────────────────────────────────────
# NOTE: ADD auto-extracts LOCAL tarballs only — a remote URL is just
# downloaded. Extract explicitly. The SHA-pinned URL busts the Docker layer
# cache exactly when the deploy pin changes.
FROM alpine:3.20 AS src
ARG HVGAPP_SHA
ADD https://github.com/pheartkeys/hvgapp/archive/${HVGAPP_SHA}.tar.gz /tmp/hvgapp.tar.gz
RUN tar -xzf /tmp/hvgapp.tar.gz -C /tmp && mv /tmp/hvgapp-${HVGAPP_SHA} /src

# ─── Stage 1: cargo-chef base ───────────────────────────────────────────────
FROM rust:${RUST_VERSION}-${DEBIAN_VERSION} AS chef
RUN cargo install cargo-chef --locked --version 0.1.71
WORKDIR /build

# ─── Stage 2: plan dependency graph ─────────────────────────────────────────
FROM chef AS planner
COPY --from=src /src .
RUN cargo chef prepare --recipe-path recipe.json

# ─── Stage 3: cook dependencies, then build the binaries ────────────────────
FROM chef AS builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libssl-dev \
        ca-certificates \
        git \
    && rm -rf /var/lib/apt/lists/*
COPY --from=planner /build/recipe.json recipe.json
# Cook the full workspace recipe — relay deps include workspace siblings, so
# scoping to -p buzz-relay misses transitive deps and re-builds them later.
RUN cargo chef cook --release --recipe-path recipe.json
COPY --from=src /src .
RUN cargo build --release --locked -p buzz-relay --bin buzz-relay \
                                   -p buzz-admin --bin buzz-admin \
                                   -p buzz-pair-relay --bin buzz-pair-relay \
    && strip target/release/buzz-relay \
    && strip target/release/buzz-admin \
    && strip target/release/buzz-pair-relay

# ─── Stage 4: web bundle (pnpm + vite) ──────────────────────────────────────
# The pair relay serves the invite landing page from this bundle.
FROM node:${NODE_VERSION}-${DEBIAN_VERSION}-slim AS web-builder
WORKDIR /build
RUN corepack enable
COPY --from=src /src/package.json /src/pnpm-lock.yaml /src/pnpm-workspace.yaml ./
COPY --from=src /src/patches/ patches/
COPY --from=src /src/web/package.json web/
COPY --from=src /src/admin-web/package.json admin-web/
RUN pnpm install --frozen-lockfile --filter buzz-web --filter buzz-admin-web
COPY --from=src /src/web/ web/
COPY --from=src /src/admin-web/ admin-web/
RUN pnpm -C web build && pnpm -C admin-web build

# ─── Stage 5: runtime ───────────────────────────────────────────────────────
FROM debian:${DEBIAN_VERSION}-slim AS runtime

LABEL org.opencontainers.image.title="Buzz Pair Relay (hvgapp)" \
      org.opencontainers.image.description="buzz-pair-relay built from peteroleary/hvgapp" \
      org.opencontainers.image.source="https://github.com/peteroleary/buzz-pair-relay-image" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gosu \
        openssl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1000 buzz \
    && useradd  --system --uid 1000 --gid 1000 --home-dir /var/lib/buzz \
                --create-home --shell /usr/sbin/nologin buzz

COPY --from=web-builder /build/web/dist                 /srv/buzz/web
COPY --from=web-builder /build/admin-web/dist           /srv/buzz/admin-web

ENV BUZZ_WEB_DIR=/srv/buzz/web \
    BUZZ_ADMIN_WEB_DIR=/srv/buzz/admin-web

# 3000: app (WS + REST)  ·  8080: /_liveness, /_readiness  ·  9102: /metrics
EXPOSE 3000 8080 9102

RUN mkdir -p /data/git && chown buzz:buzz /data/git

COPY --from=builder /build/target/release/buzz-relay      /usr/local/bin/buzz-relay
COPY --from=builder /build/target/release/buzz-admin      /usr/local/bin/buzz-admin
COPY --from=builder /build/target/release/buzz-pair-relay /usr/local/bin/buzz-pair-relay
COPY --chmod=0755 entrypoint.sh /usr/local/bin/buzz-entrypoint

# Start as root, not buzz: a Railway volume mounted at /data/git arrives
# root-owned, and only root can reclaim it. The entrypoint chowns the data
# dirs and drops to buzz via gosu before exec'ing the relay binary.
USER root
WORKDIR /var/lib/buzz

# BUZZ_BINARY selects the binary (default: buzz-pair-relay) so one image can
# back both the pair-relay sidecar and the main relay service.
ENTRYPOINT ["/usr/local/bin/buzz-entrypoint"]
