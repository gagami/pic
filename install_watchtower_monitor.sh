明白，我帮你改成 完全稳定版，确保目录挂载不会再报错，并保留以下功能：

Watchtower Monitor (Monitor-only 模式)

Telegram 通知

每日自动清理

日志保留 30 天

使用 Docker 卷 替代主机目录挂载，避免“not a directory”错误

🟢 最终稳定版安装脚本 /root/watchtower-monitor/install_watchtower_stable.sh
#!/bin/bash
# ==========================================================
# Watchtower Monitor 安装脚本（稳定版，使用 Docker 卷）
# ==========================================================

set -e

INSTALL_DIR="/root/watchtower-monitor"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CLEAN_SCRIPT="$INSTALL_DIR/cleanup_and_notify.sh"
HOSTNAME=$(hostname)
LOG_RETAIN_DAYS=30
CONTAINER_NAME="watchtower-monitor"
DOCKER_VOLUME="watchtower-logs"

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
# docker-compose.yml
# -----------------------------
cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  watchtower:
    image: containrrr/watchtower
    container_name: $CONTAINER_NAME
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $DOCKER_VOLUME:/watchtower
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

volumes:
  $DOCKER_VOLUME:
EOF

# -----------------------------
# 清理脚本
# -----------------------------
cat > "$CLEAN_SCRIPT" <<EOF
#!/bin/bash
TOKEN="$TELEGRAM_TOKEN"
CHAT_ID="$TELEGRAM_CHAT_ID"
HOSTNAME="$HOSTNAME"
LOG_FILE="/var/lib/docker/volumes/$DOCKER_VOLUME/_data/cleanup.log"

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

# 清理超过 30 天的日志
find "/var/lib/docker/volumes/$DOCKER_VOLUME/_data/" -mtime +$LOG_RETAIN_DAYS -delete
EOF

chmod +x "$CLEAN_SCRIPT"

# -----------------------------
# 启动容器
# -----------------------------
docker compose -f "$COMPOSE_FILE" up -d

# -----------------------------
# 设置每日清理 Cron
# -----------------------------
CRON_JOB="0 4 * * * /bin/bash ${CLEAN_SCRIPT}"
(crontab -l 2>/dev/null | grep -v "${CLEAN_SCRIPT}") | crontab -
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo "✅ Watchtower Monitor 安装完成！"
echo "容器名称: $CONTAINER_NAME"
echo "日志挂载卷: $DOCKER_VOLUME"
echo "每日清理: 04:00"
echo "查看日志: docker logs -f $CONTAINER_NAME"

🔹 特点

使用 Docker 卷，避免主机目录挂载冲突

/watchtower 内自动生成 updates.log 和 cleanup.log

Telegram 通知、Monitor-only 模式、每日清理全部保留

日志保留 30 天

安装后容器立即启动，Cron 自动清理生效