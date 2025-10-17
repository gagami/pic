#!/bin/bash
# ==========================================================
# Watchtower Monitor 安装脚本（带 Telegram 清理报告通知）
# ==========================================================

set -e

INSTALL_DIR="/root/watchtower-monitor"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
LOG_DIR="$INSTALL_DIR/logs"
CLEAN_SCRIPT="$INSTALL_DIR/cleanup_and_notify.sh"
HOSTNAME=$(hostname)

echo "=============================="
echo " Watchtower Monitor 安装脚本 "
echo "=============================="

# -----------------------------
# 获取 Telegram 配置
# -----------------------------
read -rp "请输入 Telegram Bot Token: " TELEGRAM_TOKEN
read -rp "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID

# -----------------------------
# 创建目录
# -----------------------------
mkdir -p "$LOG_DIR"

# -----------------------------
# 写入 docker-compose.yml
# -----------------------------
cat > "$COMPOSE_FILE" <<EOF
version: "3.8"

services:
  watchtower:
    image: containrrr/watchtower:1.7.1
    container_name: watchtower-monitor
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./logs:/watchtower
    environment:
      - WATCHTOWER_MONITOR_ONLY=true
      - WATCHTOWER_SCHEDULE=0 0 * * *
      - WATCHTOWER_INCLUDE_STOPPED=true
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_DEBUG=true
      - WATCHTOWER_NOTIFICATION_SHOUTRRR_URL=telegram://$TELEGRAM_TOKEN@$TELEGRAM_CHAT_ID?text=🚀+Watchtower+Monitor+已完成检测！+主机:$HOSTNAME
    command: --no-color
EOF

# -----------------------------
# 创建清理脚本
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

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \
     -d chat_id="\$CHAT_ID" \
     -d text="🧹 Docker 清理报告%0A主机: \$HOSTNAME%0A清理前剩余空间: \$BEFORE%0A清理后剩余空间: \$AFTER%0A日志位置: \$LOG_FILE" \
     -d parse_mode="Markdown" >/dev/null 2>&1

# 清理超过 30 天的旧日志
find "$LOG_DIR" -mtime +30 -delete
EOF
chmod +x "$CLEAN_SCRIPT"

# -----------------------------
# 启动 Watchtower
# -----------------------------
cd "$INSTALL_DIR"
docker compose up -d

# -----------------------------
# 设置每日清理任务
# -----------------------------
CRON_JOB="0 4 * * * /bin/bash $CLEAN_SCRIPT"
(crontab -l 2>/dev/null | grep -v "cleanup_and_notify.sh") | crontab -
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

# -----------------------------
# 提示信息
# -----------------------------
echo
echo "✅ Watchtower Monitor 部署完成！"
echo "----------------------------------------"
echo "📁 配置目录: $INSTALL_DIR"
echo "🕐 检测频率: 每天 00:00"
echo "📲 Telegram 通知: 已启用"
echo "🧩 容器名称: watchtower-monitor"
echo "🗒️ 日志目录: $LOG_DIR"
echo "🧹 每日清理时间: 04:00"
echo "----------------------------------------"
echo "查看运行日志命令:"
echo "  docker logs -f watchtower-monitor"
echo "----------------------------------------"
