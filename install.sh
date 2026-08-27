#!/usr/bin/env bash
#
# Instalador do DockerManager. Faz tudo: Docker, compilação, serviço, proxy e
# certificado — a instalação termina com o painel acessível por HTTPS.
#
#   sudo ./install.sh
#
# Numa máquina limpa, sem código nem credencial:
#
#   curl -fsSL https://raw.githubusercontent.com/paulogeovane/dockermanager-install/main/install.sh | sudo bash
#
# Repetir a execução atualiza o binário sem tocar em dados nem na configuração.
#
# Opções por variável de ambiente:
#   DM_HOST=painel.seudominio.com.br   domínio a usar em vez do nip.io
#   DM_SEM_PUBLICAR=1                  não sobe o proxy nem emite certificado
#   DM_COMPILAR=1                      compila em vez de baixar o binário
#   DM_VERSAO=v0.1.0                   instala uma versão específica em vez da última
#   GITHUB_TOKEN=ghp_...               só para clonar o código privado
#
set -euo pipefail

# O binário mora em /opt, num diretório do usuário do serviço: é o que permite
# ao painel se atualizar sozinho sem rodar como root. O link em /usr/local/bin
# é só para o comando existir no PATH.
BIN_DIR=/opt/dockermanager
BIN=$BIN_DIR/dockermanager
LINK=/usr/local/bin/dockermanager
CONF_DIR=/etc/dockermanager
CONF="$CONF_DIR/dm.env"
DATA_DIR=/var/lib/dockermanager
PROJECTS_DIR=/srv/projects
SERVICE_USER=dockermanager
GO_VERSION=1.26.5

msg()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[0;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "rode com sudo."

# ─── Código-fonte ─────────────────────────────────────────────────────────
# Executado por `curl | bash`, não há repositório por perto — nem sequer este
# arquivo em disco. Buscar o código aqui é o que permite instalar com um
# comando só, em vez de exigir git clone antes.
# Só quando se pede compilação: com binário publicado, não há por que clonar
# um repositório privado — e é isso que dispensa o token na instalação.
if [ ! -f go.mod ] && [ "${DM_COMPILAR:-}" = "1" ]; then
    msg "Código-fonte"
    command -v git >/dev/null 2>&1 || {
        apt-get update -qq && apt-get install -y -qq git >/dev/null
    }

    FONTE=/usr/local/src/dockermanager
    REPO=${DM_REPO:-github.com/paulogeovane/DockerManager}

    # O token entra na URL só nesta chamada e não fica gravado: o clone usa
    # --no-tags e o diretório é reescrito a cada execução, então nada com
    # credencial sobrevive em .git/config.
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        URL="https://x-access-token:${GITHUB_TOKEN}@${REPO}.git"
    else
        URL="https://${REPO}.git"
    fi

    rm -rf "$FONTE"
    git clone -q --depth 1 --no-tags "$URL" "$FONTE" 2>/dev/null || die \
        "não consegui clonar ${REPO}. Se o repositório for privado, informe GITHUB_TOKEN."

    # Apaga o remoto com credencial antes de qualquer outra coisa tocar o
    # diretório.
    git -C "$FONTE" remote set-url origin "https://${REPO}.git"

    cd "$FONTE"
    ok "código em $FONTE"
fi

[ -f go.mod ] || die "rode a partir da raiz do projeto (onde está o go.mod)."

# ─── Docker ───────────────────────────────────────────────────────────────
msg "Docker"
if command -v docker >/dev/null 2>&1; then
    ok "já instalado ($(docker --version | cut -d' ' -f3 | tr -d ,))"
else
    warn "não encontrado; instalando pelo script oficial"
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "instalado"
fi

docker info >/dev/null 2>&1 || die "o daemon do Docker não está respondendo."

# ─── Rotação de log do Docker ─────────────────────────────────────────────
# Sem isto o log dos containers cresce sem teto. Uma aplicação com tráfego
# escrevendo em stdout enche o disco em semanas, e disco cheio derruba tudo de
# uma vez: o banco para de escrever, o proxy para de renovar certificado e o
# painel para de gravar. É a falha que não avisa antes de acontecer.
msg "Rotação de log do Docker"
DAEMON_JSON=/etc/docker/daemon.json

if [ ! -f "$DAEMON_JSON" ]; then
    mkdir -p /etc/docker
    cat > "$DAEMON_JSON" <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
    systemctl restart docker
    ok "configurada (10 MB por arquivo, 3 arquivos por container)"

elif grep -q '"log-opts"' "$DAEMON_JSON"; then
    ok "já configurada"

elif command -v jq >/dev/null 2>&1; then
    # Reescrever o arquivo inteiro apagaria outras opções do daemon — faixas de
    # rede, registries, storage driver. O jq mescla preservando o resto.
    jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' \
        "$DAEMON_JSON" > "$DAEMON_JSON.novo" && mv "$DAEMON_JSON.novo" "$DAEMON_JSON"
    systemctl restart docker
    ok "acrescentada ao daemon.json existente"

else
    # Sem jq, mexer no JSON à mão arriscaria quebrar a configuração do daemon —
    # e um daemon.json inválido impede o Docker de subir.
    warn "$DAEMON_JSON existe e não tem log-opts; não vou editá-lo sem jq."
    warn "Acrescente à mão, senão o log dos containers cresce até encher o disco:"
    warn '  "log-driver": "json-file",'
    warn '  "log-opts": { "max-size": "10m", "max-file": "3" }'
fi

# ─── Binário ──────────────────────────────────────────────────────────────
# Baixar em vez de compilar. Compilar exige o Go (uns 200 MB) e leva minutos —
# tolerável uma vez, proibitivo a cada atualização. E é o que permite instalar
# numa máquina pequena, que pode não ter memória para compilar.
#
# A compilação continua como alternativa: sem release para a arquitetura, ou
# rodando de dentro de um clone com DM_COMPILAR=1, ele compila como antes.
msg "Binário"

case "$(uname -m)" in
    x86_64)        ARQ=amd64 ;;
    aarch64|arm64) ARQ=arm64 ;;
    *)             ARQ="" ;;
esac

DISTRIBUICAO=${DM_DISTRIBUICAO:-https://github.com/paulogeovane/dockermanager-install}
BAIXOU=0

mkdir -p "$BIN_DIR"
if [ -n "$ARQ" ] && [ "${DM_COMPILAR:-}" != "1" ]; then
    if [ -n "${DM_VERSAO:-}" ]; then
        BASE="$DISTRIBUICAO/releases/download/$DM_VERSAO"
    else
        BASE="$DISTRIBUICAO/releases/latest/download"
    fi

    if curl -fsSL --retry 3 -o "$BIN.novo" "$BASE/dockermanager-linux-$ARQ" 2>/dev/null; then
        # Conferir o checksum ANTES de trocar: um download truncado vira um
        # painel que não sobe — e some justamente a ferramenta com que se
        # consertaria.
        if curl -fsSL -o /tmp/SHA256SUMS "$BASE/SHA256SUMS" 2>/dev/null; then
            ESPERADO=$(awk -v a="dockermanager-linux-$ARQ" '$2 == a {print $1}' /tmp/SHA256SUMS)
            OBTIDO=$(sha256sum "$BIN.novo" | awk '{print $1}')

            if [ -n "$ESPERADO" ] && [ "$ESPERADO" != "$OBTIDO" ]; then
                rm -f "$BIN.novo"
                die "o binário baixado não confere com o checksum publicado."
            fi
            ok "checksum conferido"
        else
            warn "sem SHA256SUMS publicado; não deu para conferir o download"
        fi

        chmod 755 "$BIN.novo"
        BAIXOU=1
        ok "baixado para $ARQ"
    else
        rm -f "$BIN.novo"
    fi
fi

if [ "$BAIXOU" -eq 0 ]; then
    [ -f go.mod ] || die "sem binário publicado para esta arquitetura e sem código para compilar."
    warn "compilando a partir do código"

    # Go só para compilar, em /usr/local/go — fora do PATH do sistema, para não
    # conflitar com um Go que o usuário já tenha.
    GO_BIN=$(command -v go || true)
    if [ -z "$GO_BIN" ] && [ -x /usr/local/go/bin/go ]; then
        GO_BIN=/usr/local/go/bin/go
    fi
    if [ -z "$GO_BIN" ]; then
        warn "Go não encontrado; baixando ${GO_VERSION}"
        [ -n "$ARQ" ] || die "arquitetura não suportada: $(uname -m)"
        curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARQ}.tar.gz" -o /tmp/go.tgz
        rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz
        GO_BIN=/usr/local/go/bin/go
    fi

    # CGO desligado porque o driver de SQLite é Go puro: o binário sai estático
    # e não depende da libc desta máquina.
    CGO_ENABLED=0 "$GO_BIN" build -trimpath -ldflags="-s -w" -o "$BIN.novo" ./cmd/dm
    chmod 755 "$BIN.novo"
    ok "compilado"
fi

# Só troca no fim: uma falha antes daqui não pode deixar o serviço sem binário.
mv "$BIN.novo" "$BIN"
# Instalação antiga tinha o binário direto em /usr/local/bin; vira link.
[ -L "$LINK" ] || rm -f "$LINK"
ln -sfn "$BIN" "$LINK"
ok "$BIN ($(du -h "$BIN" | cut -f1))"

# ─── Usuário e diretórios ─────────────────────────────────────────────────
msg "Usuário e diretórios"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    ok "usuário $SERVICE_USER criado"
else
    ok "usuário $SERVICE_USER já existe"
fi
# Pertencer ao grupo docker é o que dá acesso ao socket sem rodar como root.
usermod -aG docker "$SERVICE_USER"

mkdir -p "$DATA_DIR" "$PROJECTS_DIR" "$CONF_DIR"
chown -R "$SERVICE_USER":"$SERVICE_USER" "$DATA_DIR" "$PROJECTS_DIR" "$BIN_DIR"
chmod 750 "$DATA_DIR"
ok "$DATA_DIR e $PROJECTS_DIR"

# ─── Configuração ─────────────────────────────────────────────────────────
msg "Configuração"
if [ -f "$CONF" ]; then
    ok "$CONF já existe; mantido"
else
    IP=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

    # O proxy roda em container e alcança o painel pelo IP da ponte. Fixar o
    # 172.17.0.1 seria chute: o Docker usa outra faixa quando essa conflita
    # com a rede local.
    BRIDGE_IP=$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -n "$BRIDGE_IP" ] || BRIDGE_IP=172.17.0.1
    # nip.io resolve qualquer IP como subdomínio, e o Let's Encrypt emite
    # certificado para ele. Dá HTTPS real sem precisar registrar domínio —
    # que o GitHub exige tanto para o webhook quanto para o runner baixar os
    # arquivos de build.
    # DM_HOST permite instalar já com o domínio final, evitando emitir um
    # certificado para o nip.io que ninguém vai usar.
    HOST_PADRAO="${DM_HOST:-${IP//./-}.nip.io}"

    cat > "$CONF" <<EOF
# Cifra os secrets guardados no banco.
# ATENÇÃO: trocar esta chave torna ilegível tudo que já foi cifrado.
DM_ENCRYPTION_KEY=$(openssl rand -hex 32)

# Endereço público desta instalação. Precisa ser alcançável pelo GitHub, tanto
# para o webhook quanto para o runner baixar os Dockerfiles.
DM_PUBLIC_URL=https://${HOST_PADRAO}

# O painel escuta no IP da ponte do Docker, e não em 0.0.0.0: esse endereço é
# alcançável pelo host e pelos containers (é por ele que o proxy chega até
# aqui), mas não pela internet. Expor a porta publicamente faria a senha
# trafegar em claro.
DM_ADDR=${BRIDGE_IP}:8080

DM_DATA_DIR=${DATA_DIR}
DM_PROJECTS_ROOT=${PROJECTS_DIR}
TZ=America/Sao_Paulo
EOF
    chmod 600 "$CONF"
    chown root:root "$CONF"
    ok "$CONF criado (endereço: https://${HOST_PADRAO})"
fi

# ─── Rotação do registro de acesso ────────────────────────────────────────
# O proxy grava uma linha por requisição. Num site com tráfego isso enche o
# disco pelo mesmo caminho que o log dos containers enchia — e o copytruncate
# evita mandar sinal ao Traefik para reabrir o arquivo.
msg "Rotação do registro de acesso"
cat > /etc/logrotate.d/dockermanager-traefik <<ROT
${DATA_DIR}/traefik/registro/acesso.log {
    daily
    rotate 7
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
ROT
ok "configurada (50 MB ou 1 dia, 7 arquivos)"

# ─── Serviço ──────────────────────────────────────────────────────────────
msg "Serviço"
cat > /etc/systemd/system/dockermanager.service <<'UNIT'
[Unit]
Description=DockerManager
# Sem o daemon do Docker o painel abre mas não gerencia nada.
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/dockermanager/dockermanager
EnvironmentFile=/etc/dockermanager/dm.env

# Restart=always é também o mecanismo de atualização: o painel troca o
# binário e encerra; o systemd o traz de volta já na versão nova. Assim não
# precisa de privilégio para chamar systemctl.
Restart=always
RestartSec=2s

User=dockermanager
Group=docker

# Encerramento gracioso: o SIGTERM inicia o shutdown do servidor HTTP, e o
# tempo generoso evita cortar um deploy ou um dump de backup pela metade.
KillSignal=SIGTERM
TimeoutStopSec=120

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/dockermanager /opt/dockermanager
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable dockermanager >/dev/null 2>&1
systemctl restart dockermanager
sleep 3

if systemctl is-active --quiet dockermanager; then
    ok "no ar"
else
    journalctl -u dockermanager -n 20 --no-pager
    die "o serviço não subiu (log acima)."
fi

# ─── Proxy e certificado ──────────────────────────────────────────────────
# Publicar aqui, e não como passo separado, porque sem isso o painel só é
# alcançável por túnel SSH — e um painel que exige túnel para o primeiro
# acesso não terminou de instalar.
#
# O comando é idempotente: reexecutar o instalador reescreve a rota e não
# reemite certificado válido.
if [ "${DM_SEM_PUBLICAR:-}" = "1" ]; then
    msg "Proxy"
    warn "pulado por DM_SEM_PUBLICAR=1"
else
    msg "Proxy e certificado"
    if "$BIN" --publicar-painel; then
        ok "painel publicado"
    else
        warn "não consegui publicar agora; o painel segue acessível por túnel SSH"
        warn "tente depois com: dockermanager --publicar-painel"
    fi
fi

# ─── Fim ──────────────────────────────────────────────────────────────────
PUBLIC=$(grep -E '^DM_PUBLIC_URL=' "$CONF" | cut -d= -f2-)
# O endereço vem do arquivo, e não fixo no texto: o painel escuta no IP da
# ponte do Docker, que varia por máquina. Instruir o túnel para 127.0.0.1
# entregava um comando que não conecta.
ADDR=$(grep -E '^DM_ADDR=' "$CONF" | cut -d= -f2-)

cat <<FIM

────────────────────────────────────────────────────────────
 Instalado.

   Endereço    ${PUBLIC}
   Log         journalctl -u dockermanager -f
   Reiniciar   systemctl restart dockermanager
   Config      ${CONF}

 O certificado é emitido no primeiro acesso e leva alguns segundos.
 Se o navegador reclamar logo de cara, aguarde e recarregue.

 Para o certificado sair, o domínio precisa apontar para esta máquina e as
 portas 80 e 443 precisam estar abertas.

 Se preferir não expor o painel, use um túnel:

   ssh -L 8080:${ADDR} root@<ip-desta-vps>
   e abra http://localhost:8080
────────────────────────────────────────────────────────────

FIM
