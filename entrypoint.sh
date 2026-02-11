#!/bin/bash
set -euo pipefail

# =============================================
# IPv6 Multiple Proxy Server - Docker Entrypoint
# =============================================
# Gera a configuração do 3proxy automaticamente,
# exibe uma tabela com todos os proxies criados,
# e roda o 3proxy em foreground com logs em stdout.
# =============================================

# === Cores para output ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

function log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
function log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
function log_error() { echo -e "${RED}[ERRO]${NC} $1"; }
function log_step()  { echo -e "${CYAN}[>>>>]${NC} $1"; }

# === Banner ===
echo -e "${CYAN}${BOLD}"
echo "╔═════════════════════════════════════════════════╗"
echo "║       IPv6 Multiple Proxy Server (3proxy)       ║"
echo "╚═════════════════════════════════════════════════╝"
echo -e "${NC}"

# === Variáveis de ambiente (com defaults) ===
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"
START_PORT="${START_PORT:-30000}"
NET_INTERFACE="${NET_INTERFACE:-}"
PROXY_TYPE="${PROXY_TYPE:-socks5}"
ALLOWED_HOSTS="${ALLOWED_HOSTS:-}"
DENIED_HOSTS="${DENIED_HOSTS:-}"

# === Validar tipo de proxy ===
if [ "$PROXY_TYPE" != "http" ] && [ "$PROXY_TYPE" != "socks5" ]; then
  log_error "PROXY_TYPE inválido: '$PROXY_TYPE'. Use 'http' ou 'socks5'."
  exit 1
fi

# === Auto-detectar interface de rede se não definida ===
if [ -z "$NET_INTERFACE" ]; then
  NET_INTERFACE="$(ip -br l | awk '$1 !~ "lo|vir|wl|docker|br-|veth|@NONE" { print $1}' | head -1)"
  if [ -z "$NET_INTERFACE" ]; then
    log_error "Não foi possível detectar a interface de rede automaticamente."
    log_error "Defina a variável NET_INTERFACE. Interfaces disponíveis:"
    ip -br link | awk '{print "  - "$1" ("$2")"}'
    exit 1
  fi
  log_info "Interface de rede detectada automaticamente: ${BOLD}${NET_INTERFACE}${NC}"
else
  log_info "Interface de rede definida pelo usuário: ${BOLD}${NET_INTERFACE}${NC}"
fi

# === Validar que a interface existe ===
if ! ip link show "$NET_INTERFACE" &>/dev/null; then
  log_error "Interface de rede '${NET_INTERFACE}' não encontrada!"
  log_error "Interfaces disponíveis:"
  ip -br link | awk '{print "  - "$1" ("$2")"}'
  exit 1
fi

# === Verificar IPv6 ===
log_step "Verificando suporte a IPv6..."

if ! test -f /proc/net/if_inet6; then
  log_error "IPv6 não está habilitado no sistema."
  log_error "Certifique-se de que o host suporta IPv6 e que o container tem acesso."
  exit 1
fi

if [ -z "$(ip -6 addr show scope global 2>/dev/null)" ]; then
  log_error "Nenhum endereço IPv6 global encontrado."
  log_error "Verifique se há IPv6 atribuído ao servidor e se o container usa --network host."
  exit 1
fi

log_info "IPv6 habilitado e endereços globais encontrados."

# === Configurar sysctl para IPv6 ===
log_step "Configurando parâmetros de rede IPv6 (sysctl)..."

sysctl_ok=true
for opt in \
  "net.ipv6.conf.${NET_INTERFACE}.proxy_ndp=1" \
  "net.ipv6.conf.all.proxy_ndp=1" \
  "net.ipv6.conf.default.forwarding=1" \
  "net.ipv6.conf.all.forwarding=1" \
  "net.ipv6.ip_nonlocal_bind=1"; do
  if ! sysctl -w "$opt" &>/dev/null; then
    log_warn "Falha ao configurar: $opt"
    sysctl_ok=false
  fi
done

if [ "$sysctl_ok" = true ]; then
  log_info "Parâmetros sysctl IPv6 configurados com sucesso."
else
  log_warn "Alguns parâmetros sysctl falharam. O container precisa de --privileged."
fi

# === Detectar endereços IPv6 globais ===
log_step "Detectando endereços IPv6 globais..."

mapfile -t IPV6_LIST < <(
  ip -6 addr show scope global 2>/dev/null \
    | awk '/inet6/ { print $2 }' \
    | cut -d'/' -f1 \
    | grep -E '^[23][0-9a-fA-F]{3}:'
)

if [ ${#IPV6_LIST[@]} -eq 0 ]; then
  log_error "Nenhum endereço IPv6 global válido encontrado!"
  log_error "Endereços IPv6 no sistema:"
  ip -6 addr show | awk '/inet6/ { print "  "$2 }'
  exit 1
fi

PROXY_COUNT=${#IPV6_LIST[@]}
LAST_PORT=$((START_PORT + PROXY_COUNT - 1))

log_info "Encontrados ${BOLD}${PROXY_COUNT}${NC} endereços IPv6 globais."

# === Validar porta inicial ===
if [ "$START_PORT" -lt 1024 ] || [ "$LAST_PORT" -gt 65535 ]; then
  log_error "Range de portas inválido: ${START_PORT}-${LAST_PORT}"
  log_error "START_PORT deve ser >= 1024 e a última porta (${LAST_PORT}) deve ser <= 65535."
  exit 1
fi

# === Validar autenticação ===
USE_AUTH=false
if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
  USE_AUTH=true
  log_info "Autenticação habilitada (usuário: ${BOLD}${PROXY_USER}${NC})"
elif [ -n "$PROXY_USER" ] || [ -n "$PROXY_PASS" ]; then
  log_error "PROXY_USER e PROXY_PASS devem ser definidos juntos!"
  exit 1
else
  log_warn "Proxies sem autenticação! Defina PROXY_USER e PROXY_PASS para proteger."
fi

# === Gerar configuração do 3proxy ===
log_step "Gerando configuração do 3proxy..."

CONFIG_DIR="/etc/3proxy"
CONFIG_FILE="${CONFIG_DIR}/3proxy.cfg"
mkdir -p "$CONFIG_DIR"

# Cabeçalho do config -- SEM diretiva "daemon" para rodar em foreground
cat > "$CONFIG_FILE" <<'CFGHEADER'
# 3proxy configuration - gerado automaticamente pelo entrypoint

# DNS servers
nserver 8.8.8.8
nserver 8.8.4.4
nserver 1.1.1.1
nserver 1.0.0.1

# Performance
maxconn 10000
nscache 65536
nscache6 65536
timeouts 1 5 30 60 180 60 15 60

# Log para stdout (visível em docker logs)
log /dev/stdout
logformat "+%d/%m/%Y %H:%M:%S | port:%p | code:%E | %C:%c -> %n:%r | out:%O in:%I | user:%U"

# Segurança
setgid 65535
setuid 65535

CFGHEADER

# Seção de autenticação
if [ "$USE_AUTH" = true ]; then
  cat >> "$CONFIG_FILE" <<CFGAUTH
auth strong
users ${PROXY_USER}:CL:${PROXY_PASS}
CFGAUTH
else
  echo "auth iponly" >> "$CONFIG_FILE"
fi

echo "" >> "$CONFIG_FILE"

# Regras de acesso
if [ -n "$DENIED_HOSTS" ]; then
  echo "deny * * ${DENIED_HOSTS}" >> "$CONFIG_FILE"
  echo "allow *" >> "$CONFIG_FILE"
elif [ -n "$ALLOWED_HOSTS" ]; then
  echo "allow * * ${ALLOWED_HOSTS}" >> "$CONFIG_FILE"
  echo "deny *" >> "$CONFIG_FILE"
else
  echo "allow *" >> "$CONFIG_FILE"
fi

echo "" >> "$CONFIG_FILE"

# Entradas de proxy (uma por IPv6)
if [ "$PROXY_TYPE" = "http" ]; then
  PROXY_CMD="proxy -6 -n -a"
else
  PROXY_CMD="socks -6 -a"
fi

PORT=$START_PORT
for IPV6 in "${IPV6_LIST[@]}"; do
  echo "${PROXY_CMD} -p${PORT} -i0.0.0.0 -e${IPV6}" >> "$CONFIG_FILE"
  ((PORT++))
done

log_info "Configuração gerada em: ${CONFIG_FILE}"

# === Exibir tabela de proxies criados ===
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}  PROXIES CRIADOS${NC}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
printf "  ${DIM}%-5s${NC} │ ${BOLD}%-7s${NC} │ ${BOLD}%-7s${NC} │ ${BOLD}%-45s${NC}\n" "#" "PORTA" "TIPO" "SAÍDA IPv6"
echo -e "  ${DIM}──────┼─────────┼─────────┼──────────────────────────────────────────────${NC}"

PORT=$START_PORT
COUNT=1
for IPV6 in "${IPV6_LIST[@]}"; do
  printf "  %-5s │ %-7s │ %-7s │ %-45s\n" "$COUNT" "$PORT" "$PROXY_TYPE" "$IPV6"
  ((PORT++))
  ((COUNT++))
done

echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}Total:${NC} ${PROXY_COUNT} proxies"
echo -e "  ${BOLD}Portas:${NC} ${START_PORT} - ${LAST_PORT}"
echo -e "  ${BOLD}Tipo:${NC} ${PROXY_TYPE}"
if [ "$USE_AUTH" = true ]; then
  echo -e "  ${BOLD}Auth:${NC} ${PROXY_USER}:${PROXY_PASS}"
else
  echo -e "  ${BOLD}Auth:${NC} ${YELLOW}desabilitada${NC}"
fi
if [ -n "$ALLOWED_HOSTS" ]; then
  echo -e "  ${BOLD}Hosts permitidos:${NC} ${ALLOWED_HOSTS}"
fi
if [ -n "$DENIED_HOSTS" ]; then
  echo -e "  ${BOLD}Hosts bloqueados:${NC} ${DENIED_HOSTS}"
fi
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# === Configurar ulimits ===
ulimit -n 600000 2>/dev/null || log_warn "Não foi possível aumentar ulimit -n (file descriptors)"
ulimit -u 600000 2>/dev/null || log_warn "Não foi possível aumentar ulimit -u (user processes)"

# === Tratar sinais para shutdown graceful ===
PROXY_PID=""

function cleanup() {
  echo ""
  log_info "Sinal de parada recebido. Encerrando 3proxy..."
  if [ -n "$PROXY_PID" ]; then
    kill -TERM "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
  fi
  log_info "3proxy encerrado. Até logo!"
  exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# === Iniciar 3proxy em foreground ===
log_info "Iniciando 3proxy..."
echo ""
echo -e "${GREEN}${BOLD}═══ Logs de requisições do 3proxy ══════════════════════════════════════${NC}"
echo ""

/usr/local/bin/3proxy "$CONFIG_FILE" &
PROXY_PID=$!

# Aguardar um momento para verificar se iniciou
sleep 1

if kill -0 "$PROXY_PID" 2>/dev/null; then
  log_info "3proxy iniciado com sucesso! (PID: ${PROXY_PID})"
  echo ""
else
  log_error "Falha ao iniciar o 3proxy!"
  log_error "Verifique a configuração acima e tente novamente."
  exit 1
fi

# Aguardar o processo do 3proxy (mantém container vivo)
wait "$PROXY_PID"
EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -ne 0 ]; then
  log_error "3proxy encerrou inesperadamente com código: ${EXIT_CODE}"
else
  log_info "3proxy encerrou normalmente."
fi

exit $EXIT_CODE
