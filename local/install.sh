#!/bin/bash
set -euo pipefail

# =============================================
# IPv6 Multiple Proxy Server - Instalador Local
# =============================================
# Por padrão, instala o binário 3proxy PRÉ-BUILDADO
# que acompanha o repositório (linux/amd64 e
# linux/arm64). Se o binário para a arquitetura do
# host não existir, faz fallback e compila do fonte.
#
# Uso:
#   sudo ./install.sh             # pré-buildado, fallback p/ compilar
#   sudo BUILD_FROM_SOURCE=1 ./install.sh  # força compilação
# =============================================

PROXY_VERSION="${PROXY_VERSION:-0.9.5}"
PREFIX="${PREFIX:-/usr/local}"
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-0}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
log_info() { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_err()  { echo -e "${RED}[ERRO]${NC} $1"; }
log_step() { echo -e "${CYAN}[>>>>]${NC} $1"; }

if [ "$(id -u)" -ne 0 ]; then
  log_err "Este script precisa ser executado como root (use sudo)."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === Detectar arquitetura do host ===
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64)  ARCH_DIR="linux-amd64" ;;
  aarch64|arm64) ARCH_DIR="linux-arm64" ;;
  *)             ARCH_DIR="" ;;
esac

PREBUILT="${SCRIPT_DIR}/bin/${ARCH_DIR}/3proxy"

install_runtime_deps() {
  log_step "Instalando dependências de runtime..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y --no-install-recommends iproute2 iputils-ping curl procps
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y iproute iputils curl procps-ng
  elif command -v yum >/dev/null 2>&1; then
    yum install -y iproute iputils curl procps-ng
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm iproute2 iputils curl procps-ng
  else
    log_warn "Gerenciador de pacotes não reconhecido. Garanta que iproute2/curl estejam instalados."
  fi
}

install_build_deps() {
  log_step "Instalando dependências de build..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends make g++ wget ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y make gcc-c++ wget ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y make gcc-c++ wget ca-certificates
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm make gcc wget ca-certificates
  else
    log_err "Gerenciador de pacotes não reconhecido; instale manualmente: make, g++, wget."
    exit 1
  fi
}

build_from_source() {
  install_build_deps
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' RETURN
  log_step "Baixando 3proxy ${PROXY_VERSION}..."
  wget -q "https://github.com/3proxy/3proxy/archive/refs/tags/${PROXY_VERSION}.tar.gz" \
    -O "${TMP_DIR}/3proxy.tar.gz"
  tar -xf "${TMP_DIR}/3proxy.tar.gz" -C "${TMP_DIR}"
  log_step "Compilando 3proxy..."
  ( cd "${TMP_DIR}/3proxy-${PROXY_VERSION}" && make -f Makefile.Linux )
  install -m 0755 "${TMP_DIR}/3proxy-${PROXY_VERSION}/bin/3proxy" "${PREFIX}/bin/3proxy"
}

install_runtime_deps

if [ "$BUILD_FROM_SOURCE" = "1" ]; then
  log_info "BUILD_FROM_SOURCE=1 — compilando do fonte."
  build_from_source
elif [ -n "$ARCH_DIR" ] && [ -x "$PREBUILT" ]; then
  log_step "Usando binário pré-buildado para ${ARCH_DIR} (${HOST_ARCH})..."
  install -m 0755 "$PREBUILT" "${PREFIX}/bin/3proxy"
else
  if [ -z "$ARCH_DIR" ]; then
    log_warn "Arquitetura '${HOST_ARCH}' sem binário pré-buildado."
  else
    log_warn "Binário pré-buildado não encontrado em ${PREBUILT}."
  fi
  log_info "Fallback: compilando do fonte..."
  build_from_source
fi

log_info "Binário instalado: ${PREFIX}/bin/3proxy"

log_step "Instalando runner em ${PREFIX}/bin/ipv6-proxy-run..."
install -m 0755 "${SCRIPT_DIR}/run.sh" "${PREFIX}/bin/ipv6-proxy-run"

log_step "Preparando /etc/ipv6-proxy e /etc/3proxy..."
mkdir -p /etc/ipv6-proxy /etc/3proxy
if [ ! -f /etc/ipv6-proxy/proxy.env ]; then
  install -m 0640 "${SCRIPT_DIR}/proxy.env.example" /etc/ipv6-proxy/proxy.env
  log_info "Config criado: /etc/ipv6-proxy/proxy.env"
else
  log_warn "/etc/ipv6-proxy/proxy.env já existe — mantido intacto."
fi

if [ -d /etc/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  log_step "Instalando serviço systemd..."
  install -m 0644 "${SCRIPT_DIR}/ipv6-proxy.service" /etc/systemd/system/ipv6-proxy.service
  systemctl daemon-reload
  log_info "Serviço instalado. Habilite e inicie com:"
  echo "    sudo systemctl enable --now ipv6-proxy"
fi

echo ""
log_info "Instalação concluída!"
echo ""
echo -e "${BOLD}Próximos passos:${NC}"
echo "  1. Edite /etc/ipv6-proxy/proxy.env com suas credenciais."
echo "  2. Rode em foreground para testar:    sudo ipv6-proxy-run"
echo "  3. Ou inicie como serviço:            sudo systemctl enable --now ipv6-proxy"
echo "  4. Veja logs do serviço:              sudo journalctl -u ipv6-proxy -f"
