#!/bin/bash

#=======================================================
# 自动安装 GFW 出站检测脚本并设置 Cron 任务
# (V2 - 已修改为“仅屏蔽时通知，恢复时不通知”)
#=======================================================

# --- 变量定义 ---
SCRIPT_PATH="/root/gfw_check_outbound.sh"
CONFIG_FILE="/etc/profile.d/ssh_notify.sh.env"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

OK="[${GREEN}✓${NC}]"
WARNING="[${YELLOW}⚠${NC}]"
ERROR="[${RED}✗${NC}]"
INFO="[${BLUE}ℹ${NC}]"

# 日志函数
log() {
    local level="$1"
    local message="$2"

    case "$level" in
        "INFO")
            echo -e "${INFO} $message"
            ;;
        "WARN")
            echo -e "${WARNING} $message"
            ;;
        "ERROR")
            echo -e "${ERROR} $message"
            ;;
        "SUCCESS")
            echo -e "${OK} $message"
            ;;
    esac
}

echo -e "${WHITE}========================================${NC}"
echo -e "${WHITE}    GFW 出站检测脚本安装工具${NC}"
echo -e "${WHITE}========================================${NC}"
echo

# 1. 检查是否为 Root 用户
if [ "$(id -u)" -ne 0 ]; then
   log "ERROR" "此脚本必须以 root 用户身份运行"
   echo "请使用: sudo bash $0"
   exit 1
fi

log "SUCCESS" "权限检查通过，开始安装..."

# 2. 检查并安装依赖
log "INFO" "检查系统依赖..."
missing_deps=()

if ! command -v curl &> /dev/null; then
    missing_deps+=("curl")
fi

if ! command -v jq &> /dev/null; then
    missing_deps+=("jq")
fi

if ! command -v nc &> /dev/null; then
    missing_deps+=("netcat-openbsd")
fi

if [ ${#missing_deps[@]} -gt 0 ]; then
    log "INFO" "正在安装缺失的依赖: ${missing_deps[*]}"
    if command -v apt-get &> /dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq > /dev/null
        apt-get install -y "${missing_deps[@]}" > /dev/null 2>&1
    elif command -v yum &> /dev/null; then
        yum install -y "${missing_deps[@]}" > /dev/null 2>&1
    else
        log "ERROR" "无法自动安装依赖，请手动安装: ${missing_deps[*]}"
        exit 1
    fi
    log "SUCCESS" "依赖安装完成"
else
    log "SUCCESS" "所有依赖已满足"
fi

# 3. 检查Telegram配置
log "INFO" "检查Telegram配置..."
if [ ! -f "$CONFIG_FILE" ]; then
    log "WARN" "配置文件 $CONFIG_FILE 未找到"
    echo
    echo "请提供Telegram Bot配置信息:"
    echo

    read -p "请输入 Telegram Bot Token: " TELEGRAM_TOKEN_INPUT
    read -p "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID_INPUT

    if [ -z "$TELEGRAM_TOKEN_INPUT" ] || [ -z "$TELEGRAM_CHAT_ID_INPUT" ]; then
        log "ERROR" "Token和Chat ID不能为空"
        exit 1
    fi

    # 创建配置文件
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# Telegram 配置信息
TELEGRAM_TOKEN=$TELEGRAM_TOKEN_INPUT
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID_INPUT
EOF

    chmod 600 "$CONFIG_FILE"
    log "SUCCESS" "Telegram配置文件已创建"
else
    log "SUCCESS" "Telegram配置文件已存在"

    # 验证配置文件
    if source "$CONFIG_FILE" 2>/dev/null; then
        if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
            log "ERROR" "配置文件格式错误或缺少必要参数"
            exit 1
        fi
        log "SUCCESS" "Telegram配置验证通过"
    else
        log "ERROR" "无法加载Telegram配置文件"
        exit 1
    fi
fi

# 4. 创建 GFW 检测脚本
log "INFO" "正在创建 GFW 检测脚本 $SCRIPT_PATH..."

# 使用 'EOF' (带单引号) 来防止变量在创建时被展开
cat << 'EOF' > $SCRIPT_PATH
#!/bin/bash

#=======================================================
# GFW 屏蔽检测与 Telegram 通知脚本 (V4.0)
# 兼容 vps.sh Telegram 配置格式
#=======================================================

# 颜色定义 (用于日志输出)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 控制台输出
    case "$level" in
        "INFO")
            echo -e "${BLUE}[INFO]${NC} $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
    esac

    # 文件日志
    echo "[$timestamp] [$level] $message" >> /var/log/gfw_check.log 2>/dev/null || true
}

# --- (1) 配置文件路径 ---
CONFIG_FILE="/etc/profile.d/ssh_notify.sh.env"

# --- (2) 检测配置 ---
FAIL_THRESHOLD=90
TARGETS=(
    "223.5.5.5:53"      # AliDNS
    "119.29.29.29:53"   # TencentDNS (DNSPod)
    "baidu.com:80"      # Baidu Web
    "163.com:80"        # Netease Web
)

# --- (3) 状态文件 ---
STATUS_FILE="/tmp/gfw_outbound_blocked.flag"

# --- (4) 加载和验证配置 ---
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    log "ERROR" "配置文件不存在: $CONFIG_FILE"
    exit 1
fi

if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log "ERROR" "Telegram配置不完整"
    exit 1
fi

# --- (5) Telegram 发送函数 (增强版) ---
send_tg_notification() {
    local MESSAGE="$1"
    local MESSAGE_URLENCODED=$(printf "%s" "$MESSAGE" | jq -s -R -r @uri)
    local API_URL="https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage"

    # 添加解析格式
    local PARSED_MESSAGE=$(printf "%s" "$MESSAGE" | sed 's/\\n/\n/g')

    # 发送消息
    local response=$(curl -s -m 10 -X POST "$API_URL" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${PARSED_MESSAGE}" \
        -d parse_mode="HTML" 2>/dev/null)

    # 检查发送结果
    if echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
        log "SUCCESS" "Telegram通知发送成功"
        return 0
    else
        log "ERROR" "Telegram通知发送失败"
        return 1
    fi
}

# --- (6) 系统信息获取函数 ---
get_system_info() {
    local hostname=$(hostname)
    local ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "未知")
    local location=$(curl -s --connect-timeout 5 "http://ip-api.com/json/$ip" 2>/dev/null | jq -r '.country // "未知"' 2>/dev/null || echo "未知")

    echo "$hostname|$ip|$location"
}

# --- (7) 主检测逻辑 ---
log "INFO" "开始 GFW 出站连通性检测..."

# 检查依赖工具
if ! command -v nc &> /dev/null || ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
    log "ERROR" "缺少必要的系统工具 (nc, jq, curl)"
    exit 1
fi

# 获取系统信息
SYSTEM_INFO=$(get_system_info)
HOSTNAME=$(echo "$SYSTEM_INFO" | cut -d'|' -f1)
MY_IP=$(echo "$SYSTEM_INFO" | cut -d'|' -f2)
LOCATION=$(echo "$SYSTEM_INFO" | cut -d'|' -f3)

if [ -z "$MY_IP" ] || [ "$MY_IP" = "未知" ]; then
    log "ERROR" "无法获取服务器IP地址"
    exit 1
fi

# 执行连通性测试
TOTAL_TARGETS=${#TARGETS[@]}
FAILED_TARGETS=0

if [ "$TOTAL_TARGETS" -eq 0 ]; then
    log "ERROR" "没有配置检测目标"
    exit 0
fi

log "INFO" "检测 $TOTAL_TARGETS 个目标服务器..."

for target in "${TARGETS[@]}"; do
    host=$(echo $target | cut -d: -f1)
    port=$(echo $target | cut -d: -f2)

    nc -z -v -w 3 $host $port &> /dev/null
    if [ $? -ne 0 ]; then
        FAILED_TARGETS=$((FAILED_TARGETS + 1))
        log "WARN" "连接失败: $host:$port"
    else
        log "INFO" "连接成功: $host:$port"
    fi
done

FAILURE_RATE=$((FAILED_TARGETS * 100 / TOTAL_TARGETS))
SUCCESS_COUNT=$((TOTAL_TARGETS - FAILED_TARGETS))

log "INFO" "检测完成: $SUCCESS_COUNT/$TOTAL_TARGETS 成功 (失败率: $FAILURE_RATE%)"

# --- (8) 判断与通知 (仅屏蔽时通知) ---
if [ "$FAILURE_RATE" -ge "$FAIL_THRESHOLD" ]; then
    # 判定为被墙

    # 检查状态文件，如果文件不存在，说明是首次检测到屏蔽
    if [ ! -f "$STATUS_FILE" ]; then
        log "WARN" "首次检测到 GFW 屏蔽，发送通知..."

        # 构建详细的通知消息
        MSG="🚨 <b>GFW 屏蔽警告</b> 🚨

📊 <b>服务器信息:</b>
• 主机名: $HOSTNAME
• IP 地址: <code>$MY_IP</code>
• 地区: $LOCATION

🔍 <b>检测结果:</b>
• 检测方向: VPS → 中国大陆
• 成功连接: $SUCCESS_COUNT/$TOTAL_TARGETS
• 失败率: <b>$FAILURE_RATE%</b>

⚠️ <b>警告:</b>
您的服务器出站访问中国大陆可能已被 GFW 屏蔽！

💡 <b>说明:</b>
GFW 通常执行双向封锁，这意味着中国大陆用户也可能无法访问您的服务器。

📅 <b>检测时间:</b> $(date '+%Y-%m-%d %H:%M:%S')

🔧 <b>建议操作:</b>
1. 检查服务器状态
2. 联系服务提供商
3. 考虑更换IP或服务器"

        if send_tg_notification "$MSG"; then
            log "SUCCESS" "GFW屏蔽通知已发送"
        else
            log "ERROR" "GFW屏蔽通知发送失败"
        fi

        # 创建状态文件，防止重复通知
        touch "$STATUS_FILE"
        log "INFO" "已创建状态标记，24小时内不再重复通知"
    else
        log "INFO" "已处于屏蔽状态，本次不重复通知"
    fi
else
    # 判定为正常

    # 检查状态文件，如果文件存在，说明是从"被墙"恢复了
    if [ -f "$STATUS_FILE" ]; then
        log "INFO" "从 GFW 屏蔽状态恢复"

        # 可选：发送恢复通知（注释掉以符合"仅屏蔽时通知"的要求）
        # RECOVERY_MSG="✅ <b>GFW 屏蔽已解除</b>
        #
        # 📊 <b>服务器信息:</b>
        # • 主机名: $HOSTNAME
        # • IP 地址: <code>$MY_IP</code>
        # • 地区: $LOCATION
        #
        # ✅ <b>状态更新:</b>
        # • 检测方向: VPS → 中国大陆
        # • 成功连接: $SUCCESS_COUNT/$TOTAL_TARGETS
        # • 失败率: $FAILURE_RATE%
        #
        # 🎉 <b>好消息:</b>
        # 您的服务器出站访问中国大陆已恢复正常！
        #
        # 📅 <b>恢复时间:</b> $(date '+%Y-%m-%d %H:%M:%S')"
        #
        # send_tg_notification "$RECOVERY_MSG"

        # 删除状态文件，为下次屏蔽做准备
        rm -f "$STATUS_FILE"
        log "INFO" "已移除状态标记"
    else
        log "INFO" "连通性正常，未被屏蔽"
    fi
fi

log "INFO" "GFW 检测完成"
EOF

# 5. 设置权限
log "INFO" "设置脚本执行权限..."
chmod +x $SCRIPT_PATH

# 6. 创建日志目录
log "INFO" "创建日志目录..."
mkdir -p /var/log
touch /var/log/gfw_check.log
chmod 644 /var/log/gfw_check.log

# 7. 添加 Cron 任务
log "INFO" "配置定时任务..."
CRON_JOB="0 2 * * * $SCRIPT_PATH > /dev/null 2>&1"

if crontab -l 2>/dev/null | grep -Fq "$SCRIPT_PATH"; then
    log "INFO" "定时任务已存在，更新配置..."
    # 移除旧的任务
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
    # 添加新任务
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    log "SUCCESS" "定时任务已更新 (每天凌晨 2:00)"
else
    log "INFO" "添加新的定时任务..."
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    log "SUCCESS" "定时任务已添加 (每天凌晨 2:00)"
fi

# 8. 测试脚本（可选）
echo
read -p "是否立即测试 GFW 检测脚本？(y/N): " TEST_NOW
TEST_NOW=${TEST_NOW:-N}

if [[ "$TEST_NOW" =~ ^[Yy]$ ]]; then
    log "INFO" "运行测试..."
    if $SCRIPT_PATH; then
        log "SUCCESS" "测试运行完成"
    else
        log "ERROR" "测试运行失败，请检查日志: /var/log/gfw_check.log"
    fi
fi

# 9. 显示安装完成信息
echo
echo -e "${WHITE}========================================${NC}"
echo -e "${GREEN}✅ GFW 出站检测脚本安装完成！${NC}"
echo -e "${WHITE}========================================${NC}"
echo

echo -e "${CYAN}📁 安装信息:${NC}"
echo "• 检测脚本: $SCRIPT_PATH"
echo "• 配置文件: $CONFIG_FILE"
echo "• 日志文件: /var/log/gfw_check.log"
echo "• 定时任务: 每天凌晨 2:00"
echo

echo -e "${CYAN}🔧 脚本功能:${NC}"
echo "• 检测 VPS → 中国大陆的出站连通性"
echo "• 仅在检测到 GFW 屏蔽时发送通知"
echo "• 支持详细的 HTML 格式通知"
echo "• 自动获取服务器 IP 和位置信息"
echo "• 防重复通知机制"
echo

echo -e "${CYAN}⚙️ 配置检测:${NC}"
echo "• 检测目标: 4个中国服务器"
echo "• 屏蔽阈值: 90% 失败率"
echo "• 超时设置: 3秒连接超时"
echo

echo -e "${CYAN}📱 通知格式:${NC}"
echo "• 兼容 vps.sh Telegram 配置"
echo "• HTML 格式，支持代码块"
echo "• 包含详细的检测信息和建议"
echo

echo -e "${YELLOW}💡 使用说明:${NC}"
echo "• 脚本会自动检测并发送 Telegram 通知"
echo "• 查看日志: tail -f /var/log/gfw_check.log"
echo "• 手动运行: $SCRIPT_PATH"
echo "• 编辑定时任务: crontab -e"
echo

echo -e "${GREEN}🎉 安装成功！GFW 出站检测已启用。${NC}"
