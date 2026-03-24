#!/usr/bin/env bash
set -euo pipefail

# Harbor Mac 本地一键部署脚本（离线 arm64）
#
# 用法:
#   bash deploy-local.sh                     # 自动检测 IP，HTTPS 端口默认 443
#   bash deploy-local.sh 192.168.1.100       # 指定 IP，HTTPS 端口默认 443
#   bash deploy-local.sh 192.168.1.100 8443  # 指定 IP 和 HTTPS 端口
#   bash deploy-local.sh --http              # 纯 HTTP 模式，端口 8090，无需证书
#
# 说明:
#   - 证书和数据目录统一放在 ~/harbor-data（Docker Desktop 可直接挂载）
#   - 原始 harbor.yml 会备份为 harbor.yml.bak，不会丢失

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARBOR_YML="$SCRIPT_DIR/harbor.yml"
DATA_DIR="$HOME/harbor-data"
CERT_DIR="$DATA_DIR/cert"

# ── 颜色输出 ──────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}$*${NC}"; }

# ── 参数解析 ──────────────────────────────────────────────
HTTP_ONLY=false
HOST_IP=""
HTTPS_PORT="443"

for arg in "$@"; do
  case "$arg" in
    --http) HTTP_ONLY=true ;;
    --help)
      echo "用法: bash deploy-local.sh [IP] [HTTPS端口]"
      echo "      bash deploy-local.sh --http  # 纯 HTTP 模式"
      exit 0 ;;
    [0-9]*.[0-9]*.[0-9]*.[0-9]*)
      HOST_IP="$arg" ;;
    [0-9]*)
      HTTPS_PORT="$arg" ;;
  esac
done

# 自动检测本机 IP（优先 en0，再 en1）
if [ -z "$HOST_IP" ]; then
  HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || \
            ipconfig getifaddr en1 2>/dev/null || \
            ipconfig getifaddr en2 2>/dev/null || echo "")
fi

[ -z "$HOST_IP" ] && error "无法自动检测本机 IP，请手动指定: bash deploy-local.sh <IP地址>"

echo -e "${BOLD}=== Harbor Mac 本地部署 ===${NC}"
echo "  IP 地址  : $HOST_IP"
if $HTTP_ONLY; then
  echo "  模式     : HTTP (端口 8090)"
else
  echo "  HTTPS 端口: $HTTPS_PORT"
fi
echo "  数据目录 : $DATA_DIR"
echo ""

# ── 检查依赖 ──────────────────────────────────────────────
step "[依赖检查]"
command -v docker &>/dev/null   || error "请先安装并启动 Docker Desktop"
docker info &>/dev/null 2>&1    || error "Docker 未运行，请启动 Docker Desktop"
command -v openssl &>/dev/null  || error "未找到 openssl，请执行: brew install openssl"
success "依赖检查通过"

# ── Step 1: 加载镜像 ──────────────────────────────────────
step "[1/5] 加载 Harbor 离线镜像"
TAR_FILE=$(ls "$SCRIPT_DIR"/harbor*.tar.gz 2>/dev/null | head -1 || true)
[ -z "$TAR_FILE" ] && error "未在 $SCRIPT_DIR 找到 harbor*.tar.gz 镜像文件"

if docker image inspect goharbor/harbor-core:v2.13.0-aarch64 &>/dev/null; then
  success "Harbor 镜像已加载，跳过"
else
  info "正在加载 $(basename "$TAR_FILE")（644MB，请等待...）"
  docker load -i "$TAR_FILE"
  success "镜像加载完成"
fi

# ── Step 2: 生成自签证书（HTTP 模式跳过） ─────────────────
if ! $HTTP_ONLY; then
  step "[2/5] 生成自签名 TLS 证书"
  mkdir -p "$CERT_DIR"

  if [ -f "$CERT_DIR/harbor.crt" ] && [ -f "$CERT_DIR/harbor.key" ]; then
    success "证书已存在，跳过生成 ($CERT_DIR)"
  else
    info "生成 CA 私钥和证书..."
    openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes -sha512 -days 3650 \
      -subj "/C=CN/ST=Local/L=Local/O=HarborTest/CN=$HOST_IP" \
      -key "$CERT_DIR/ca.key" \
      -out "$CERT_DIR/ca.crt" 2>/dev/null

    info "生成服务器证书..."
    openssl genrsa -out "$CERT_DIR/harbor.key" 4096 2>/dev/null
    openssl req -sha512 -new \
      -subj "/C=CN/ST=Local/L=Local/O=HarborTest/CN=$HOST_IP" \
      -key "$CERT_DIR/harbor.key" \
      -out "$CERT_DIR/harbor.csr" 2>/dev/null

    # SAN 扩展（IP 访问必须加，否则 x509 报错）
    cat > "$CERT_DIR/v3.ext" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:${HOST_IP}
EOF

    openssl x509 -req -sha512 -days 3650 \
      -extfile "$CERT_DIR/v3.ext" \
      -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
      -in "$CERT_DIR/harbor.csr" \
      -out "$CERT_DIR/harbor.crt" 2>/dev/null

    success "证书生成完成: $CERT_DIR"
  fi
else
  step "[2/5] HTTP 模式，跳过证书生成"
  success "已跳过"
fi

# ── Step 3: 更新 harbor.yml ──────────────────────────────
step "[3/5] 生成本地 harbor.yml 配置"

HARBOR_TMPL="$SCRIPT_DIR/harbor.yml.tmpl"
[ -f "$HARBOR_TMPL" ] || error "未找到 harbor.yml.tmpl 模板文件"

# 始终从模板生成，保证幂等性（不依赖上次修改结果）
# 将原始 harbor.yml 备份一次
if [ -f "$HARBOR_YML" ] && [ ! -f "${HARBOR_YML}.bak" ]; then
  cp "$HARBOR_YML" "${HARBOR_YML}.bak"
  info "原始配置已备份为 harbor.yml.bak"
fi

# 用 Python 从模板生成 harbor.yml
# 采用精确字符串替换（而非正则），规避 yaml 注释格式导致的匹配失败问题
python3 << PYEOF
import re

tmpl_path = "$HARBOR_TMPL"
yml_path  = "$HARBOR_YML"
host_ip   = "$HOST_IP"
https_port = "$HTTPS_PORT"
cert_dir  = "$CERT_DIR"
data_dir  = "$DATA_DIR"
http_only = $( $HTTP_ONLY && echo True || echo False )

with open(tmpl_path, 'r') as f:
    content = f.read()

# ── 1. hostname ──────────────────────────────────────────
content = content.replace('hostname: reg.mydomain.com', f'hostname: {host_ip}')

# ── 2. http port ─────────────────────────────────────────
# 模板默认 port: 80；HTTP 模式改为 8090；HTTPS 模式保持 80（用于 http→https 重定向）
if http_only:
    content = re.sub(r'^(\s*port:\s*)80(\s*$)', r'\g<1>8090\2', content, count=1, flags=re.MULTILINE)

# ── 3. https 块 ───────────────────────────────────────────
# 模板里的 https 块是有效配置（含占位路径），精确匹配原始模板文本
OLD_HTTPS = """\
# https related config
https:
  # https port for harbor, default is 443
  port: 443
  # The path of cert and key files for nginx
  certificate: /your/certificate/path
  private_key: /your/private/key/path
  # enable strong ssl ciphers (default: false)
  # strong_ssl_ciphers: false"""

if http_only:
    # HTTP 模式：删除整个 https 块
    content = content.replace(OLD_HTTPS + '\n', '')
    content = content.replace(OLD_HTTPS, '')
else:
    # HTTPS 模式：替换为真实证书路径
    NEW_HTTPS = f"""\
# https related config
https:
  port: {https_port}
  certificate: {cert_dir}/harbor.crt
  private_key: {cert_dir}/harbor.key"""
    if OLD_HTTPS in content:
        content = content.replace(OLD_HTTPS, NEW_HTTPS)
    else:
        # 兜底：先删除任何已有的 https 块，再插入
        content = re.sub(
            r'^# https related config\nhttps:\n(?:[ \t]+.*\n)*',
            '', content, flags=re.MULTILINE
        )
        https_block = (
            f"# https related config\nhttps:\n"
            f"  port: {https_port}\n"
            f"  certificate: {cert_dir}/harbor.crt\n"
            f"  private_key: {cert_dir}/harbor.key\n\n"
        )
        content = re.sub(
            r'(^http:\s*\n(?:[ \t]*#[^\n]*\n)*[ \t]*port:\s*\d+[ \t]*\n\n)',
            r'\1' + https_block,
            content, flags=re.MULTILINE
        )

# ── 4. external_url：注释掉 ───────────────────────────────
content = re.sub(r'^external_url:', '# external_url:', content, flags=re.MULTILINE)

# ── 5. data_volume ────────────────────────────────────────
content = content.replace('data_volume: /data', f'data_volume: {data_dir}')

with open(yml_path, 'w') as f:
    f.write(content)

print(f"  hostname     -> {host_ip}")
print(f"  data_volume  -> {data_dir}")
if not http_only:
    print(f"  https port   -> {https_port}")
    print(f"  certificate  -> {cert_dir}/harbor.crt")
print("  external_url -> 已注释")
PYEOF

success "harbor.yml 更新完成"

# ── Step 4: 执行 prepare ──────────────────────────────────
step "[4/5] 执行 prepare 生成配置文件"
info "运行 prepare 容器（goharbor/prepare:v2.13.0-aarch64）..."
"$SCRIPT_DIR/prepare"
success "配置文件生成完成"

# ── Step 5: 启动 Harbor ───────────────────────────────────
step "[5/5] 启动 Harbor 服务"
cd "$SCRIPT_DIR"

# 停止已有实例
if docker compose ps -q 2>/dev/null | grep -q .; then
  warn "检测到已有 Harbor 实例，先停止..."
  docker compose down
fi

docker compose up -d
success "Harbor 启动完成"

# ── 完成提示 ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✅ Harbor 部署成功！${NC}"
echo ""
if $HTTP_ONLY; then
  echo -e "  访问地址:  ${BOLD}http://$HOST_IP:8090${NC}"
else
  echo -e "  访问地址:  ${BOLD}https://$HOST_IP:$HTTPS_PORT${NC}"
  echo ""
  echo "  ⚠️  浏览器首次访问会提示证书不受信任（自签名），"
  echo "     点击「高级」→「继续访问」即可正常使用。"
  echo ""
  echo "  若需浏览器不再提示，将以下 CA 证书加入系统信任:"
  echo "  ${CERT_DIR}/ca.crt"
  echo "  命令: sudo security add-trusted-cert -d -r trustRoot \\"
  echo "          -k /Library/Keychains/System.keychain ${CERT_DIR}/ca.crt"
fi
echo ""
echo "  用户名:  admin"
echo "  密  码:  Harbor12345  （首次登录后请修改）"
echo ""
echo "  数据目录: $DATA_DIR"
echo "  查看日志: docker compose -f $SCRIPT_DIR/docker-compose.yml logs -f"
echo "  停止服务: docker compose -f $SCRIPT_DIR/docker-compose.yml down"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
