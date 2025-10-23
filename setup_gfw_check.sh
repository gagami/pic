#!/bin/bash

#=======================================================
# 自动安装 GFW 出站检测脚本并设置 Cron 任务
# (V2 - 已修改为“仅屏蔽时通知，恢复时不通知”)
#=======================================================

# --- 变量定义 ---
SCRIPT_PATH="/root/gfw_check_outbound.sh"
CONFIG_FILE="/etc/profile.d/ssh_notify.sh.env"

# 1. 检查是否为 Root 用户
if [ "$(id -u)" -ne 0 ]; then
   echo "错误: 此脚本必须以 root 用户身份运行。"
   exit 1
fi

# 2. 检查并安装依赖 (静默)
if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null || ! command -v nc &> /dev/null; then
    echo "正在检查并安装依赖 (curl, jq, netcat)..."
    if command -v apt-get &> /dev/null; then
        apt-get update > /dev/null
        apt-get install -y curl jq netcat-openbsd
    elif command -v yum &> /dev/null;
        yum install -y curl jq nc
    else
        echo "无法自动安装依赖。请手动安装 curl, jq, nc 后重试。"
        exit 1
    fi
    echo "依赖安装完毕。"
fi

# 3. 检查配置文件是否存在 (只警告)
if [ ! -f "$CONFIG_FILE" ]; then
    echo "---"
    echo "警告: 配置文件 $CONFIG_FILE 未找到。"
    echo "脚本 $SCRIPT_PATH 将会创建，但它在运行时会失败。"
    echo "请务必在运行前创建该文件并填入:"
    echo "TELEGRAM_TOKEN=xxxxx"
    echo "TELEGRAM_CHAT_ID=xxxx"
    echo "---"
    echo "5 秒后继续..."
    sleep 5
fi

# 4. 创建 GFW 检测脚本 (已修改通知逻辑)
echo "正在创建或覆盖 $SCRIPT_PATH..."

# 使用 'EOF' (带单引号) 来防止变量在创建时被展开
cat << 'EOF' > $SCRIPT_PATH
#!/bin/bash

#=======================================================
# GFW 屏蔽检测与 Telegram 通知脚本 (V3.1 - 仅屏蔽时通知)
#
# !! 警告 !!
# 此脚本通过检测 [VPS -> 中国] 的出站连通性来猜测是否被墙。
# 这是一个不准确的方法，GFW 经常只封锁 [中国 -> VPS] 的入站连接。
#
#=======================================================

# --- (1) 配置文件路径 ---
CONFIG_FILE="/etc/profile.d/ssh_notify.sh.env"

# --- (2) 检测配置 ---
FAIL_THRESHOLD=90
TARGETS=(
    "223.5.5.5:53"      # AliDNS
    "119.29.29.29:53"   # TencentDNS (DNSPod)
    "baidu.com:80"      # Baidu Web
    "qq.com:80"         # Tencent Web
    "163.com:80"        # Netease Web
)

# --- (3) 状态文件 ---
STATUS_FILE="/tmp/gfw_outbound_blocked.flag"

# --- (4) 加载和验证配置 ---
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    exit 1
fi
if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    exit 1
fi

# --- (5) Telegram 发送函数 ---
send_tg_notification() {
    local MESSAGE="$1"
    local MESSAGE_URLENCODED=$(printf "%s" "$MESSAGE" | jq -s -R -r @uri)
    local API_URL="https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage"
    curl -s -m 10 -X POST "$API_URL" -d chat_id="${TELEGRAM_CHAT_ID}" -d text="${MESSAGE_URLENCODED}" > /dev/null
}

# --- (6) 主检测逻辑 ---
if ! command -v nc &> /dev/null || ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
    exit 1
fi
MY_IP=$(curl -s ifconfig.me)
if [ -z "$MY_IP" ]; then
    exit 1
fi

TOTAL_TARGETS=${#TARGETS[@]}
FAILED_TARGETS=0
if [ "$TOTAL_TARGETS" -eq 0 ]; then
    exit 0
fi

for target in "${TARGETS[@]}"; do
    host=$(echo $target | cut -d: -f1)
    port=$(echo $target | cut -d: -f2)
    nc -z -v -w 3 $host $port &> /dev/null
    if [ $? -ne 0 ]; then
        FAILED_TARGETS=$((FAILED_TARGETS + 1))
    fi
done

FAILURE_RATE=$((FAILED_TARGETS * 100 / TOTAL_TARGETS))
SUCCESS_COUNT=$((TOTAL_TARGETS - FAILED_TARGETS))

# --- (7) 判断与通知 (修改版：恢复时不通知) ---
if [ "$FAILURE_RATE" -ge "$FAIL_THRESHOLD" ]; then
    # 判定为被墙
    
    # 检查状态文件，如果文件不存在，说明是首次检测到屏蔽
    if [ ! -f "$STATUS_FILE" ]; then
        # echo "状态: 首次检测到出站屏蔽，发送通知..."
        MSG="🚨 警告：你的 VPS (IP: $MY_IP) [出站] 访问中国大陆可能已被 GFW 屏蔽！\n\n出站连通性测试: $SUCCESS_COUNT / $TOTAL_TARGETS 成功 (失败率: $FAILURE_RATE%)。\n\n(注意: 这通常意味着双向封锁)"
        send_tg_notification "$MSG"
        # 创建状态文件，防止重复通知
        touch "$STATUS_FILE"
    # else
        # "状态: 已处于出站屏蔽状态，本次不重复通知。"
    fi
else
    # 判定为正常
    
    # 检查状态文件，如果文件存在，说明是从“被墙”恢复了
    if [ -f "$STATUS_FILE" ]; then
        # echo "状态: 从出站屏蔽状态恢复，静默处理。"
        # (用户要求：恢复时不需要通知)
        # 只删除状态文件，为下次屏蔽做准备
        rm -f "$STATUS_FILE"
    # else
        # "状态: 持续正常 (出站)。"
    fi
fi
EOF

# 5. 设置权限
echo "正在设置执行权限..."
chmod +x $SCRIPT_PATH

# 6. 添加 Cron 任务
echo "正在添加/验证 crontab 计划任务..."
CRON_JOB="0 2 * * * $SCRIPT_PATH > /dev/null 2>&1"

if crontab -l 2>/dev/null | grep -Fq "$SCRIPT_PATH"; then
    echo "Cron 任务已存在，无需添加。"
else
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "Cron 任务已成功添加 (每天凌晨 2:00)。"
fi

echo "---"
echo "✅ 更新完成！"
echo "脚本 $SCRIPT_PATH 已更新为“仅屏蔽时通知”。"
echo "请确保 $CONFIG_FILE 文件配置正确。"
