#!/bin/bash
# ==========================================================
# Watchtower Monitor 安装脚本 v12.6 优化版
# ==========================================================
# 功能：
# ✅ 每天 03:00 检测 Docker 容器镜像更新（Monitor-only 模式）
# ✅ Telegram 状态报告（包含主机名、容器运行状态、可更新镜像高亮）
# ✅ 日志写入 /root/watchtower-monitor/_data/cleanup.log（日志清理）
# ✅ 每天凌晨 04:00 自动清理旧日志（30 天前的日志文件）
# ✅ Telegram 日志清理报告（包含清理前后剩余磁盘空间，代码块显示）
# ✅ 支持 .env 文件统一存储 Telegram Token 和 Chat ID，cron 调用脚本自动读取
# ✅ 状态报告和日志清理报告均采用 Telegram 代码块显示，风格统一、清晰可读
# ✅ 自动创建 docker-compose.yml 与日志卷，保证 Watchtower Monitor 以 Monitor-only 模式运行
# ✅ 首次启动延迟发送状态报告，保证健康状态完成
# ==========================================================

set -e

INSTALL_DIR="/root/watchtower-monitor"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CLEAN_SCRIPT="$INSTALL_DIR/cleanup_and_notify.sh"
STATUS_SCRIPT="$INSTALL_DIR/send_status_report.sh"
ENV_FILE="$INSTALL_DIR/.env"
HOSTNAME=$(hostname)
CONTAINER_NAME="watchtower-monitor"
VOLUME_NAME="watchtower_logs_volume"

echo "=============================="
echo " Watchtower Monitor 安装脚本 v12.6 优化版 "
echo "=============================="

# -----------------------------
# 获取 Telegram 配置并存 .env
# -----------------------------
read -rp "请输入 Telegram Bot Token: " TELEGRAM_TOKEN
read -rp "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID

mkdir -p "$INSTALL_DIR"

cat > "$ENV_FILE" <<EOF
TELEGRAM_TOKEN=$TELEGRAM_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF

echo ".env 文件已创建: $ENV_FILE"

# -----------------------------
# URL encode 函数（优化版）
# -----------------------------
urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [a-zA-Z0-9.~_-]) encoded+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"
               encoded+="$hex"
               ;;
        esac
    done
    echo "$encoded"
}

# -----------------------------
# 删除旧容器和卷
# -----------------------------
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker volume rm "$VOLUME_NAME" 2>/dev/null || true

# -----------------------------
# docker-compose.yml
# -----------------------------
NOTIFY_TEXT="🚀 Watchtower Monitor 已启动！主机:$HOSTNAME"
NOTIFY_TEXT_ENCODED=$(urlencode "$NOTIFY_TEXT")

cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: $CONTAINER_NAME
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $VOLUME_NAME:/watchtower_data
    environment:
      WATCHTOWER_NOTIFICATIONS: "shoutrrr"
      WATCHTOWER_NOTIFICATION_SHOUTRRR_URL: "telegram://\$TELEGRAM_TOKEN@\$TELEGRAM_CHAT_ID?text=$NOTIFY_TEXT_ENCODED&parse_mode=Markdown"
      WATCHTOWER_MONITOR_ONLY: "true"
      WATCHTOWER_RUN_ONCE: "false"
      WATCHTOWER_SCHEDULE: "0 3 * * *"
      WATCHTOWER_DEBUG: "true"
      WATCHTOWER_INCLUDE_STOPPED: "true"
      WATCHTOWER_INCLUDE_RESTARTING: "true"
      WATCHTOWER_NOTIFICATION_TITLETAG: "[Server:$HOSTNAME]"
    command: --no-color
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "7"

volumes:
  $VOLUME_NAME:
EOF

# -----------------------------
# 日志清理脚本
# -----------------------------
cat > "$CLEAN_SCRIPT" <<'EOF'
#!/bin/bash
# Docker 日志清理报告（优化版）

ENV_FILE="/root/watchtower-monitor/.env"
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo ".env 文件不存在，退出"
    exit 1
fi

HOSTNAME=$(hostname)
VOLUME_NAME="watchtower_logs_volume"
LOG_DIR="/var/lib/docker/volumes/$VOLUME_NAME/_data"
LOG_FILE="$LOG_DIR/cleanup.log"

mkdir -p "$LOG_DIR"

{
  echo "=============================="
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 执行 Docker 日志清理"
  BEFORE=$(df -h "$LOG_DIR" | awk 'NR==2 {print $4}')
  echo "当前剩余空间: $BEFORE"

  find "$LOG_DIR" -type f -mtime +30 -print -delete

  AFTER=$(df -h "$LOG_DIR" | awk 'NR==2 {print $4}')
  echo "执行后剩余空间: $AFTER"
  echo "=============================="
} >> "$LOG_FILE" 2>&1

CLEAN_LOG=$(tail -n 20 "$LOG_FILE")
MESSAGE="🧹 Docker 日志清理报告
主机: $HOSTNAME
执行时间: $(date '+%Y-%m-%d %H:%M:%S %Z')

\`\`\`
$CLEAN_LOG
\`\`\`
"

curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
     -d chat_id="$TELEGRAM_CHAT_ID" \
     -d text="$MESSAGE" \
     -d parse_mode="Markdown" >/dev/null 2>&1
EOF

chmod 700 "$CLEAN_SCRIPT"

# -----------------------------
# 状态报告脚本
# -----------------------------
cat > "$STATUS_SCRIPT" <<'EOF'
#!/bin/bash
# Docker 状态报告（优化版）

ENV_FILE="/root/watchtower-monitor/.env"
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo ".env 文件不存在，退出"
    exit 1
fi

HOSTNAME=$(hostname)

STATUS=$(docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}")

UPDATES_ARRAY=()

while read -r cid; do
    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$cid")
    LOCAL_ID=$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -F "$IMAGE" | awk '{print $2}')
    docker pull "$IMAGE" >/dev/null 2>&1
    REMOTE_ID=$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -F "$IMAGE" | awk '{print $2}')
    if [ "$LOCAL_ID" != "$REMOTE_ID" ]; then
        UPDATES_ARRAY+=("$IMAGE")
    fi
done < <(docker ps -q)

MESSAGE="📊 Docker 容器状态报告
主机: $HOSTNAME
执行时间: $(date '+%Y-%m-%d %H:%M:%S %Z')

\`\`\`
$STATUS
\`\`\`"

if [ ${#UPDATES_ARRAY[@]} -gt 0 ]; then
    MESSAGE="$MESSAGE

⚠️ 可更新镜像:
$(printf "%s\n" "${UPDATES_ARRAY[@]}")"
else
    MESSAGE="$MESSAGE

✅ 所有镜像均为最新版本"
fi

curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
     -d chat_id="$TELEGRAM_CHAT_ID" \
     -d text="$MESSAGE" \
     -d parse_mode="Markdown" >/dev/null 2>&1
EOF

chmod 700 "$STATUS_SCRIPT"

# -----------------------------
# 启动 Watchtower Monitor
# -----------------------------
cd "$INSTALL_DIR"
docker compose up -d

# -----------------------------
# 等待容器健康检查完成再发送首次状态报告
# -----------------------------
echo "⌛ 等待 Watchtower Monitor 容器启动..."
MAX_WAIT=30
INTERVAL=5
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    HEALTH_STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "starting")
    if [ "$HEALTH_STATUS" == "healthy" ] || [ "$HEALTH_STATUS" == "none" ]; then
        break
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

"$STATUS_SCRIPT"
echo "✅ 首次状态报告已发送！"

# -----------------------------
# 设置每日 cron
# -----------------------------
CRON_STATUS="0 3 * * * /bin/bash ${STATUS_SCRIPT}"
CRON_CLEAN="0 4 * * * /bin/bash ${CLEAN_SCRIPT}"

(
  crontab -l 2>/dev/null | grep -v "${STATUS_SCRIPT}" | grep -v "${CLEAN_SCRIPT}" || true
  echo "$CRON_STATUS"
  echo "$CRON_CLEAN"
) | crontab -

echo
echo "✅ Watchtower Monitor 安装完成！"
echo "容器名称: $CONTAINER_NAME"
echo "日志卷: $VOLUME_NAME"
echo "首次启动状态报告已发送: ✅"
echo "每日检测时间: 03:00"
echo "每日日志清理时间: 04:00"
echo "查看运行日志: docker logs -f $CONTAINER_NAME"
