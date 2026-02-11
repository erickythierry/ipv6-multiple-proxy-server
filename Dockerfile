# ============================================
# IPv6 Multiple Proxy Server - Dockerfile
# Multi-stage build: compila 3proxy no stage 1,
# copia apenas o binário para a imagem final.
# ============================================

# ---- Stage 1: Build 3proxy from source ----
FROM ubuntu:22.04 AS builder

ARG PROXY_VERSION=0.9.5

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      make g++ wget ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN wget -q "https://github.com/3proxy/3proxy/archive/refs/tags/${PROXY_VERSION}.tar.gz" \
      -O /tmp/3proxy.tar.gz && \
    tar -xf /tmp/3proxy.tar.gz -C /tmp && \
    cd /tmp/3proxy-${PROXY_VERSION} && \
    make -f Makefile.Linux

# ---- Stage 2: Runtime image (leve) ----
FROM ubuntu:22.04

LABEL maintainer="erickythierry" \
      description="IPv6 Multiple Proxy Server using 3proxy" \
      version="5.0"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      iproute2 \
      iputils-ping \
      curl \
      procps && \
    rm -rf /var/lib/apt/lists/*

# Copiar binário do 3proxy do stage de build
ARG PROXY_VERSION=0.9.5
COPY --from=builder /tmp/3proxy-${PROXY_VERSION}/bin/3proxy /usr/local/bin/3proxy
RUN chmod +x /usr/local/bin/3proxy

# Copiar entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Variáveis de ambiente com defaults
ENV PROXY_USER="" \
    PROXY_PASS="" \
    START_PORT="30000" \
    NET_INTERFACE="" \
    PROXY_TYPE="socks5" \
    ALLOWED_HOSTS="" \
    DENIED_HOSTS=""

ENTRYPOINT ["/entrypoint.sh"]
