#!/bin/bash
# ==========================================================
# Watchtower Monitor 安装脚本（最终稳定版 v2）
# 兼容 Watchtower 1.7+ Shoutrrr Telegram & 新模板
# ==========================================================

set -e

INSTALL_DIR="/root/watchtower-monitor"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CLEAN_SCRIPT="$INSTALL_DIR/cleanup_and_notify.sh"
HOSTNAME=$(hostname)
LOG_RETAIN_DAYS=30
CONTAINER_NAME="watchtower-monitor"
VOLUME_NAME="watchtower_logs_volume"

echo "=============================="
echo " Watchtower Monitor 安装脚本 "
echo "=============================="

# -----------------------------
# 获取 Telegram 配置
# -----------------------------
read -rp "请输入 Telegram Bot Token: " TELEGRAM_TOKEN
read -rp "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID

# -----------------------------
# 创建安装目录
# -----------------------------
mkdir -p "$INSTALL_DIR"

# -----------------------------
# 删除旧容器和卷，避免挂载冲突
# -----------------------------
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker volume rm "$VOLUME_NAME" 2>/dev/null || true

# -----------------------------
# docker-compose.yml
# -----------------------------
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
      WATCHTOWER_NOTIFICATION_SHOUTRRR_URL: "telegram://$TELEGRAM_TOKEN@$TELEGRAM_CHAT_ID"
      WATCHTOWER_SCHEDULE: "0 3 * * *"   # 每天凌晨 03:00
      WATCHTOWER_MONITOR_ONLY: "true"
      WATCHTOWER_DEBUG: "true"
      WATCHTOWER_INCLUDE_STOPPED: "true"
      WATCHTOWER_INCLUDE_RESTARTING: "true"
      WATCHTOWER_NOTIFICATION_TITLETAG: "[Server:$HOSTNAME]"
      WATCHTOWER_NOTIFICATION_TEMPLATE: |
        🚀 容器事件通知 🚀
        主机: {{ .Hostname }}
        容器: {{ .ContainerName }}
        镜像: {{ .ImageName }}
        状态: {{ .State }}
        旧版: {{ .CurrentImageID }}
        新版: {{ .NewImageID }}
        镜像构建时间: {{ .ImageCreatedAt }}
        检测时间: {{ .UpdatedAt }}
        模式: Monitor-only (仅检测)
    command: --no-color

volumes:
  $VOLUME_NAME:
EOF

# -----------------------------
# 清理脚本
# -----------------------------
cat > "$CLEAN_SCRIPT" <<EOF
#!/bin/bash
TOKEN="$TELEGRAM_TOKEN"
CHAT_ID="$TELEGRAM_CHAT_ID"
HOSTNAME="$HOSTNAME"
LOG_FILE="/var/lib/docker/volumes/$VOLUME_NAME/_data/cleanup.log"

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

# Telegram 清理报告
MESSAGE="🧹 *Docker 清理报告*%0A主机: \$HOSTNAME%0A执行时间: \$(date '+%Y-%m-%d %H:%M:%S')%0A清理前剩余空间: \$BEFORE%0A清理后剩余空间: \$AFTER%0A日志位置: \$LOG_FILE"
curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" -d chat_id="\$CHAT_ID" -d text="\$MESSAGE" -d parse_mode="Markdown" >/dev/null 2>&1

# 删除超过 30 天日志
find "/var/lib/docker/volumes/$VOLUME_NAME/_data/" -mtime +$LOG_RETAIN_DAYS -delete
EOF

chmod +x "$CLEAN_SCRIPT"

# -----------------------------
# 启动 Watchtower Monitor
# -----------------------------
cd "$INSTALL_DIR"
docker compose up -d

# -----------------------------
# 设置每日清理 Cron（凌晨 04:00）
# -----------------------------
CRON_JOB="0 4 * * * /bin/bash ${CLEAN_SCRIPT}"
(crontab -l 2>/dev/null | grep -v "${CLEAN_SCRIPT}") | crontab -
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo "✅ Watchtower Monitor 安装完成！"
echo "容器名称: $CONTAINER_NAME"
echo "日志卷: $VOLUME_NAME"
echo "每日检测时间: 03:00"
echo "每日清理时间: 04:00"
echo "查看运行日志: docker logs -f $CONTAINER_NAME"
