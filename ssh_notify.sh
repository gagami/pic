#!/bin/bash
# ============================================================
# 自动发送 SSH 登录通知到 Telegram
# ============================================================

# 读取 .env 文件中的环境变量
source ssh_notify.sh.env

# 获取信息
HOSTNAME=$(hostname)
USER=$(whoami)
LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")

# 从 auth.log 提取 SSH 登录的用户的 IP 地址，查找包含 'Accepted' 的行
IP_ADDR=$(grep 'sshd' /var/log/auth.log | grep 'Accepted' | tail -n 1 | sed -E 's/.*from ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/')

# 判断是否为内网 IP 地址
if [[ "$IP_ADDR" =~ ^192\.168\.[0-9]+\.[0-9]+$ || "$IP_ADDR" =~ ^10\.[0-9]+\.[0-9]+\.[0-9]+$ || "$IP_ADDR" =~ ^172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+$ ]]; then
    GEO_INFO="内网"
    COUNTRY="内网"
else
    # 获取地理位置，设置超时时间为 5 秒
    GEO_INFO=$(curl -s --max-time 5 https://ipinfo.io/${IP_ADDR}/city)
    COUNTRY=$(curl -s --max-time 5 https://ipinfo.io/${IP_ADDR}/country)

    # 如果获取失败，则设置为 "未知"
    if [[ -z "$GEO_INFO" || -z "$COUNTRY" ]]; then
        GEO_INFO="未知"
        COUNTRY="未知"
    fi
fi

# 使用 printf 构建消息，确保换行符正确
MESSAGE=$(printf "🚀 **SSH 登录通知**\n\n🖥️ **主机名**: %s\n👤 **用户**: %s\n🌐 **登录 IP**: %s\n📍 **位置**: %s\n⏰ **登录时间**: %s" \
    "$HOSTNAME" "$USER" "$IP_ADDR" "$GEO_INFO" "$LOGIN_TIME")

# 发送消息到 Telegram 并捕获响应
RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d text="$MESSAGE" \
    -d parse_mode="Markdown")

