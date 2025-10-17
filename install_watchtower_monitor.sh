#!/bin/bash
# ==========================================================
# Watchtower Monitor 安装脚本 v12.2
# （Monitor-only + Telegram 通知 + 日志卷 + HTML 状态报告）
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
echo " Watchtower Monitor 安装脚本 v12.2 "
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
      WATCHTOWER_NOTIFICATION_SHOUTRRR_URL: "telegram://$TELEGRAM_TOKEN@$TELEGRAM_CHAT_ID?text=$NOTIFY_TEXT_ENCODED&parse_mode=HTML"
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
# 清理脚本（仅删除日志文件，去掉 system prune）
# -----------------------------
cat > "$CLEAN_SCRIPT" <<EOF
#!/bin/bash
TOKEN="$TELEGRAM_TOKEN"
CHAT_ID="$TELEGRAM_CHAT_ID"
HOSTNAME="$HOSTNAME"
LOG_FILE="/var/lib/docker/volumes/$VOLUME_NAME/_data/cleanup.log"

mkdir -p "\$(dirname "\$LOG_FILE")"

{
  echo "=============================="
  echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 执行 Docker 日志清理"
  BEFORE=\$(df -h / | awk 'NR==2 {print \$4}')
  echo "当前剩余空间: \$BEFORE"
  echo "删除30天前的日志文件..."
  find "/var/lib/docker/volumes/$VOLUME_NAME/_data/" -type f -mtime +30 -delete
  AFTER=\$(df -h / | awk 'NR==2 {print \$4}')
  echo "执行后剩余空间: \$AFTER"
  echo "=============================="
} >> "\$LOG_FILE" 2>&1

MESSAGE="<b>🧹 Docker 日志清理报告</b><br><b>主机:</b> \$HOSTNAME<br><b>执行时间:</b> \$(date '+%Y-%m-%d %H:%M:%S')<br>清理前剩余空间: \$BEFORE<br>清理后剩余空间: \$AFTER<br>日志位置: \$LOG_FILE"

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \
     -d chat_id="\$CHAT_ID" \
     -d text="\$MESSAGE" \
     -d parse_mode="HTML" >/dev/null 2>&1
EOF

chmod 700 "$CLEAN_SCRIPT"

# -----------------------------
# 状态报告脚本（HTML + <pre> 表格显示）
# -----------------------------
cat > "$STATUS_SCRIPT" <<EOF
#!/bin/bash
TOKEN="$TELEGRAM_TOKEN"
CHAT_ID="$TELEGRAM_CHAT_ID"
HOSTNAME="$HOSTNAME"

# Docker 容器状态，固定宽度格式化
STATUS=\$(docker ps -a --format "%-25.25N %-35.35S %-20.20I")

# HTML 消息，<pre> 保留表格格式
MESSAGE="<b>📊 Docker 容器状态报告</b><br>主机: \$HOSTNAME<br>执行时间: \$(date '+%Y-%m-%d %H:%M:%S')<br><pre>\$STATUS</pre>"

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \
     -d chat_id="\$CHAT_ID" \
     -d text="\$MESSAGE" \
     -d parse_mode="HTML" >/dev/null 2>&1
EOF

chmod 700 "$STATUS_SCRIPT"

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

# 清除旧记录后重新写入
(
  crontab -l 2>/dev/null | grep -v "${STATUS_SCRIPT}" | grep -v "${CLEAN_SCRIPT}" || true
  echo "$CRON_STATUS"
  echo "$CRON_CLEAN"
) | crontab -

echo
echo "✅ Watchtower Monitor 安装完成！"
echo "容器名称: $CONTAINER_NAME"
echo "日志卷: $VOLUME_NAME"
echo "首次启动立即检测并发送状态报告: ✅"
echo "每日检测时间: 03:00"
echo "每日日志清理时间: 04:00"
echo "查看运行日志: docker logs -f $CONTAINER_NAME"
