#!/usr/bin/env bash
# =====================================================
# pi-ios Relay Server 一键部署脚本 (Ubuntu 24.04)
# 用法: 上传 relay-server/ 到服务器后:
#   chmod +x deploy.sh && sudo ./deploy.sh <你的TOKEN>
# =====================================================
set -e

TOKEN="${1:-}"
if [ -z "$TOKEN" ]; then
  echo "❌ 用法: sudo ./deploy.sh <RELAY_TOKEN>"
  echo "   生成 token: openssl rand -hex 16"
  exit 1
fi

echo "=========================================="
echo " pi-ios Relay Server 部署 (Ubuntu 24.04)"
echo "=========================================="

# 1. 安装 Node.js 20 (Ubuntu 24.04 自带 node 18，升级到 20 LTS)
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt 20 ]; then
  echo "[1/5] 安装 Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
else
  echo "[1/5] Node.js 已安装: $(node -v)"
fi

# 2. 安装依赖
echo "[2/5] 安装依赖 (npm install)..."
cd "$(dirname "$0")"
npm install --omit=dev

# 3. 安装 pm2
echo "[3/5] 安装 pm2..."
if ! command -v pm2 >/dev/null 2>&1; then
  npm install -g pm2
fi

# 4. 启动中继服务
echo "[4/5] 启动中继服务 (pm2)..."
RELAY_TOKEN="$TOKEN" pm2 start server.mjs --name pi-relay
pm2 save

# 5. 开机自启
echo "[5/5] 配置开机自启..."
pm2 startup systemd | tail -1

echo ""
echo "=========================================="
echo " ✅ 部署完成！"
echo "    服务: ws://$(hostname -I | awk '{print $1}'):3002 (内网)"
echo "    公网: 请通过 Caddy/Nginx 暴露 wss://<你的域名>"
echo "    Token: 已通过环境变量配置（不会打印）"
echo ""
echo " ⚠️  仅旧版明文部署需要公网放行 3002；推荐只开放 HTTPS/WSS 443。"
echo "=========================================="
