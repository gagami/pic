#!/bin/bash
# ==========================================================
# Watchtower Monitor 安装脚本（修正版，环境变量字典形式）
# ==========================================================

set -e

INSTALL_DIR="/root/watchtower-monitor"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
LOG_FILE="$INSTALL_DIR/updates.log"
CLEAN_LOG="$INSTALL_DIR/cleanup.log"
CLEAN_SCRIPT="$INSTALL_DIR/cleanup_and_notify.sh"
HOSTNAME=$(hostname)
LOG_RETAIN_DAYS=30

echo "=============================="
echo " Watchtower Monitor 安装脚本 "
echo "=============================="

# -----------------------------
# 获取 Telegram 配置
# -----------------------------
echo
read -rp "请输入 Telegram Bot Token: " TELEGRAM_TOKEN
read -rp "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID

# -----------------------------
# 创建目录与配置文件
# -----------------------------
mkdir -p "$INSTALL_DIR"
touch "$LOG_FILE" "$CLEAN_LOG"

# -----------------------------
# 写入 docker-compose.yml（字典形式 environment）
# -----------------------------
cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  watchtower:
    image: containrrr/watchtower
    container_name: watchtower-monitor
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${LOG_FILE}:/watchtower/updates.log
    environment:
      WATCHTOWER_NOTIFICATIONS: "telegram"
      WATCHTOWER_NOTIFICATION_TELEGRAM_TOKEN: "${TELEGRAM_TOKEN}"
      WATCHTOWER_NOTIFICATION_TELEGRAM_CHAT_ID: "${TELEGRAM_CHAT_ID}"
      WATCHTOWER_SCHEDULE: "0 * * * *"
      WATCHTOWER_MONITOR_ONLY: "true"
      WATCHTOWER_DEBUG: "true"
      WATCHTOWER_INCLUDE_STOPPED: "true"
      WATCHTOWER_INCLUDE_RESTARTING: "true"
      WATCHTOWER_NOTIFICATION_TITLETAG: "[Server:${HOSTNAME}]"
      WATCHTOWER_NOTIFICATION_TEMPLATE: "*{{range .Entries}}🚀 容器事件通知 🚀%0A主机: ${HOSTNAME}%0A容器: {{.ContainerName}}%0A镜像: {{.ImageName}}%0A状态: {{.State}}%0A旧版: {{.CurrentImageID}}%0A新版: {{.NewImageID}}%0A镜像构建时间: {{.ImageCreatedAt}}%0A检测时间: {{.UpdatedAt}}%0A模式: Monitor-only (仅检测)%0A------------------------------------%0A📜 日志已写入 /root/watchtower-monitor/updates.log%0A{{end}}*"
    command: --no-color
EOF

# -----------------------------
# 创建清理脚本 (含 Telegram 报告)
# -----------------------------
cat > "$CLEAN_SCRIPT" <<EOF
#!/bin/bash
# ======================================================
# Docker 自动清理与 Telegram 报告脚本
# ======================================================

TOKEN="${TELEGRAM_TOKEN}"
CHAT_ID="${TELEGRAM_CHAT_ID}"
HOSTNAME="${HOSTNAME}"
LOG_FILE="${CLEAN_LOG}"

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

# 发送 Telegram 报告
MESSAGE="🧹 *Docker 清理报告*%0A\
主机: \$HOSTNAME%0A\
执行时间: \$(date '+%Y-%m-%d %H:%M:%S')%0A\
清理前剩余空间: \$BEFORE%0A\
清理后剩余空间: \$AFTER%0A\
日志位置: /root/watchtower-monitor/cleanup.log"

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \
     -d chat_id="\$CHAT_ID" \
     -d text="\$MESSAGE" \
     -d parse_mode="Markdown" >/dev/null 2>&1

# 清理超过 30 天的旧日志
find "${LOG_FILE}" -mtime +${LOG_RETAIN_DAYS} -delete
EOF
chmod +x "$CLEAN_SCRIPT"

# -----------------------------
# 启动 Watchtower 容器
# -----------------------------
echo
echo "[INFO] 启动 Watchtower Monitor 容器..."
cd "$INSTALL_DIR"
docker compose up -d

# -----------------------------
# 设置每日清理任务
# -----------------------------
echo
echo "[INFO] 设置每日自动清理任务（04:00 执行）..."
CRON_JOB="0 4 * * * /bin/bash ${CLEAN_SCRIPT}"
(crontab -l 2>/dev/null | grep -v "${CLEAN_SCRIPT}") | crontab -
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

# -----------------------------
# 提示信息
# -----------------------------
echo
echo "✅ Watchtower Monitor 部署完成（修正版）！"
echo "----------------------------------------"
echo "📁 配置目录: $INSTALL_DIR"
echo "🕐 检测频率: 每小时"
echo "📲 Telegram 通知: 已启用（含更新与清理报告）"
echo "🧩 容器名称: watchtower-monitor"
echo "🗒️ 更新日志: $LOG_FILE"
echo "🧹 每日清理时间: 凌晨 04:00"
echo "📜 清理日志: $CLEAN_LOG"
echo "🕓 日志保留天数: ${LOG_RETAIN_DAYS} 天"
echo "----------------------------------------"
echo "查看运行日志命令:"
echo "  docker logs -f watchtower-monitor"
echo "----------------------------------------"