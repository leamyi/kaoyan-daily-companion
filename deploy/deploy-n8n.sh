#!/usr/bin/env bash
# 轻量云服务器 · 一键部署 n8n（Ubuntu 22.04）
# 用法：在服务器 SSH 里执行 bash deploy-n8n.sh
set -e

# ==================== 只需改这三行 ====================
DB_PASS='CHANGE_ME_DB_PASSWORD'        # 数据库密码，随便写一串随机字符
N8N_KEY='CHANGE_ME_RANDOM_STRING'      # 加密密钥，随便写一串随机字符（重要：定下后不能再改，改了存量凭证全部失效）
MIRROR=''                              # 镜像加速地址，如 https://xxxx.mirror.aliyuncs.com
# 拿不到就留空，脚本会跳过（拉镜像可能变慢，见下方提示）
# ======================================================

if [[ "$DB_PASS" == CHANGE_ME* || "$N8N_KEY" == CHANGE_ME* ]]; then
  echo "!! 请先修改 DB_PASS 和 N8N_KEY 再执行（当前还是占位符）" >&2
  exit 1
fi

echo "===> 1/6 设置时区 Asia/Shanghai"
timedatectl set-timezone Asia/Shanghai
date

echo "===> 2/6 加 2G 虚拟内存（2G 内存必须做）"
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
free -h

echo "===> 3/6 安装 Docker（阿里云 apt 源，国内快）"
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
systemctl enable --now docker
docker --version
docker compose version

echo "===> 4/6 配置镜像加速"
if [ -n "$MIRROR" ]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": ["$MIRROR"]
}
EOF
  systemctl restart docker
  docker info | grep -A 2 "Registry Mirrors" || true
else
  echo "   未填 MIRROR，跳过（拉镜像慢的话回来补这一项）"
fi

echo "===> 5/6 写入 docker-compose.yml"
mkdir -p /root/n8n
cat > /root/n8n/docker-compose.yml <<EOF
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=${DB_PASS}
      - POSTGRES_DB=n8n
      - PGDATA=/var/lib/postgresql/data
    volumes:
      - db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h localhost -U n8n -d n8n"]
      interval: 5s
      timeout: 5s
      retries: 10
    deploy:
      resources:
        limits:
          memory: 512M

  n8n:
    image: n8nio/n8n:2.44.6
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - GENERIC_TIMEZONE=Asia/Shanghai
      - TZ=Asia/Shanghai
      - N8N_SECURE_COOKIE=false
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_ENCRYPTION_KEY=${N8N_KEY}
      - N8N_DIAGNOSTICS_ENABLED=false
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${DB_PASS}
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: 1200M

volumes:
  db_data:
  n8n_data:
EOF
echo "   已写入 /root/n8n/docker-compose.yml"

echo "===> 6/6 启动（首次拉镜像 2-5 分钟）"
cd /root/n8n
docker compose up -d
sleep 8
docker compose ps
echo
echo "================ 完成 ================"
echo "下一步：浏览器打开 http://<你的公网IP>:5678"
echo "打不开就去阿里云控制台 → 轻量服务器 → 防火墙 → 添加规则 → TCP 5678"
free -h
