#!/bin/bash
# ==========================================================
# Watchtower Monitor 安装脚本 v11（Monitor-only + Telegram 通知）
# ==========================================================

set -e

INSTALL_DIR="/root/watchtower-monitor"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CLEAN_SCRIPT="$INSTALL_DIR/cleanup_and_notify.sh"
STATUS_SCRIPT="$INSTALL_DIR/send_status_report.sh"
HOSTNAME=$(hostname)
CONTAINER_NAME="watchtower-monitor"
VOLUME_NAME="watchtower_logs_volume"

echo "=============================="
echo " Watchtower Monitor 安装脚本 v11 "
echo "=============================="

# -----------------------------
# 获取 Telegram 配置
# -----------------------------
read -rp "请输入 Telegram Bot Token: " TELEGRAM_TOKEN
read -rp "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID

# -----------------------------
# URL encode 函数
# -----------------------------
urlencode() {
    local LANG=C
    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c"
        esac
    done
}

# -----------------------------
# 创建安装目录
# -----------------------------
mkdir -p "$INSTALL_DIR"

# -----------------------------
# 删除旧容器和卷
# -----------------------------
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker volume rm "$VOLUME_NAME" 2>/dev/null || true

# -----------------------------
# docker-compose.yml
# -----------------------------
NOTIFY_TEXT="🚀 Watchtower Monitor 检测完成！主机:$HOSTNAME"
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
      WATCHTOWER_NOTIFICATION_SHOUTRRR_URL: "telegram://$TELEGRAM_TOKEN@$TELEGRAM_CHAT_ID?text=$NOTIFY_TEXT_ENCODED&parse_mode=Markdown"
      WATCHTOWER_MONITOR_ONLY: "true"
      WATCHTOWER_RUN_ONCE: "false"
      WATCHTOWER_SCHEDULE: "0 3 * * *"
      WATCHTOWER_DEBUG: "true"
      WATCHTOWER_INCLUDE_STOPPED: "true"
      WATCHTOWER_INCLUDE_RESTARTING: "true"
      WATCHTOWER_NOTIFICATION_TITLETAG: "[Server:$HOSTNAME]"
    command: --no-pull --no-color
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "7"

volumes:
  $VOLUME_NAME:
EOF

# -----------------------------
# 清理脚本
# -----------------------------
cat > "$CLEAN_SCRIPT" <<'EOF'
#!/bin/bash
TOKEN="'"$TELEGRAM_TOKEN"'"
CHAT_ID="'"$TELEGRAM_CHAT_ID"'"
HOSTNAME="'"$HOSTNAME"'"
LOG_FILE="/var/lib/docker/volumes/'"$VOLUME_NAME"'/_data/cleanup.log"

{
  echo "=============================="
  echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 开始清理 Docker 资源"
  BEFORE=\$(df -h / | awk 'NR==2 {print \$4}')
  docker system prune -af --volumes -y
  AFTER=\$(df -h / | awk 'NR==2 {print \$4}')
  echo "清理前剩余空间: \$BEFORE"
  echo "清理后剩余空间: \$AFTER"
  echo "=============================="
} >> "\$LOG_FILE" 2>&1

MESSAGE="🧹 Docker 清理报告\n主机: \$HOSTNAME\n执行时间: \$(date '+%Y-%m-%d %H:%M:%S')\n清理前剩余空间: \$BEFORE\n清理后剩余空间: \$AFTER\n日志位置: \$LOG_FILE"
curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" -d chat_id="\$CHAT_ID" -d text="\$MESSAGE" -d parse_mode="Markdown" >/dev/null 2>&1

find "/var/lib/docker/volumes/'"$VOLUME_NAME"'/_data/" -mtime +30 -delete
EOF

chmod +x "$CLEAN_SCRIPT"

# -----------------------------
# 状态报告脚本
# -----------------------------
cat > "$STATUS_SCRIPT" <<'EOF'
#!/bin/bash
TOKEN="'"$TELEGRAM_TOKEN"'"
CHAT_ID="'"$TELEGRAM_CHAT_ID"'"
HOSTNAME="'"$HOSTNAME"'"

urlencode() {
    local LANG=C
    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c"
        esac
    done
}

STATUS=$(docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}")
UPDATES=""
for CONTAINER in $(docker ps --format '{{.Names}}'); do
  IMAGE=$(docker inspect --format='{{.Config.Image}}' $CONTAINER)
  NAME=${IMAGE%%:*}
  TAG=${IMAGE##*:}
  REMOTE_DIGEST=$(curl -s "https://registry.hub.docker.com/v2/repositories/$NAME/tags/$TAG" \
    | grep -oP '"digest":"\K[^"]+' | head -n1)
  LOCAL_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' $CONTAINER 2>/dev/null | awk -F@ '{print $2}')
  if [[ -n "$REMOTE_DIGEST" && "$REMOTE_DIGEST" != "$LOCAL_DIGEST" ]]; then
    UPDATES+="$CONTAINER ($IMAGE) 可更新\n"
  fi
done

if [[ -z "$UPDATES" ]]; then
  UPDATES_MSG="✅ 当前没有可更新容器"
else
  UPDATES_MSG="⚠️ 可更新容器列表:\n$UPDATES"
fi

MESSAGE="📊 Docker 容器状态报告\n主机: $HOSTNAME\n执行时间: $(date '+%Y-%m-%d %H:%M:%S')\n\n$STATUS\n\n$UPDATES_MSG"
MESSAGE_ENCODED=$(urlencode "$MESSAGE")
curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d text="$MESSAGE_ENCODED" -d parse_mode="Markdown" >/dev/null 2>&1
EOF

chmod +x "$STATUS_SCRIPT"

# -----------------------------
# 启动 Watchtower Monitor
# -----------------------------
cd "$INSTALL_DIR"
docker compose up -d

# 首次启动立即发送状态报告
"$STATUS_SCRIPT"

# -----------------------------
# 设置每日 cron
# -----------------------------
CRON_STATUS="0 3 * * * /bin/bash ${STATUS_SCRIPT}"
CRON_CLEAN="0 4 * * * /bin/bash ${CLEAN_SCRIPT}"
(crontab -l 2>/dev/null | grep -v "${STATUS_SCRIPT}" | grep -v "${CLEAN_SCRIPT}") | crontab -
(crontab -l 2>/dev/null; echo "$CRON_STATUS"; echo "$CRON_CLEAN") | crontab -

echo "✅ Watchtower Monitor 安装完成！"
echo "容器名称: $CONTAINER_NAME"
echo "日志卷: $VOLUME_NAME"
echo "首次启动立即检测并发送状态报告: ✅"
echo "每日检测时间: 03:00"
echo "每日清理时间: 04:00"
echo "查看运行日志: docker logs -f $CONTAINER_NAME"
