### _this fork works differently than the [original](https://github.com/Temporalitas/ipv6-proxy-server)_

# Multiple IPv6 Proxy Server

Create your own IPv6 backconnect proxy server with Docker on any Linux distribution.
This code is an adaptation of the original project.
The original design works with an entire block of IPv6 attached to the server.
This fork works with a fixed list of IPs previously attached to the server.

## Features

- Automatically detects all global IPv6 addresses on the server
- Creates one proxy (HTTP or SOCKS5) per IPv6 address
- Displays a clear table of all created proxies (ports, IPs, auth)
- Shows real-time 3proxy request logs via `docker logs`
- Proper signal handling (graceful shutdown)
- Multi-stage Docker build (lightweight final image)
- Supports username/password authentication
- Supports host allow/deny rules

---

> **Running without Docker?** See [local/README.md](local/README.md) for an installer that uses pre-built `3proxy` binaries (linux/amd64 and linux/arm64) and registers a `systemd` service.

## Quick Start

### Prerequisites
- Docker installed
- One or more global IPv6 addresses attached to your server

### Run:
```bash
docker run --privileged -d \
  -e PROXY_USER=myuser \
  -e PROXY_PASS=mypass \
  -e START_PORT=30000 \
  -e PROXY_TYPE=socks5 \
  --name ipv6-proxy \
  --network host \
  --restart always \
  ethie/ipv6-multiple-proxy-server:v5
```

### Check the logs to see created proxies:
```bash
docker logs ipv6-proxy
```

You will see output like:
```
╔═════════════════════════════════════════════════╗
║       IPv6 Multiple Proxy Server (3proxy)       ║
╚═════════════════════════════════════════════════╝

[INFO]  Interface de rede detectada automaticamente: eth0
[INFO]  IPv6 habilitado e endereços globais encontrados.
[INFO]  Encontrados 3 endereços IPv6 globais.
[INFO]  Autenticação habilitada (usuário: myuser)

══════════════════════════════════════════════════════════════════════════
  PROXIES CRIADOS
══════════════════════════════════════════════════════════════════════════
  #     │ PORTA   │ TIPO    │ SAÍDA IPv6
  ──────┼─────────┼─────────┼──────────────────────────────────────────────
  1     │ 30000   │ socks5  │ 2001:db8::1
  2     │ 30001   │ socks5  │ 2001:db8::2
  3     │ 30002   │ socks5  │ 2001:db8::3
══════════════════════════════════════════════════════════════════════════
  Total: 3 proxies
  Portas: 30000 - 30002
  Tipo: socks5
  Auth: myuser:mypass
══════════════════════════════════════════════════════════════════════════
```

### Follow request logs in real time:
```bash
docker logs -f ipv6-proxy
```

Request logs look like:
```
11/02/2026 03:58:09 | port:30000 | code:00000 | 45.7.26.101:49378 -> facebook.com:443 | out:1234 in:5678 | user:myuser
11/02/2026 03:58:09 | port:30001 | code:00000 | 45.7.26.101:42108 -> google.com:443 | out:890 in:1234 | user:myuser
```

---

## Testing the Proxies

You can test each proxy using `curl` and the site [ifconfig.me](https://ifconfig.me), which returns the IP address that made the request.

### SOCKS5 proxy (default):
```bash
curl -x socks5://myuser:mypass@127.0.0.1:30000 http://ifconfig.me
```

### HTTP proxy:
```bash
curl -x http://myuser:mypass@127.0.0.1:30000 http://ifconfig.me
```

### Without authentication:
```bash
curl -x socks5://127.0.0.1:30000 http://ifconfig.me
```

### Test all proxies at once:
```bash
for port in $(seq 30000 30031); do
  echo -n "Port $port -> "
  curl -s -x socks5://myuser:mypass@127.0.0.1:$port http://ifconfig.me
  echo ""
done
```

Each port should return a different IPv6 address, confirming that all proxies are working correctly.

---

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `PROXY_USER` | No | _(empty)_ | Proxy authentication username |
| `PROXY_PASS` | No | _(empty)_ | Proxy authentication password |
| `START_PORT` | No | `30000` | First port for proxy assignment |
| `NET_INTERFACE` | No | _(auto-detect)_ | Network interface name (e.g. `eth0`) |
| `PROXY_TYPE` | No | `socks5` | Proxy type: `socks5` or `http` |
| `ALLOWED_HOSTS` | No | _(empty)_ | Allowed hosts (3proxy format). Others are denied |
| `DENIED_HOSTS` | No | _(empty)_ | Denied hosts (3proxy format). Others are allowed |

> **Note:** If neither `PROXY_USER` nor `PROXY_PASS` is set, proxies will run **without authentication**.

---

## Build from Source

```bash
docker build -t ipv6-proxy .
```

Then run:
```bash
docker run --privileged -d \
  -e PROXY_USER=myuser \
  -e PROXY_PASS=mypass \
  -e START_PORT=30000 \
  --name ipv6-proxy \
  --network host \
  --restart always \
  ipv6-proxy
```

---

## Examples

### SOCKS5 proxy with auth:
```bash
docker run --privileged -d \
  -e PROXY_USER=admin -e PROXY_PASS=secretpass \
  -e START_PORT=40000 -e PROXY_TYPE=socks5 \
  --name ipv6-proxy --network host --restart always \
  ethie/ipv6-multiple-proxy-server:v5
```

### HTTP proxy without auth:
```bash
docker run --privileged -d \
  -e START_PORT=50000 -e PROXY_TYPE=http \
  --name ipv6-proxy --network host --restart always \
  ethie/ipv6-multiple-proxy-server:v5
```

### With host restrictions:
```bash
docker run --privileged -d \
  -e PROXY_USER=admin -e PROXY_PASS=pass \
  -e ALLOWED_HOSTS="google.com,*.google.com" \
  --name ipv6-proxy --network host --restart always \
  ethie/ipv6-multiple-proxy-server:v5
```

### Specifying network interface:
```bash
docker run --privileged -d \
  -e PROXY_USER=admin -e PROXY_PASS=pass \
  -e NET_INTERFACE=ens3 \
  --name ipv6-proxy --network host --restart always \
  ethie/ipv6-multiple-proxy-server:v5
```

---

## Important Notes

- The container **must** use `--network host` to access the host's IPv6 addresses.
- The container **must** use `--privileged` to configure sysctl network parameters.
- One proxy is created per global IPv6 address found on the system.
- Ports are assigned sequentially starting from `START_PORT`.

---

# 🇧🇷

### _Este fork funciona de forma diferente do [original](https://github.com/Temporalitas/ipv6-proxy-server)_

# Servidor Multi Proxy IPv6

Crie seu próprio servidor de proxy de backconnect IPv6 com Docker em qualquer distribuição Linux.
Este código é uma adaptação do projeto original.
O design original funciona com um bloco inteiro de IPv6 anexado ao servidor.
Este fork funciona com uma lista fixa de IPs previamente anexados ao servidor.

> **Quer rodar sem Docker?** Veja [local/README.md](local/README.md) — tem um instalador que usa os binários do `3proxy` pré-buildados (linux/amd64 e linux/arm64) e registra um serviço `systemd`.

## Início Rápido

### Pré-requisitos
- Docker instalado
- Um ou mais endereços IPv6 globais anexados ao servidor

### Executar:
```bash
docker run --privileged -d \
  -e PROXY_USER=usuario \
  -e PROXY_PASS=senha \
  -e START_PORT=30000 \
  -e PROXY_TYPE=socks5 \
  --name ipv6-proxy \
  --network host \
  --restart always \
  ethie/ipv6-multiple-proxy-server:v5
```

### Ver os proxies criados e logs:
```bash
docker logs ipv6-proxy        # ver logs
docker logs -f ipv6-proxy     # acompanhar em tempo real
```

---

## Testando os Proxies

Use `curl` com o site [ifconfig.me](https://ifconfig.me), que retorna o IP que fez a requisição.

### Proxy SOCKS5 (padrão):
```bash
curl -x socks5://usuario:senha@127.0.0.1:30000 http://ifconfig.me
```

### Proxy HTTP:
```bash
curl -x http://usuario:senha@127.0.0.1:30000 http://ifconfig.me
```

### Sem autenticação:
```bash
curl -x socks5://127.0.0.1:30000 http://ifconfig.me
```

### Testar todos os proxies de uma vez:
```bash
for port in $(seq 30000 30031); do
  echo -n "Porta $port -> "
  curl -s -x socks5://usuario:senha@127.0.0.1:$port http://ifconfig.me
  echo ""
done
```

Cada porta deve retornar um endereço IPv6 diferente, confirmando que todos os proxies estão funcionando.

---

## Variáveis de Ambiente

| Variável | Obrigatório | Padrão | Descrição |
|---|---|---|---|
| `PROXY_USER` | Não | _(vazio)_ | Usuário para autenticação do proxy |
| `PROXY_PASS` | Não | _(vazio)_ | Senha para autenticação do proxy |
| `START_PORT` | Não | `30000` | Porta inicial para atribuição de proxies |
| `NET_INTERFACE` | Não | _(auto-detect)_ | Nome da interface de rede (ex: `eth0`) |
| `PROXY_TYPE` | Não | `socks5` | Tipo de proxy: `socks5` ou `http` |
| `ALLOWED_HOSTS` | Não | _(vazio)_ | Hosts permitidos (formato 3proxy). Outros são bloqueados |
| `DENIED_HOSTS` | Não | _(vazio)_ | Hosts bloqueados (formato 3proxy). Outros são permitidos |

### Build local:
```bash
docker build -t ipv6-proxy .
docker run --privileged -d \
  -e PROXY_USER=usuario \
  -e PROXY_PASS=senha \
  --name ipv6-proxy --network host --restart always ipv6-proxy
```

---

## Notas Importantes

- O container **precisa** usar `--network host` para acessar os IPv6 do host.
- O container **precisa** usar `--privileged` para configurar parâmetros sysctl de rede.
- Um proxy é criado por endereço IPv6 global encontrado no sistema.
- As portas são atribuídas sequencialmente a partir do `START_PORT`.

---

### Licence

#### [MIT](https://opensource.org/licenses/MIT)
