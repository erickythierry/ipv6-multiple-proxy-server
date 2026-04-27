# IPv6 Multiple Proxy Server — Instalação Local (sem Docker)

Esta subpasta contém uma adaptação do projeto principal para rodar **direto no sistema host**, sem Docker. O instalador usa por padrão os binários do [3proxy](https://github.com/3proxy/3proxy) **pré-buildados** que acompanham o repositório (`linux/amd64` e `linux/arm64`), caindo para compilação do fonte apenas se a arquitetura não for suportada ou se você pedir explicitamente. Ele copia o binário para `/usr/local/bin`, cria um arquivo de configuração em `/etc/ipv6-proxy/` e (opcionalmente) registra um serviço `systemd`.

O comportamento em runtime é **idêntico** ao do container: detecta todos os IPv6 globais do host, cria um proxy por IP (SOCKS5 ou HTTP), exibe a tabela com portas e sai de conexões.

---

## Pré-requisitos

- Linux `amd64` ou `arm64` (outras arquiteturas caem no fallback de compilação do fonte)
- `systemd` (opcional, mas recomendado) e `bash`
- Acesso `root` (sudo)
- Um ou mais endereços IPv6 globais já atribuídos à interface de rede
- Gerenciador de pacotes suportado: `apt`, `dnf`, `yum` ou `pacman` (as deps são instaladas automaticamente)

---

## Instalação

```bash
cd local
sudo ./install.sh
```

O instalador vai:

1. Instalar dependências de runtime (`iproute2`, `curl`, `procps`).
2. Detectar a arquitetura do host e copiar o binário pré-buildado de [`bin/linux-<arch>/3proxy`](bin/) para `/usr/local/bin/3proxy`. Se não houver binário para a arquitetura, instala as deps de build (`make`, `g++`, `wget`) e compila o 3proxy a partir do fonte (versão controlada por `PROXY_VERSION`, default `0.9.5`).
3. Instalar o runner em `/usr/local/bin/ipv6-proxy-run`.
4. Criar `/etc/ipv6-proxy/proxy.env` a partir do exemplo (se ainda não existir).
5. Instalar a unit `ipv6-proxy.service` em `/etc/systemd/system/` e rodar `systemctl daemon-reload`.

Para **forçar compilação do fonte** (ignorando os binários pré-buildados):

```bash
sudo BUILD_FROM_SOURCE=1 ./install.sh
```

---

## Configuração

Edite o arquivo `/etc/ipv6-proxy/proxy.env`:

```bash
sudo nano /etc/ipv6-proxy/proxy.env
```

| Variável         | Padrão              | Descrição                                                      |
|------------------|---------------------|----------------------------------------------------------------|
| `PROXY_USER`     | _(vazio)_           | Usuário para autenticação. Vazio = sem auth.                   |
| `PROXY_PASS`     | _(vazio)_           | Senha para autenticação.                                       |
| `START_PORT`     | `30000`             | Primeira porta; demais são sequenciais.                        |
| `PROXY_TYPE`     | `socks5`            | `socks5` ou `http`.                                            |
| `NET_INTERFACE`  | _(auto)_            | Interface de rede (ex.: `eth0`, `ens3`).                       |
| `ALLOWED_HOSTS`  | _(vazio)_           | Hosts permitidos (formato 3proxy). Outros são bloqueados.      |
| `DENIED_HOSTS`   | _(vazio)_           | Hosts bloqueados. Outros são permitidos.                       |
| `SIMPLE_MODE`    | _(vazio)_           | Defina como `1` para criar apenas 1 proxy IPv4 simples, ignorando IPv6. |
| `PROXY_BIN`      | `/usr/local/bin/3proxy` | Caminho do binário do 3proxy.                              |
| `CONFIG_FILE`    | `/etc/3proxy/3proxy.cfg` | Onde gravar o config gerado.                              |
| `RUN_USER_UID`   | `65534`             | UID para o 3proxy após bind (drop de privilégios).             |
| `RUN_USER_GID`   | `65534`             | GID para o 3proxy após bind.                                   |

---

## Uso

### Modo foreground (teste/debug)

```bash
sudo ipv6-proxy-run
```

Lê `/etc/ipv6-proxy/proxy.env`, gera o config, imprime a tabela de proxies e roda o `3proxy` com logs de requisição no terminal. `Ctrl+C` encerra.

Também aceita um arquivo de config alternativo:

```bash
sudo ipv6-proxy-run /caminho/para/outro.env
```

### Modo serviço (produção)

```bash
sudo systemctl enable --now ipv6-proxy
sudo systemctl status ipv6-proxy
sudo journalctl -u ipv6-proxy -f    # acompanhar logs em tempo real
```

Reinicie após mudar o `.env`:

```bash
sudo systemctl restart ipv6-proxy
```

---

## Testando

```bash
# SOCKS5 com auth
curl -x socks5://usuario:senha@127.0.0.1:30000 http://ifconfig.me

# HTTP com auth
curl -x http://usuario:senha@127.0.0.1:30000 http://ifconfig.me

# Testar todas as portas
for port in $(seq 30000 30031); do
  echo -n "Porta $port -> "
  curl -s -x socks5://usuario:senha@127.0.0.1:$port http://ifconfig.me
  echo ""
done
```

Cada porta deve retornar um IPv6 diferente.

---

## Rebuildar os binários pré-buildados

Os binários versionados em [`bin/linux-amd64/3proxy`](bin/linux-amd64/) e [`bin/linux-arm64/3proxy`](bin/linux-arm64/) foram gerados em containers `ubuntu:22.04` (usando QEMU para o arm64 quando o host é amd64). Para regerar:

```bash
# Uma vez por host (registra QEMU no binfmt para cross-arch):
docker run --privileged --rm tonistiigi/binfmt --install arm64

# A qualquer momento, para rebuildar ambas as arquiteturas:
./local/build-binaries.sh
```

A versão do 3proxy é controlada pela variável `PROXY_VERSION` (default `0.9.5`).

---

## Desinstalação

```bash
sudo systemctl disable --now ipv6-proxy
sudo rm -f /etc/systemd/system/ipv6-proxy.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/3proxy /usr/local/bin/ipv6-proxy-run
sudo rm -rf /etc/ipv6-proxy /etc/3proxy
```

---

## Diferenças em relação à versão Docker

- Não há isolamento: o `3proxy` roda diretamente no host.
- Parâmetros `sysctl` e `ulimit` são aplicados no host (persistem só até o reboot — use `/etc/sysctl.d/` se quiser fixar).
- Logs vão para `journald` (via systemd) em vez de `docker logs`.
- Não precisa de `--privileged` nem `--network host`, mas **precisa ser root** para `sysctl`, `ip_nonlocal_bind` e bind em portas privilegiadas (se aplicável).
- Com `SIMPLE_MODE=1`, não é necessário ter IPv6 no host e os sysctls IPv6 são ignorados.
