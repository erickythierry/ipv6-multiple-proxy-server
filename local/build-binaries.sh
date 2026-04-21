#!/bin/bash
set -euo pipefail

# =============================================
# Builda o 3proxy para linux/amd64 e linux/arm64
# usando containers ubuntu:22.04 (com QEMU para
# o arm64). Os binários são gravados em:
#   local/bin/linux-amd64/3proxy
#   local/bin/linux-arm64/3proxy
#
# Requer: docker, e QEMU registrado no binfmt
# (para arm64 em host amd64):
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
# =============================================

PROXY_VERSION="${PROXY_VERSION:-0.9.5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/bin"

BUILD_CMD='set -eux
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends make g++ wget ca-certificates >/dev/null
  wget -q "https://github.com/3proxy/3proxy/archive/refs/tags/'"${PROXY_VERSION}"'.tar.gz" -O /tmp/3proxy.tar.gz
  tar -xf /tmp/3proxy.tar.gz -C /tmp
  cd /tmp/3proxy-'"${PROXY_VERSION}"'
  make -f Makefile.Linux
  cp bin/3proxy /out/3proxy
  chmod +x /out/3proxy
  strip /out/3proxy || true'

for PLATFORM in linux/amd64 linux/arm64; do
  ARCH="${PLATFORM##*/}"
  OUT_ARCH_DIR="${OUT_DIR}/linux-${ARCH}"
  mkdir -p "$OUT_ARCH_DIR"
  echo ">>> Building 3proxy ${PROXY_VERSION} for ${PLATFORM}..."
  docker run --rm \
    --platform "${PLATFORM}" \
    -v "${OUT_ARCH_DIR}:/out" \
    ubuntu:22.04 \
    bash -c "$BUILD_CMD"
  echo ">>> Binary: ${OUT_ARCH_DIR}/3proxy"
  file "${OUT_ARCH_DIR}/3proxy" || true
done

echo ""
echo "Done. Binaries:"
ls -la "${OUT_DIR}"/linux-*/3proxy
