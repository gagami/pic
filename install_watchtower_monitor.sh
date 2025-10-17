#!/bin/bash
# ==========================================================
# Watchtower Monitor 安装脚本（最终稳定版）
# ==========================================================

set -e

INSTALL_DIR="/root/watchtower-monitor"
LOG_DIR="$INSTALL_DIR/logs"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CLEAN_SCRIPT="$INSTALL_DIR/cleanup_and_notify.sh"
HOSTNAME=$(hostname)
LOG_RETAIN_DAYS=30
CONTAINER_NAME="watchtower-monitor"

echo "=============================="
echo " Watchtower Monitor 安装脚本 "
echo "=============================="

# -----------------------------
# 获取 Telegram 配置
# -----------------------------
read -rp "请输入 Telegram Bot Token: " TELEGRAM_TOKEN
read -rp "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID

# -----------------------------
# 创建目录（确保为空目录）
# -----------------------------
mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR"/*

# -----------------------------
# 删除旧容器，确保挂载不冲突
# -----------------------------
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# -----------------------------
# docker-compose.yml
# -----------------------------
mkdir -p "$INSTALL_DIR"

cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: $CONTAINER_NAME
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $LOG_DIR:/watchtower
    environment:
      WATCHTOWER_NOTIFICATIONS: "telegram"
      WATCHTOWER_NOTIFICATION_TELEGRAM_TOKEN: "$TELEGRAM_TOKEN"
      WATCHTOWER_NOTIFICATION_TELEGRAM_CHAT_ID: "$TELEGRAM_CHAT_ID"
      WATCHTOWER_SCHEDULE: "0 * * * *"
      WATCHTOWER_MONITOR_ONLY: "true"
      WATCHTOWER_DEBUG: "true"
      WATCHTOWER_INCLUDE_STOPPED: "true"
      WATCHTOWER_INCLUDE_RESTARTING: "true"
      WATCHTOWER_NOTIFICATION_TITLETAG: "[Server:$HOSTNAME]"
      WATCHTOWER_NOTIFICATION_TEMPLATE: "*{{range .Entries}}🚀 容器事件通知 🚀%0A主机: $HOSTNAME%0A容器: {{.ContainerName}}%0A镜像: {{.ImageName}}%0A状态: {{.State}}%0A旧版: {{.CurrentImageID}}%0A新版: {{.NewImageID}}%0A镜像构建时间: {{.ImageCreatedAt}}%0A检测时间: {{.UpdatedAt}}%0A模式: Monitor-only (仅检测)%0A------------------------------------%0A📜 日志已写入 /watchtower/updates.log%0A{{end}}*"
    command: --no-color
EOF

# -----------------------------
# 清理脚本
# -----------------------------
cat > "$CLEAN_SCRIPT" <<EOF
#!/bin/bash
TOKEN="$TELEGRAM_TOKEN"
CHAT_ID="$TELEGRAM_CHAT_ID"
HOSTNAME="$HOSTNAME"
LOG_FILE="$LOG_DIR/cleanup.log"

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

# Telegram 报告
MESSAGE="🧹 *Docker 清理报告*%0A主机: \$HOSTNAME%0A执行时间: \$(date '+%Y-%m-%d %H:%M:%S')%0A清理前剩余空间: \$BEFORE%0A清理后剩余空间: \$AFTER%0A日志位置: \$LOG_FILE"
curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" -d chat_id="\$CHAT_ID" -d text="\$MESSAGE" -d parse_mode="Markdown" >/dev/null 2>&1

# 删除超过30天日志
find "$LOG_DIR" -mtime +$LOG_RETAIN_DAYS -delete
EOF

chmod +x "$CLEAN_SCRIPT"

# -----------------------------
# 启动 Watchtower Monitor
# -----------------------------
cd "$INSTALL_DIR"
docker compose up -d

# -----------------------------
# 设置每日清理 Cron
# -----------------------------
CRON_JOB="0 4 * * * /bin/bash ${CLEAN_SCRIPT}"
(crontab -l 2>/dev/null | grep -v "${CLEAN_SCRIPT}") | crontab -
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo "✅ Watchtower Monitor 安装完成！"
echo "容器名称: $CONTAINER_NAME"
echo "日志目录: $LOG_DIR"
echo "每日清理: 04:00"
echo "查看运行日志: docker logs -f $CONTAINER_NAME"
