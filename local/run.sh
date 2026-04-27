#!/bin/bash
set -euo pipefail

# =============================================
# IPv6 Multiple Proxy Server - Runner Local
# =============================================
# Gera a configuração do 3proxy a partir de
# /etc/ipv6-proxy/proxy.env (ou do caminho passado
# como $1) e executa o 3proxy em foreground.
# =============================================

CONFIG_ENV="${1:-/etc/ipv6-proxy/proxy.env}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
log_info() { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_err()  { echo -e "${RED}[ERRO]${NC} $1"; }
log_step() { echo -e "${CYAN}[>>>>]${NC} $1"; }

echo -e "${CYAN}${BOLD}"
echo "╔═════════════════════════════════════════════════╗"
echo "║    IPv6 Multiple Proxy Server (3proxy) — LOCAL  ║"
echo "╚═════════════════════════════════════════════════╝"
echo -e "${NC}"

if [ "$(id -u)" -ne 0 ]; then
  log_err "Este script precisa ser executado como root (sysctl/bind em portas < 1024 e ip_nonlocal_bind)."
  exit 1
fi

# === Carregar variáveis do arquivo de configuração ===
if [ -f "$CONFIG_ENV" ]; then
  log_info "Carregando configuração de: ${CONFIG_ENV}"
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_ENV"
  set +a
else
  log_warn "Arquivo de configuração não encontrado: ${CONFIG_ENV}. Usando defaults/ambiente."
fi

PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"
START_PORT="${START_PORT:-30000}"
NET_INTERFACE="${NET_INTERFACE:-}"
PROXY_TYPE="${PROXY_TYPE:-socks5}"
ALLOWED_HOSTS="${ALLOWED_HOSTS:-}"
DENIED_HOSTS="${DENIED_HOSTS:-}"
SIMPLE_MODE="${SIMPLE_MODE:-}"
PROXY_BIN="${PROXY_BIN:-/usr/local/bin/3proxy}"
CONFIG_FILE="${CONFIG_FILE:-/etc/3proxy/3proxy.cfg}"
RUN_USER_UID="${RUN_USER_UID:-65534}"
RUN_USER_GID="${RUN_USER_GID:-65534}"

if [ ! -x "$PROXY_BIN" ]; then
  log_err "Binário do 3proxy não encontrado em ${PROXY_BIN}. Rode o install.sh primeiro."
  exit 1
fi

if [ "$PROXY_TYPE" != "http" ] && [ "$PROXY_TYPE" != "socks5" ]; then
  log_err "PROXY_TYPE inválido: '$PROXY_TYPE'. Use 'http' ou 'socks5'."
  exit 1
fi

# === Modo simples (IPv4, proxy único) ===
case "${SIMPLE_MODE,,}" in
  1|true|yes)
    SIMPLE_MODE="1"
    log_info "Modo SIMPLE_MODE ativado: será criado 1 proxy IPv4 simples na porta ${START_PORT}."
    ;;
esac

# === Auto-detectar interface ===
if [ -z "$NET_INTERFACE" ]; then
  NET_INTERFACE="$(ip -br l | awk '$1 !~ "lo|vir|wl|docker|br-|veth|@NONE" { print $1}' | head -1)"
  if [ -z "$NET_INTERFACE" ]; then
    log_err "Não foi possível detectar a interface de rede automaticamente."
    ip -br link | awk '{print "  - "$1" ("$2")"}'
    exit 1
  fi
  log_info "Interface detectada: ${BOLD}${NET_INTERFACE}${NC}"
else
  log_info "Interface definida: ${BOLD}${NET_INTERFACE}${NC}"
fi

if ! ip link show "$NET_INTERFACE" &>/dev/null; then
  log_err "Interface '${NET_INTERFACE}' não encontrada."
  exit 1
fi

# === Checar IPv6 (apenas no modo padrão) ===
if [ "$SIMPLE_MODE" != "1" ]; then
  log_step "Verificando IPv6..."
  if ! test -f /proc/net/if_inet6; then
    log_err "IPv6 não habilitado no kernel."
    exit 1
  fi
  if [ -z "$(ip -6 addr show scope global 2>/dev/null)" ]; then
    log_err "Nenhum endereço IPv6 global no sistema."
    exit 1
  fi

  # === sysctl ===
  log_step "Configurando sysctl IPv6..."
  for opt in \
    "net.ipv6.conf.${NET_INTERFACE}.proxy_ndp=1" \
    "net.ipv6.conf.all.proxy_ndp=1" \
    "net.ipv6.conf.default.forwarding=1" \
    "net.ipv6.conf.all.forwarding=1" \
    "net.ipv6.ip_nonlocal_bind=1"; do
    if ! sysctl -w "$opt" &>/dev/null; then
      log_warn "Falha: $opt"
    fi
  done

  # === Coletar IPv6 globais ===
  log_step "Coletando endereços IPv6 globais..."
  mapfile -t IPV6_LIST < <(
    ip -6 addr show scope global 2>/dev/null \
      | awk '/inet6/ { print $2 }' \
      | cut -d'/' -f1 \
      | grep -E '^[23][0-9a-fA-F]{3}:'
  )

  if [ ${#IPV6_LIST[@]} -eq 0 ]; then
    log_err "Nenhum IPv6 global válido encontrado."
    exit 1
  fi

  PROXY_COUNT=${#IPV6_LIST[@]}
  LAST_PORT=$((START_PORT + PROXY_COUNT - 1))
  log_info "${BOLD}${PROXY_COUNT}${NC} endereços IPv6 globais encontrados."
else
  PROXY_COUNT=1
  LAST_PORT=$START_PORT
fi

if [ "$START_PORT" -lt 1024 ] || [ "$LAST_PORT" -gt 65535 ]; then
  log_err "Range de portas inválido: ${START_PORT}-${LAST_PORT}"
  exit 1
fi

# === Auth ===
USE_AUTH=false
if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
  USE_AUTH=true
  log_info "Autenticação habilitada (usuário: ${BOLD}${PROXY_USER}${NC})"
elif [ -n "$PROXY_USER" ] || [ -n "$PROXY_PASS" ]; then
  log_err "PROXY_USER e PROXY_PASS devem ser definidos juntos."
  exit 1
else
  log_warn "Proxies SEM autenticação."
fi

# === Gerar config ===
log_step "Gerando ${CONFIG_FILE}..."
mkdir -p "$(dirname "$CONFIG_FILE")"

{
  cat <<CFGHEADER
# 3proxy configuration - gerado automaticamente por ipv6-proxy-run

nserver 8.8.8.8
nserver 8.8.4.4
nserver 1.1.1.1
nserver 1.0.0.1

maxconn 10000
nscache 65536
nscache6 65536
timeouts 1 5 30 60 180 60 15 60

log /dev/stdout
logformat "+%d/%m/%Y %H:%M:%S | port:%p | code:%E | %C:%c -> %n:%r | out:%O in:%I | user:%U"

setgid ${RUN_USER_GID}
setuid ${RUN_USER_UID}

CFGHEADER

  if [ "$USE_AUTH" = true ]; then
    echo "auth strong"
    echo "users ${PROXY_USER}:CL:${PROXY_PASS}"
  else
    echo "auth iponly"
  fi
  echo ""

  if [ -n "$DENIED_HOSTS" ]; then
    echo "deny * * ${DENIED_HOSTS}"
    echo "allow *"
  elif [ -n "$ALLOWED_HOSTS" ]; then
    echo "allow * * ${ALLOWED_HOSTS}"
    echo "deny *"
  else
    echo "allow *"
  fi
  echo ""

  if [ "$SIMPLE_MODE" = "1" ]; then
    # Modo simples IPv4: 1 proxy sem flags IPv6 e sem IP de saída específico
    if [ "$PROXY_TYPE" = "http" ]; then
      PROXY_CMD="proxy -n -a"
    else
      PROXY_CMD="socks -a"
    fi
    echo "${PROXY_CMD} -p${START_PORT} -i0.0.0.0"
  else
    # Modo padrão: um proxy por IPv6
    if [ "$PROXY_TYPE" = "http" ]; then
      PROXY_CMD="proxy -6 -n -a"
    else
      PROXY_CMD="socks -6 -a"
    fi

    PORT=$START_PORT
    for IPV6 in "${IPV6_LIST[@]}"; do
      echo "${PROXY_CMD} -p${PORT} -i0.0.0.0 -e${IPV6}"
      PORT=$((PORT + 1))
    done
  fi
} > "$CONFIG_FILE"

log_info "Configuração gerada."

# === Tabela ===
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  PROXIES CRIADOS${NC}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"

if [ "$SIMPLE_MODE" = "1" ]; then
  printf "  ${DIM}%-5s${NC} │ ${BOLD}%-7s${NC} │ ${BOLD}%-7s${NC} │ ${BOLD}%-45s${NC}\n" "#" "PORTA" "TIPO" "SAÍDA"
  echo -e "  ${DIM}──────┼─────────┼─────────┼──────────────────────────────────────────────${NC}"
  printf "  %-5s │ %-7s │ %-7s │ %-45s\n" "1" "$START_PORT" "$PROXY_TYPE" "IPv4 (todas as interfaces)"
else
  printf "  ${DIM}%-5s${NC} │ ${BOLD}%-7s${NC} │ ${BOLD}%-7s${NC} │ ${BOLD}%-45s${NC}\n" "#" "PORTA" "TIPO" "SAÍDA IPv6"
  echo -e "  ${DIM}──────┼─────────┼─────────┼──────────────────────────────────────────────${NC}"
  PORT=$START_PORT; COUNT=1
  for IPV6 in "${IPV6_LIST[@]}"; do
    printf "  %-5s │ %-7s │ %-7s │ %-45s\n" "$COUNT" "$PORT" "$PROXY_TYPE" "$IPV6"
    PORT=$((PORT + 1)); COUNT=$((COUNT + 1))
  done
fi

echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}Total:${NC} ${PROXY_COUNT} proxies"
if [ "$SIMPLE_MODE" != "1" ]; then
  echo -e "  ${BOLD}Portas:${NC} ${START_PORT} - ${LAST_PORT}"
else
  echo -e "  ${BOLD}Porta:${NC} ${START_PORT}"
fi
echo -e "  ${BOLD}Tipo:${NC} ${PROXY_TYPE}"
if [ "$USE_AUTH" = true ]; then
  echo -e "  ${BOLD}Auth:${NC} ${PROXY_USER}:${PROXY_PASS}"
else
  echo -e "  ${BOLD}Auth:${NC} ${YELLOW}desabilitada${NC}"
fi
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# === ulimits ===
ulimit -n 600000 2>/dev/null || log_warn "Falha em ulimit -n"
ulimit -u 600000 2>/dev/null || log_warn "Falha em ulimit -u"

# === Signal handling ===
PROXY_PID=""
cleanup() {
  echo ""; log_info "Encerrando 3proxy..."
  [ -n "$PROXY_PID" ] && kill -TERM "$PROXY_PID" 2>/dev/null || true
  [ -n "$PROXY_PID" ] && wait "$PROXY_PID" 2>/dev/null || true
  log_info "Encerrado."
  exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

log_info "Iniciando 3proxy em foreground..."
echo -e "${GREEN}${BOLD}═══ Logs de requisições ══════════════════════════════════════${NC}"
echo ""

"$PROXY_BIN" "$CONFIG_FILE" &
PROXY_PID=$!
sleep 1

if kill -0 "$PROXY_PID" 2>/dev/null; then
  log_info "3proxy iniciado (PID ${PROXY_PID})."
  echo ""
else
  log_err "Falha ao iniciar 3proxy."
  exit 1
fi

wait "$PROXY_PID"
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  log_err "3proxy encerrou com código ${EXIT_CODE}."
else
  log_info "3proxy encerrou normalmente."
fi
exit $EXIT_CODE
