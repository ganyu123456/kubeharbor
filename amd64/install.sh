#!/usr/bin/env bash
set -euo pipefail

# Harbor 一键部署脚本（amd64 完全离线版）
#
# 说明:
#   - Docker / docker-compose-plugin：若未安装则从安装包内置的离线文件自动安装（无需联网）
#   - openssl：若未安装则尝试系统包管理器安装（极少数情况需要，大多数 Linux 发行版已自带）
#   - Harbor 镜像：已内置于安装包（harbor.v*.tgz）
#   - TLS 证书：自动签发自签名证书，直接启用 HTTPS
#
# 用法:
#   sudo bash install.sh                          # 自动检测本机 IP，HTTPS 默认 443
#   sudo bash install.sh 192.168.1.100            # 指定 IP，HTTPS 443
#   sudo bash install.sh 192.168.1.100 8443       # 指定 IP 和 HTTPS 端口
#   sudo bash install.sh --domain harbor.local    # 使用域名
#
# 前置条件:
#   - Linux x86_64（Ubuntu 20.04+ / Debian 11+ / CentOS 7+ / RHEL 8+）
#   - root 权限
#   - 无需联网（完全离线）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="${SCRIPT_DIR}/offline"
HARBOR_YML="${SCRIPT_DIR}/harbor.yml"
HARBOR_TMPL="${SCRIPT_DIR}/harbor.yml.tmpl"
DATA_DIR="/opt/harbor-data"
CERT_DIR="/opt/harbor-data/cert"
HTTPS_PORT="443"
HOST_IP=""
HOST_DOMAIN=""

# ── 颜色 & 日志 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}[$*]${NC}"; }

# ── 必须以 root 运行 ────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "请使用 root 权限运行: sudo bash install.sh"

# ── 架构检查 ────────────────────────────────────────────────────────────────────
ARCH=$(uname -m)
[[ "$ARCH" != "x86_64" ]] && error "此包仅支持 amd64/x86_64，当前架构: $ARCH"

# ── 参数解析 ────────────────────────────────────────────────────────────────────
_prev_arg=""
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      echo "用法: sudo bash install.sh [IP|域名] [HTTPS端口]"
      echo "      sudo bash install.sh --domain harbor.local 8443"
      exit 0 ;;
    --domain=*) HOST_DOMAIN="${arg#--domain=}" ;;
    --domain)   _prev_arg="domain" ;;
    [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*) HOST_IP="$arg" ;;
    [0-9]*)
      if [ "$_prev_arg" = "domain" ]; then
        HOST_DOMAIN="$arg"; _prev_arg=""
      else
        HTTPS_PORT="$arg"
      fi ;;
    *)
      if [ "$_prev_arg" = "domain" ]; then
        HOST_DOMAIN="$arg"; _prev_arg=""
      fi ;;
  esac
done

# ── 自动检测本机 IP（Linux） ────────────────────────────────────────────────────
if [ -z "$HOST_IP" ] && [ -z "$HOST_DOMAIN" ]; then
  HOST_IP=$(ip route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' \
    || hostname -I 2>/dev/null | awk '{print $1}' \
    || echo "")
fi

HOST="${HOST_DOMAIN:-$HOST_IP}"
[ -z "$HOST" ] && error "无法自动检测本机 IP，请手动指定: sudo bash install.sh <IP地址>"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    Harbor 一键部署脚本  (amd64 离线版)       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "  主机地址  : $HOST"
echo "  HTTPS 端口: $HTTPS_PORT"
echo "  数据目录  : $DATA_DIR"
echo "  离线包目录: $OFFLINE_DIR"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1/6  安装 Docker（完全离线，使用内置静态二进制包）
# ═══════════════════════════════════════════════════════════════════════════════
step "1/6  检查并安装 Docker（离线）"

_install_docker_offline() {
  local docker_tgz
  docker_tgz=$(ls "${OFFLINE_DIR}"/docker-*.tgz 2>/dev/null | head -1 || echo "")
  [ -z "$docker_tgz" ] && error "离线 Docker 包未找到: ${OFFLINE_DIR}/docker-*.tgz，请确认安装包完整"

  info "正在安装 Docker（离线静态包）: $(basename "$docker_tgz")"
  tar xzf "$docker_tgz" -C /tmp/
  cp /tmp/docker/* /usr/local/bin/
  rm -rf /tmp/docker
  hash -r

  # 创建 docker 用户组
  getent group docker &>/dev/null || groupadd docker

  # 创建 /etc/docker/daemon.json
  mkdir -p /etc/docker
  if [ ! -f /etc/docker/daemon.json ]; then
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF
  fi

  # containerd systemd 服务
  cat > /etc/systemd/system/containerd.service <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

  # docker.socket systemd 单元
  cat > /etc/systemd/system/docker.socket <<'EOF'
[Unit]
Description=Docker Socket for the API
PartOf=docker.service

[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

  # docker.service systemd 单元
  cat > /etc/systemd/system/docker.service <<'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service containerd.service
Wants=network-online.target
Requires=docker.socket containerd.service

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable containerd
  systemctl start containerd
  sleep 2
  systemctl enable docker.socket
  systemctl enable docker
  systemctl start docker
  sleep 3

  success "Docker 安装完成: $(docker --version)"
}

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  success "Docker 已运行: $(docker --version)"
else
  _install_docker_offline
fi

# ── docker-compose 插件（离线） ─────────────────────────────────────────────────
step "1/6  检查并安装 Docker Compose（离线）"
if docker compose version &>/dev/null 2>&1; then
  success "Docker Compose 已就绪: $(docker compose version --short 2>/dev/null || docker compose version)"
else
  COMPOSE_BIN=$(ls "${OFFLINE_DIR}"/docker-compose* 2>/dev/null | head -1 || echo "")
  [ -z "$COMPOSE_BIN" ] && error "离线 docker-compose 未找到: ${OFFLINE_DIR}/docker-compose*，请确认安装包完整"

  info "正在安装 docker-compose 插件（离线）..."
  mkdir -p /usr/local/lib/docker/cli-plugins/
  cp "$COMPOSE_BIN" /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

  docker compose version &>/dev/null 2>&1 || error "docker compose 安装后仍不可用，请检查"
  success "Docker Compose 安装完成: $(docker compose version --short 2>/dev/null || docker compose version)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2/6  检查 OpenSSL
# ═══════════════════════════════════════════════════════════════════════════════
step "2/6  检查 OpenSSL"

if command -v openssl &>/dev/null; then
  success "OpenSSL 已安装: $(openssl version)"
else
  warn "OpenSSL 未检测到，尝试通过包管理器安装（可能需要联网）..."
  if command -v apt-get &>/dev/null; then
    apt-get install -y -qq openssl || error "openssl 安装失败，请手动安装后重试"
  elif command -v yum &>/dev/null; then
    yum install -y openssl || error "openssl 安装失败，请手动安装后重试"
  elif command -v dnf &>/dev/null; then
    dnf install -y openssl || error "openssl 安装失败，请手动安装后重试"
  else
    error "未检测到 openssl，且无法自动安装。请手动安装 openssl 后重试"
  fi
  success "OpenSSL 安装完成: $(openssl version)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3/6  加载 Harbor 镜像（内置离线包）
# ═══════════════════════════════════════════════════════════════════════════════
step "3/6  加载 Harbor 镜像"

HARBOR_IMG_TAG="v2.13.0"
TAR_FILE=$(ls "${SCRIPT_DIR}"/harbor*.tar.gz "${SCRIPT_DIR}"/harbor*.tgz 2>/dev/null \
           | grep -v harbor.yml | head -1 || true)
[ -z "$TAR_FILE" ] && error "未在 ${SCRIPT_DIR} 找到 Harbor 镜像包（harbor*.tar.gz 或 harbor*.tgz）"

if docker image inspect "goharbor/harbor-core:${HARBOR_IMG_TAG}" &>/dev/null 2>&1; then
  success "Harbor 镜像已加载，跳过"
else
  info "正在加载 $(basename "$TAR_FILE")，请稍候（文件较大，约需几分钟）..."
  docker load -i "$TAR_FILE"
  success "镜像加载完成"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4/6  签发自签名 TLS 证书
# ═══════════════════════════════════════════════════════════════════════════════
step "4/6  签发自签名 TLS 证书"
mkdir -p "$CERT_DIR"

if [ -f "${CERT_DIR}/harbor.crt" ] && [ -f "${CERT_DIR}/harbor.key" ]; then
  success "证书已存在，跳过 (${CERT_DIR})"
else
  # SAN：IP 用 IP:，域名用 DNS:
  if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SAN="IP:${HOST}"
  else
    SAN="DNS:${HOST}"
  fi

  info "生成 CA 私钥 & 根证书..."
  openssl genrsa -out "${CERT_DIR}/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes -sha512 -days 3650 \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=Harbor/CN=${HOST}" \
    -key "${CERT_DIR}/ca.key" \
    -out "${CERT_DIR}/ca.crt" 2>/dev/null

  info "生成服务器私钥 & 证书..."
  openssl genrsa -out "${CERT_DIR}/harbor.key" 4096 2>/dev/null
  openssl req -sha512 -new \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=Harbor/CN=${HOST}" \
    -key "${CERT_DIR}/harbor.key" \
    -out "${CERT_DIR}/harbor.csr" 2>/dev/null

  cat > "${CERT_DIR}/v3.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${SAN}
EOF

  openssl x509 -req -sha512 -days 3650 \
    -extfile "${CERT_DIR}/v3.ext" \
    -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" -CAcreateserial \
    -in "${CERT_DIR}/harbor.csr" \
    -out "${CERT_DIR}/harbor.crt" 2>/dev/null

  success "证书签发完成: ${CERT_DIR}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5/6  生成 harbor.yml 配置文件
# ═══════════════════════════════════════════════════════════════════════════════
step "5/6  生成 harbor.yml 配置"

# 若 harbor.yml.tmpl 不存在，则将 harbor.yml 备份为模板（一次性）
if [ ! -f "$HARBOR_TMPL" ] && [ -f "$HARBOR_YML" ]; then
  cp "$HARBOR_YML" "$HARBOR_TMPL"
  info "已将 harbor.yml 另存为 harbor.yml.tmpl（原始模板，后续重装可重复使用）"
fi
[ -f "$HARBOR_TMPL" ] || error "未找到 harbor.yml.tmpl 或 harbor.yml，安装包可能不完整"

# 通过环境变量传参，使用 quoted heredoc 避免 bash 转义问题
export _H_HOST="$HOST"
export _H_PORT="$HTTPS_PORT"
export _H_CERT="$CERT_DIR"
export _H_DATA="$DATA_DIR"
export _H_TMPL="$HARBOR_TMPL"
export _H_YML="$HARBOR_YML"

python3 <<'PYEOF'
import os, re

host      = os.environ['_H_HOST']
port      = os.environ['_H_PORT']
cert_dir  = os.environ['_H_CERT']
data_dir  = os.environ['_H_DATA']
tmpl_path = os.environ['_H_TMPL']
yml_path  = os.environ['_H_YML']

with open(tmpl_path, 'r') as f:
    content = f.read()

# 1. hostname
content = content.replace('hostname: reg.mydomain.com', 'hostname: ' + host)

# 2. 替换 https 块（精确匹配 harbor.yml.tmpl 原始内容）
OLD_HTTPS = (
    "# https related config\n"
    "https:\n"
    "  # https port for harbor, default is 443\n"
    "  port: 443\n"
    "  # The path of cert and key files for nginx\n"
    "  certificate: /your/certificate/path\n"
    "  private_key: /your/private/key/path\n"
    "  # enable strong ssl ciphers (default: false)\n"
    "  # strong_ssl_ciphers: false"
)
NEW_HTTPS = (
    "# https related config\n"
    "https:\n"
    "  port: " + port + "\n"
    "  certificate: " + cert_dir + "/harbor.crt\n"
    "  private_key: " + cert_dir + "/harbor.key"
)
if OLD_HTTPS in content:
    content = content.replace(OLD_HTTPS, NEW_HTTPS)
else:
    # 兜底：逐行替换
    content = re.sub(r'^(\s*certificate:\s*).*', r'\g<1>' + cert_dir + '/harbor.crt', content, count=1, flags=re.MULTILINE)
    content = re.sub(r'^(\s*private_key:\s*).*',  r'\g<1>' + cert_dir + '/harbor.key',  content, count=1, flags=re.MULTILINE)

# 3. external_url 注释掉
content = re.sub(r'^(external_url:)', r'# \1', content, flags=re.MULTILINE)

# 4. data_volume
content = content.replace('data_volume: /data', 'data_volume: ' + data_dir)

with open(yml_path, 'w') as f:
    f.write(content)

print("  hostname      -> " + host)
print("  https port    -> " + port)
print("  certificate   -> " + cert_dir + "/harbor.crt")
print("  data_volume   -> " + data_dir)
PYEOF

success "harbor.yml 配置完成"

# ═══════════════════════════════════════════════════════════════════════════════
# Step 6/6  执行 prepare 并启动 Harbor
# ═══════════════════════════════════════════════════════════════════════════════
step "6/6  运行 prepare 并启动 Harbor"

chmod +x "${SCRIPT_DIR}/prepare"
info "执行 prepare（生成 nginx/db/core 等配置）..."
"${SCRIPT_DIR}/prepare"
success "prepare 完成"

info "启动 Harbor 服务..."
cd "$SCRIPT_DIR"
if docker compose ps -q 2>/dev/null | grep -q .; then
  warn "检测到已有 Harbor 实例，先停止..."
  docker compose down
fi
docker compose up -d
success "Harbor 已成功启动"

# ── 完成提示 ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✅  Harbor 部署成功！${NC}"
echo ""
echo -e "  访问地址  : ${BOLD}https://${HOST}:${HTTPS_PORT}${NC}"
echo "  用户名    : admin"
echo "  初始密码  : Harbor12345  （首次登录后请立即修改）"
echo ""
echo "  ⚠  浏览器首次访问会提示「证书不受信任」（自签名），"
echo "     点击「高级」→「继续访问」即可正常使用。"
echo ""
echo "  将 CA 根证书加入系统信任（可选，让浏览器不再提示）："
echo "    # Ubuntu / Debian："
echo "    sudo cp ${CERT_DIR}/ca.crt /usr/local/share/ca-certificates/harbor-ca.crt"
echo "    sudo update-ca-certificates"
echo "    # CentOS / RHEL："
echo "    sudo cp ${CERT_DIR}/ca.crt /etc/pki/ca-trust/source/anchors/harbor-ca.crt"
echo "    sudo update-ca-trust"
echo ""
echo "  让 Docker 信任此 Harbor（推送/拉取镜像前执行）："
echo "    sudo mkdir -p /etc/docker/certs.d/${HOST}:${HTTPS_PORT}"
echo "    sudo cp ${CERT_DIR}/ca.crt /etc/docker/certs.d/${HOST}:${HTTPS_PORT}/ca.crt"
echo "    sudo systemctl restart docker"
echo ""
echo "  数据目录  : $DATA_DIR"
echo "  查看日志  : docker compose -f ${SCRIPT_DIR}/docker-compose.yml logs -f"
echo "  停止服务  : docker compose -f ${SCRIPT_DIR}/docker-compose.yml down"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
