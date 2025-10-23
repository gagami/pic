#!/bin/bash
# ================================================
# VPS 全自动初始化优化脚本 (优化版 v2.1)
# 作者: yagami + ChatGPT 重构优化
# 系统: Ubuntu 22.04+, Debian 12+
# 优化版本: 增强错误处理、进度显示、性能优化
# ================================================

set -euo pipefail

# 全局环境变量 - 避免交互式提示
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none

# 全局变量
SCRIPT_VERSION="2.1"
LOG_FILE="/var/log/vps_setup.log"
START_TIME=$(date +%s)
ERROR_COUNT=0
SUCCESS_COUNT=0

# 系统检测
detect_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO=$ID
        DISTRO_VERSION=$VERSION_ID
    else
        DISTRO="unknown"
        DISTRO_VERSION="unknown"
    fi

    log "INFO" "检测到系统: $DISTRO $DISTRO_VERSION"

    # 设置系统特定的包名和服务名
    case "$DISTRO" in
        "debian")
            # Debian 12 使用 systemd-syslog
            SYSLOG_SERVICE="systemd-journald"
            LOG_SERVICE="systemd-journald"
            ;;
        "ubuntu")
            # Ubuntu 使用 rsyslog
            SYSLOG_SERVICE="rsyslog"
            LOG_SERVICE="rsyslog"
            ;;
        *)
            # 默认尝试 rsyslog
            SYSLOG_SERVICE="rsyslog"
            LOG_SERVICE="rsyslog"
            ;;
    esac
}

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# 日志函数
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 控制台输出
    case "$level" in
        "INFO")
            echo -e "\n${GREEN}[INFO]${NC} $message"
            ;;
        "WARN")
            echo -e "\n${YELLOW}[WARN]${NC} $message"
            ;;
        "ERROR")
            echo -e "\n${RED}[ERROR]${NC} $message"
            ((ERROR_COUNT++))
            ;;
        "SUCCESS")
            echo -e "\n${GREEN}[SUCCESS]${NC} $message"
            ((SUCCESS_COUNT++))
            ;;
        "PROGRESS")
            echo -e "\n${BLUE}[PROGRESS]${NC} $message"
            ;;
    esac

    # 写入日志文件
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# 进度条显示
show_progress() {
    local current=$1
    local total=$2
    local desc="$3"
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))

    printf "\r${CYAN}%s%s${NC} [%s%s] %d%%" \
        "$desc" \
        $(printf "%*s" $((50 - ${#desc})) "") \
        $(printf "%*s" $filled "|" ) \
        $(printf "%*s" $empty "-") \
        "$percent"
}

# 错误处理函数
handle_error() {
    local exit_code=$1
    local message="$2"

    if [ $exit_code -ne 0 ]; then
        log "ERROR" "$message (错误码: $exit_code)"
        log "ERROR" "脚本执行失败，请检查日志文件: $LOG_FILE"
        echo -e "\n${RED}=== 脚本执行失败 ===${NC}"
        echo -e "${RED}错误信息: $message${NC}"
        echo -e "${RED}错误代码: $exit_code${NC}"
        echo -e "${RED}日志文件: $LOG_FILE${NC}"
        exit $exit_code
    fi
}

# 检查网络连接
check_network() {
    log "INFO" "检查网络连接..."
    local test_urls=("google.com" "github.com" "dl.xanmod.org")

    for url in "${test_urls[@]}"; do
        if ping -c 1 -W 5 "$url" >/dev/null 2>&1; then
            log "SUCCESS" "网络连接正常"
            return 0
        fi
    done

    log "ERROR" "网络连接失败，请检查网络设置"
    return 1
}

# 等待apt锁释放
wait_for_apt_lock() {
    local max_wait=600  # 增加到10分钟
    local wait_time=0
    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/cache/apt/archives/lock"
    )

    log "INFO" "检查apt锁状态..."

    # 检查是否有apt进程在运行
    local apt_processes=$(pgrep -f "apt-get|apt|dpkg" | wc -l)
    if [[ $apt_processes -gt 0 ]]; then
        log "INFO" "发现 $apt_processes 个apt相关进程正在运行，等待完成..."
    fi

    for lock_file in "${lock_files[@]}"; do
        if [[ -f "$lock_file" ]]; then
            local lock_pid=$(fuser "$lock_file" 2>/dev/null | awk '{print $2}' | head -1)
            if [[ -n "$lock_pid" ]]; then
                log "INFO" "检测到apt锁: $lock_file (进程PID: $lock_pid)"
            fi
        fi
    done

    log "INFO" "等待apt锁释放..."
    while [[ $wait_time -lt $max_wait ]]; do
        local all_free=true

        for lock_file in "${lock_files[@]}"; do
            if fuser "$lock_file" >/dev/null 2>&1; then
                all_free=false
                break
            fi
        done

        if $all_free; then
            log "SUCCESS" "apt锁已释放"
            return 0
        fi

        wait_time=$((wait_time + 5))
        echo -n "."
        sleep 5
    done

    echo
    log "ERROR" "apt锁等待超时 (${max_wait}秒)"

    # 显示占用进程信息
    for lock_file in "${lock_files[@]}"; do
        if fuser "$lock_file" >/dev/null 2>&1; then
            local lock_pid=$(fuser "$lock_file" 2>/dev/null | awk '{print $2}' | head -1)
            if [[ -n "$lock_pid" ]]; then
                log "ERROR" "锁文件 $lock_file 被进程 $lock_pid 占用"
                log "INFO" "进程详情: $(ps -p $lock_pid -o comm,cmd 2>/dev/null || echo '进程不存在')"
            fi
        fi
    done

    return 1
}

# 强制清理apt锁（仅作为最后手段）
force_cleanup_apt_locks() {
    log "WARN" "尝试强制清理apt锁..."

    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/cache/apt/archives/lock"
        "/var/lib/apt/lists/lock"
    )

    for lock_file in "${lock_files[@]}"; do
        if [[ -f "$lock_file" ]]; then
            local lock_pid=$(fuser "$lock_file" 2>/dev/null | awk '{print $2}' | head -1)
            if [[ -n "$lock_pid" ]]; then
                # 检查进程是否还在运行
                if ps -p "$lock_pid" >/dev/null 2>&1; then
                    log "INFO" "进程 $lock_pid 正在运行，不强制终止"
                else
                    log "WARN" "清理僵尸锁文件: $lock_file"
                    rm -f "$lock_file" 2>/dev/null || true
                fi
            fi
        fi
    done

    # 重启dpkg
    dpkg --configure -a 2>/dev/null || true

    log "INFO" "apt锁清理完成"
}

# 安装包的改进函数
install_package() {
    local package="$1"
    local description="$2"

    log "INFO" "安装 $description: $package"

    if ! apt-cache show "$package" >/dev/null 2>&1; then
        log "ERROR" "包 $package 不存在"
        return 1
    fi

    if dpkg -l | grep -q "^ii  $package "; then
        log "INFO" "$description 已安装"
        return 0
    fi

    # 等待apt锁释放
    if ! wait_for_apt_lock; then
        log "ERROR" "无法等待apt锁释放，跳过安装 $description"
        return 1
    fi

    # 静默无交互安装
    local max_retries=3
    local retry_count=0

    while [[ $retry_count -lt $max_retries ]]; do
        if apt-get install -yqq "$package"; then
            log "SUCCESS" "$description 安装完成"
            return 0
        else
            retry_count=$((retry_count + 1))
            local exit_code=$?

            if [[ $retry_count -lt $max_retries ]]; then
                log "WARN" "$description 安装失败，尝试 $retry_count/$max_retries，等待5秒后重试..."
                sleep 5

                # 再次等待apt锁
                wait_for_apt_lock
            else
                # 最后尝试：强制清理apt锁
                log "WARN" "所有重试失败，尝试强制清理apt锁..."
                force_cleanup_apt_locks

                # 最后一次尝试安装
                if apt-get install -yqq "$package"; then
                    log "SUCCESS" "$description 安装完成 (强制清理后)"
                    return 0
                else
                    handle_error $exit_code "安装 $description 失败 (已重试 $max_retries 次并强制清理)"
                    return $exit_code
                fi
            fi
        fi
    done
}

# 检查系统资源
check_system_resources() {
    log "INFO" "检查系统资源..."

    # 检查内存
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    local available_mem=$(free -m | awk '/^Mem:/{print $7}')

    if [ "$total_mem" -lt 512 ]; then
        log "WARN" "系统内存较少 (${total_mem}MB)，可能影响性能"
    fi

    # 检查磁盘空间
    local disk_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$disk_usage" -gt 90 ]; then
        log "WARN" "磁盘使用率较高 (${disk_usage}%)，可能影响安装"
    fi

    # 检查系统负载
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    if (( $(echo "$load_avg > 2.0" | bc -l) )); then
        log "WARN" "系统负载较高 ($load_avg)，建议稍后再运行"
    fi

    log "INFO" "系统资源检查完成"
}

# 创建备份
create_backup() {
    local item="$1"
    local backup_name="$2"

    if [ -e "$item" ]; then
        log "INFO" "备份 $backup_name..."
        cp -r "$item" "${item}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
}

# 系统信息显示
show_system_info() {
    echo -e "\n${PURPLE}=== 系统信息 ===${NC}"
    echo -e "${CYAN}操作系统:${NC} $(lsb_release -d 2>/dev/null || echo "Unknown")"
    echo -e "${CYAN}内核版本:${NC} $(uname -r)"
    echo -e "${CYAN}CPU信息:${NC} $(lscpu | grep 'Model name' | cut -d':' -f2- | xargs || echo "Unknown")"
    echo -e "${CYAN}内存信息:${NC} $(free -h | grep '^Mem:' | awk '{print $2}' | xargs)"
    echo -e "${CYAN}磁盘空间:${NC} $(df -h / | awk 'NR==2 {print $2}')"
    echo -e "${CYAN}网络接口:${NC} $(ip route | grep default | awk '{print $5}' | head -1 || echo "Unknown")"
    echo -e "${PURPLE}==================${NC}\n"
}

# ==============================
# 交互部分
# ==============================
show_system_info

echo -e "${WHITE}========== VPS 初始化脚本 v$SCRIPT_VERSION ==========${NC}"
echo -e "${YELLOW}此脚本将优化您的 VPS 系统，请确保您了解所有操作。${NC}\n"

read -p "请输入 VPS 主机名 (hostname): " NEW_HOSTNAME
[[ -z "$NEW_HOSTNAME" ]] && NEW_HOSTNAME="vps-default"

# 设置时区
read -p "请输入时区 (默认: Asia/Shanghai): " TIMEZONE_INPUT
TIMEZONE=${TIMEZONE_INPUT:-Asia/Shanghai}

# 密码设置
read -s -p "请输入 root 登录密码: " ROOT_PASS
echo
read -s -p "请再次输入 root 登录密码确认: " ROOT_PASS2
echo

if [[ "$ROOT_PASS" != "$ROOT_PASS2" ]]; then
    log "ERROR" "两次密码输入不一致！"
    exit 1
fi

# 检查密码强度
if [[ ${#ROOT_PASS} -lt 8 ]]; then
    log "WARN" "密码长度少于8位，建议使用更复杂的密码"
fi

# 选择 XanMod 内核类型
echo -e "\n${WHITE}请选择要安装的 XanMod 内核类型:${NC}"
XANMOD_KERNEL_TYPE="main"  # 默认值
select KERNEL_TYPE in "main" "edge"; do
    [[ "$KERNEL_TYPE" =~ ^(main|edge)$ ]] && XANMOD_KERNEL_TYPE=$KERNEL_TYPE && break
    echo "无效选择，请输入 1 或 2."
done

# Swap 配置
echo
read -p "是否要创建或重置 swap 交换空间？(Y/n): " CREATE_SWAP
CREATE_SWAP=${CREATE_SWAP:-Y}

if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then
    read -p "请输入要创建的 swap 大小（MB，默认 1024）: " SWAP_SIZE
    SWAP_SIZE=${SWAP_SIZE:-1024}

    if [[ $SWAP_SIZE -lt 512 ]]; then
        log "WARN" "Swap 大小较小，建议至少512MB"
    elif [[ $SWAP_SIZE -gt 8192 ]]; then
        log "WARN" "Swap 大小较大，可能占用过多磁盘空间"
    fi
else
    SWAP_SIZE=0
fi

# Telegram 配置
echo -e "\n${WHITE}========== 配置 Telegram Bot 信息 ==========${NC}"
read -p "是否配置 Telegram Bot 信息？(Y/n): " CONFIGURE_TELEGRAM
CONFIGURE_TELEGRAM=${CONFIGURE_TELEGRAM:-Y}

# 初始化Telegram变量
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

if [[ "$CONFIGURE_TELEGRAM" =~ ^[Yy]$ ]]; then
    read -p "请输入 Telegram Bot 的 API Token: " TELEGRAM_TOKEN
    read -p "请输入 Telegram Chat ID： " TELEGRAM_CHAT_ID

    if [[ -z "$TELEGRAM_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        log "ERROR" "Token 和 Chat ID 不能为空"
        exit 1
    fi
fi

# 系统检测
detect_system

# 系统检查
check_system_resources
check_network || exit 1

# ==============================
# 系统更新和基础安装
# ==============================
log "INFO" "开始系统初始化..."

# 更新系统时间
timedatectl set-ntp true 2>/dev/null || true

# 配置apt为非交互模式
log "INFO" "配置APT为非交互模式..."
cat > /etc/apt/apt.conf.d/99noninteractive << EOF
APT::Get::Assume-Yes "true";
APT::Get::AllowUnauthenticated "false";
APT::Get::AllowReleaseInfoChange "true";
Dpkg::Options {
   "--force-confdef";
   "--force-confold";
}
EOF

# 更新软件包列表
log "INFO" "更新软件包列表..."
wait_for_apt_lock
apt-get update -qq || handle_error $? "软件包列表更新失败"

# 升级已安装的软件包
log "INFO" "升级已安装的软件包..."
wait_for_apt_lock
apt-get upgrade -yqq || handle_error $? "系统升级失败"

# 安装基础软件包
log "PROGRESS" "安装基础软件包..."
wait_for_apt_lock

# 分组安装软件包以优化网络请求
ESSENTIAL_PACKAGES=(
    "wget"
    "curl"
    "git"
    "screen"
    "tmux"
    "tar"
    "unzip"
    "aria2"
)

SYSTEM_PACKAGES=(
    "ca-certificates"
    "gnupg"
    "lsb-release"
)

BUILD_PACKAGES=(
    "build-essential"
    "make"
    "gcc"
    "automake"
    "autoconf"
    "libtool"
    "libssl-dev"
    "libpam0g-dev"
)

NETWORK_PACKAGES=(
    "net-tools"
    "iptables-persistent"
    "netfilter-persistent"
)

SECURITY_PACKAGES=(
    "chrony"
    "fail2ban"
)

# 根据系统类型调整软件包
case "$DISTRO" in
    "debian")
        # Debian 12 默认使用 systemd-journald，rsyslog是可选的
        SECURITY_PACKAGES+=("rsyslog")
        ;;
    "ubuntu")
        # Ubuntu 需要rsyslog
        SECURITY_PACKAGES+=("rsyslog")
        ;;
    *)
        # 其他系统默认包含rsyslog
        SECURITY_PACKAGES+=("rsyslog")
        ;;
esac

UTILITY_PACKAGES=(
    "ethtool"
    "htop"
    "iotop"
    "jq"
)

# 批量安装软件包
for package in "${ESSENTIAL_PACKAGES[@]}"; do
    install_package "$package" "基础软件"
done

for package in "${SYSTEM_PACKAGES[@]}"; do
    install_package "$package" "系统软件"
done

for package in "${BUILD_PACKAGES[@]}"; do
    install_package "$package" "构建工具"
done

for package in "${NETWORK_PACKAGES[@]}"; do
    install_package "$package" "网络工具"
done

for package in "${SECURITY_PACKAGES[@]}"; do
    install_package "$package" "安全软件"
done

for package in "${UTILITY_PACKAGES[@]}"; do
    install_package "$package" "实用工具"
done

# ==============================
# 防火墙设置
# ==============================
log "INFO" "配置防火墙规则..."

# 备份原有防火墙配置
create_backup "/etc/iptables/rules.v4" "iptables规则"
create_backup "/etc/iptables/rules.v6" "ip6tables规则"

# 禁用并移除 ufw
ufw disable 2>/dev/null || true
apt-get remove ufw -yqq 2>/dev/null || true
apt-get purge ufw -yqq 2>/dev/null || true

# 安装 iptables-persistent
install_package "iptables-persistent" "iptables持久化工具"

# 配置 iptables 规则 - 允许所有流量
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F
iptables -X

# 设置基本的安全规则
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 52222 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# 保存规则
iptables-save > /etc/iptables/rules.v4 2>/dev/null || handle_error $? "保存iptables规则失败"
ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || handle_error $? "保存ip6tables规则失败"

# 启用并启动服务
systemctl enable netfilter-persistent 2>/dev/null || true
systemctl start netfilter-persistent 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true
netfilter-persistent reload 2>/dev/null || true

# 确保相关服务运行
systemctl start iptables 2>/dev/null || true
systemctl start netfilter 2>/dev/null || true
systemctl start netfilter-persistent 2>/dev/null || true

log "SUCCESS" "防火墙配置完成"

# ==============================
# 系统设置
# ==============================
log "INFO" "配置系统基本设置..."

# 设置主机名
hostnamectl set-hostname "$NEW_HOSTNAME"
if ! grep -q "$NEW_HOSTNAME" /etc/hosts; then
    echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
fi

# 设置root密码
echo "root:$ROOT_PASS" | chpasswd
log "SUCCESS" "主机名设置为: $NEW_HOSTNAME"

# 设置时区
timedatectl set-timezone "$TIMEZONE"
install_package "chrony" "时间同步服务"
systemctl enable chrony --now
chronyc -a makestep
log "SUCCESS" "时区设置完成: $TIMEZONE"

# 设置系统限制
echo "* hard nofile 1048576" >> /etc/security/limits.conf
echo "* soft nofile 1048576" >> /etc/security/limits.conf
echo "root hard nofile 1048576" >> /etc/security/limits.conf
echo "root soft nofile 1048576" >> /etc/security/limits.conf

# 检查BBR支持
if ! modinfo tcp_bbr >/dev/null 2>&1; then
    log "WARN" "当前内核不支持BBR拥塞控制，将使用cubic"
    CONGESTION_CONTROL="cubic"
    QDISC="pfifo"
else
    log "INFO" "检测到BBR支持，将启用BBR拥塞控制"
    CONGESTION_CONTROL="bbr"
    QDISC="fq"
fi

# 内核参数优化
cat > /etc/sysctl.d/99-vps-optimization.conf << EOF
# 网络优化
net.core.rmem_default = 262144
net.core.rmem_max = 536870912
net.core.wmem_default = 262144
net.core.wmem_max = 536870912
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CONGESTION_CONTROL

# 文件系统优化
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288

# 虚拟内存优化
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# 网络安全
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# 系统性能
kernel.pid_max = 32768
kernel.threads-max = 65535
EOF

# 应用内核参数
if ! sysctl --system 2>&1 | tee /tmp/sysctl_first_error.log; then
    log "ERROR" "应用内核参数失败，尝试逐个验证参数..."

    # 显示错误信息
    if [[ -f /tmp/sysctl_first_error.log ]]; then
        echo "=== 系统参数错误信息 ==="
        cat /tmp/sysctl_first_error.log
        echo "========================="
    fi

    # 验证重要参数
    log "INFO" "验证关键网络参数..."
    sysctl -w net.ipv4.tcp_congestion_control=$CONGESTION_CONTROL 2>/dev/null || log "WARN" "$CONGESTION_CONTROL 拥塞控制不支持"
    sysctl -w net.core.default_qdisc=$QDISC 2>/dev/null || log "WARN" "$QDISC 队列不支持"

    # 应用其他重要参数
    local critical_params=(
        "vm.swappiness=10"
        "fs.file-max=1048576"
        "net.ipv4.ip_forward=1"
        "kernel.pid_max=32768"
    )

    for param_set in "${critical_params[@]}"; do
        if sysctl -w "$param_set" 2>/dev/null; then
            log "INFO" "✓ $param_set"
        else
            log "WARN" "✗ $param_set (参数不支持)"
        fi
    done

    # 尝试应用完整配置文件
    if [[ -f /etc/sysctl.d/99-vps-optimization.conf ]]; then
        log "INFO" "尝试应用系统优化配置..."
        sysctl -p /etc/sysctl.d/99-vps-optimization.conf 2>/dev/null && log "SUCCESS" "系统优化配置应用成功" || log "WARN" "部分系统参数应用失败"
    fi

    # 清理临时文件
    rm -f /tmp/sysctl_first_error.log
else
    log "SUCCESS" "所有内核参数应用成功"
fi
log "SUCCESS" "系统配置完成"

# ==============================
# Swap 创建
# ==============================
if [[ "$SWAP_SIZE" -gt 0 ]]; then
    log "PROGRESS" "创建 ${SWAP_SIZE}MB Swap 分区..."
    SWAP_FILE="/swapfile"

    # 检查是否已有swap
    if swapon --show | grep -q "$SWAP_FILE"; then
        log "INFO" "检测到已有 swap，正在删除旧 swap..."
        swapoff "$SWAP_FILE" || true
        rm -f "$SWAP_FILE" || true
    fi

    # 创建swap文件
    log "INFO" "创建 swap 文件: ${SWAP_SIZE}MB"
    fallocate -l "${SWAP_SIZE}M" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE" status=none

    # 设置权限
    chmod 600 "$SWAP_FILE"

    # 格式化并启用swap
    mkswap "$SWAP_FILE" || handle_error $? "创建swap失败"
    swapon "$SWAP_FILE" || handle_error $? "启用swap失败"

    # 添加到fstab
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi

    # 优化swap使用
    sysctl vm.swappiness=10 >/dev/null

    log "SUCCESS" "Swap 创建完成: ${SWAP_SIZE}MB"
else
    log "INFO" "跳过创建 swap"
fi

# ==============================
# SSH 优化
# ==============================
log "INFO" "优化 SSH 配置..."

# 备份SSH配置
create_backup "/etc/ssh/sshd_config" "SSH配置"

# SSH配置优化
SSH_PORT=52222
sed -i \
    -e "s/^#\?Port .*/Port ${SSH_PORT}/" \
    -e "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" \
    -e "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" \
    -e "s/^#\?ClientAliveInterval .*/ClientAliveInterval 60/" \
    -e "s/^#\?ClientAliveCountMax .*/ClientAliveCountMax 3/" \
    -e "s/^#\?UseDNS .*/UseDNS no/" \
    -e "s/^#\?GSSAPIAuthentication .*/GSSAPIAuthentication no/" \
    -e "s/^#\?MaxAuthTries .*/MaxAuthTries 3/" \
    -e "s/^#\?MaxSessions .*/MaxSessions 10/" \
    /etc/ssh/sshd_config

# 添加SSH安全配置
cat >> /etc/ssh/sshd_config << EOF

# SSH 安全配置
Banner /etc/ssh/banner
LogLevel VERBOSE
AllowTcpForwarding no
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
EOF

# 创建SSH banner
cat > /etc/ssh/banner << EOF
*******************************************************************************
                            AUTHORIZED ACCESS ONLY
*******************************************************************************
This system is for authorized users only. Individual activity
may be monitored. Unauthorized access is prohibited and will be
prosecuted to the fullest extent of the law.
*******************************************************************************
EOF

# 重启SSH服务
systemctl restart sshd || handle_error $? "SSH服务重启失败"
log "SUCCESS" "SSH 配置完成 (端口: $SSH_PORT)"

# ==============================
# Fail2Ban 配置
# ==============================
log "INFO" "配置 Fail2Ban..."

# 确保日志服务运行
if systemctl list-unit-files | grep -q "^${SYSLOG_SERVICE}.service"; then
    systemctl enable ${SYSLOG_SERVICE} 2>/dev/null || true
    systemctl restart ${SYSLOG_SERVICE} 2>/dev/null || true
    log "INFO" "日志服务 ${SYSLOG_SERVICE} 已启动"
else
    log "WARN" "日志服务 ${SYSLOG_SERVICE} 不存在，跳过"
fi

# 检测日志路径
case "$DISTRO" in
    "debian")
        AUTH_LOG_PATH="/var/log/auth.log"
        ;;
    "ubuntu")
        AUTH_LOG_PATH="/var/log/auth.log"
        ;;
    *)
        AUTH_LOG_PATH="/var/log/auth.log"
        ;;
esac

# 确保日志文件存在
if [[ ! -f "$AUTH_LOG_PATH" ]]; then
    AUTH_LOG_PATH="/var/log/secure"
fi
if [[ ! -f "$AUTH_LOG_PATH" ]]; then
    AUTH_LOG_PATH="/var/log/messages"
fi

log "INFO" "使用日志路径: $AUTH_LOG_PATH"

# 备份Fail2Ban配置
create_backup "/etc/fail2ban/jail.conf" "Fail2Ban配置"
create_backup "/etc/fail2ban/jail.local" "Fail2Ban本地配置"

# 配置Fail2Ban
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime = 24h
findtime = 10m
maxretry = 3
backend = systemd
banaction = iptables-multiport
chain = INPUT

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = $AUTH_LOG_PATH
maxretry = 3
bantime = 24h

[nginx-http]
enabled = false
port = http,https
filter = nginx-http
logpath = /var/log/nginx/error.log
maxretry = 3
bantime = 24h

[nginx-noscript]
enabled = false
port = http,https
filter = nginx-noscript
logpath = /var/log/nginx/access.log
maxretry = 6
bantime = 1h
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "SUCCESS" "Fail2Ban 配置完成"

# ==============================
# XanMod 内核安装
# ==============================
log "PROGRESS" "检测系统并安装 XanMod 内核..."

# 获取CPU信息
CPU_MODEL=$(lscpu | grep "Model name" | cut -d':' -f2- | xargs || echo "Unknown")
CPU_CORES=$(nproc)
CPU_FLAGS=$(lscpu | grep "Flags" | awk -F: '{print $2}')

# ABI检测
if echo "$CPU_FLAGS" | grep -q avx512f; then
    ABI="x86-64-v4"
elif echo "$CPU_FLAGS" | grep -q avx512; then
    ABI="x86-64-v4"
elif echo "$CPU_FLAGS" | grep -q avx2; then
    ABI="x86-64-v3"
elif echo "$CPU_FLAGS" | grep -q sse4_2; then
    ABI="x86-64-v2"
else
    ABI="x86-64-v1"
fi

log "INFO" "检测到系统信息:"
log "INFO" "  CPU型号: $CPU_MODEL"
log "INFO" "  核心数: $CPU_CORES"
log "INFO" "  ABI: $ABI"

# 根据类型选择包
case "$ABI" in
    x86-64-v4)
        if [[ "$XANMOD_KERNEL_TYPE" == "edge" ]]; then
            PKG="linux-xanmod-edge-x64v4"
        else
            PKG="linux-xanmod-main-x64v4"
        fi
        ;;
    x86-64-v2)
        if [[ "$XANMOD_KERNEL_TYPE" == "edge" ]]; then
            PKG="linux-xanmod-edge-x64v2"
        else
            PKG="linux-xanmod-main-x64v2"
        fi
        ;;
    x86-64-v3)
        if [[ "$XANMOD_KERNEL_TYPE" == "edge" ]]; then
            PKG="linux-xanmod-edge-x64v3"
        else
            PKG="linux-xanmod-main-x64v3"
        fi
        ;;
    x86-64-v1)
        if [[ "$XANMOD_KERNEL_TYPE" == "edge" ]]; then
            PKG="linux-xanmod-edge-x64v1"
        else
            PKG="linux-xanmod-main-x64v1"
        fi
        ;;
    *)
        log "ERROR" "不支持的 ABI: $ABI"
        exit 1
        ;;
esac

log "INFO" "选择内核包: $PKG"

# 导入GPG密钥 - 多重备用方案
log "INFO" "导入 XanMod GPG 密钥..."

# 确保keyrings目录存在
mkdir -p /usr/share/keyrings

# 尝试多种方法导入GPG密钥
import_gpg_success=false

# 方法1: 直接从xanmod.org下载
if ! $import_gpg_success; then
    log "INFO" "尝试从官方服务器下载GPG密钥..."
    if wget -qO - https://dl.xanmod.org/archive.key 2>/dev/null | gpg --dearmor 2>/dev/null | tee /usr/share/keyrings/xanmod-archive-keyring.gpg >/dev/null; then
        log "SUCCESS" "GPG密钥导入成功（方法1）"
        import_gpg_success=true
    else
        log "WARN" "官方服务器下载失败，尝试备用方法..."
    fi
fi

# 方法2: 使用keyserver
if ! $import_gpg_success; then
    log "INFO" "尝试从keyserver导入GPG密钥..."
    # XanMod的GPG密钥指纹
    if gpg --keyserver keyserver.ubuntu.com --recv-keys 9544152F6246B46F695836525BB4B590718A3631 2>/dev/null; then
        gpg --armor --export 9544152F6246B46F695836525BB4B590718A3631 | gpg --dearmor > /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null
        if [[ -f /usr/share/keyrings/xanmod-archive-keyring.gpg ]]; then
            log "SUCCESS" "GPG密钥导入成功（方法2）"
            import_gpg_success=true
        else
            log "WARN" "Keyserver方法失败，尝试其他备用方法..."
        fi
    else
        log "WARN" "Keyserver访问失败，尝试其他备用方法..."
    fi
fi

# 方法3: 使用备用keyserver
if ! $import_gpg_success; then
    log "INFO" "尝试从备用keyserver导入GPG密钥..."
    for keyserver in "pgp.mit.edu" "keyserver.pgp.com" "hkps.pool.sks-keyservers.net"; do
        if gpg --keyserver "$keyserver" --recv-keys 9544152F6246B46F695836525BB4B590718A3631 2>/dev/null; then
            gpg --armor --export 9544152F6246B46F695836525BB4B590718A3631 | gpg --dearmor > /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null
            if [[ -f /usr/share/keyrings/xanmod-archive-keyring.gpg ]]; then
                log "SUCCESS" "GPG密钥导入成功（keyserver: $keyserver）"
                import_gpg_success=true
                break
            fi
        fi
        log "INFO" "keyserver $keyserver 访问失败，尝试下一个..."
    done
fi

# 方法4: 使用curl替代wget（如果可用）
if ! $import_gpg_success && command -v curl >/dev/null 2>&1; then
    log "INFO" "尝试使用curl下载GPG密钥..."
    if curl -fsSL https://dl.xanmod.org/archive.key 2>/dev/null | gpg --dearmor 2>/dev/null | tee /usr/share/keyrings/xanmod-archive-keyring.gpg >/dev/null; then
        log "SUCCESS" "GPG密钥导入成功（curl方法）"
        import_gpg_success=true
    else
        log "WARN" "curl方法也失败了"
    fi
fi

# 方法5: 创建临时keyring（无签名验证）
if ! $import_gpg_success; then
    log "WARN" "所有GPG密钥导入方法都失败，创建无签名验证的配置..."
    # 创建一个空的keyring文件以避免apt错误
    touch /usr/share/keyrings/xanmod-archive-keyring.gpg
    import_gpg_success=true
    log "INFO" "将继续安装，但跳过GPG签名验证"
fi

# 验证keyring文件
if [[ -f /usr/share/keyrings/xanmod-archive-keyring.gpg ]]; then
    local keyring_size=$(stat -c%s /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null || echo "0")
    if [[ $keyring_size -gt 0 ]]; then
        log "INFO" "GPG keyring 文件已创建 (大小: $keyring_size 字节)"
    else
        log "WARN" "GPG keyring 文件为空，将跳过签名验证"
    fi
else
    log "ERROR" "无法创建GPG keyring文件"
    handle_error 1 "GPG keyring创建失败"
fi

# 添加软件源 - 根据GPG状态决定是否启用签名验证
if [[ -f /usr/share/keyrings/xanmod-archive-keyring.gpg ]] && [[ $(stat -c%s /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null || echo "0") -gt 0 ]]; then
    # 有有效keyring，启用签名验证
    echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" | tee /etc/apt/sources.list.d/xanmod-kernel.list >/dev/null
    log "INFO" "已添加XanMod软件源（启用GPG签名验证）"
else
    # 无有效keyring，使用trusted选项
    echo "deb [trusted=yes] http://deb.xanmod.org releases main" | tee /etc/apt/sources.list.d/xanmod-kernel.list >/dev/null
    log "WARN" "已添加XanMod软件源（跳过GPG签名验证）"
fi

# 更新包列表 - 带重试机制
log "INFO" "更新软件包列表..."
max_update_retries=3
update_retry_count=0

while [[ $update_retry_count -lt $max_update_retries ]]; do
    if apt-get update -qq; then
        log "SUCCESS" "软件包列表更新成功"
        break
    else
        ((update_retry_count++))
        if [[ $update_retry_count -lt $max_update_retries ]]; then
            log "WARN" "软件包列表更新失败，重试 $update_retry_count/$max_update_retries，等待5秒..."
            sleep 5
            # 清理可能的锁
            wait_for_apt_lock
        else
            log "ERROR" "软件包列表更新失败，请检查网络连接"
            handle_error $? "更新软件包列表失败"
        fi
    fi
done

# 检查包是否存在
if ! apt-cache show "$PKG" >/dev/null 2>&1; then
    log "ERROR" "找不到 XanMod 包: $PKG"
    exit 1
fi

# 安装内核
log "INFO" "安装 XanMod 内核: $PKG"

# 等待apt锁释放
if ! wait_for_apt_lock; then
    log "ERROR" "无法等待apt锁释放，无法安装内核"
    exit 1
fi

# 尝试安装内核，带重试机制
max_retries=2
retry_count=0

while [[ $retry_count -lt $max_retries ]]; do
    if apt-get install -yqq "$PKG"; then
        log "SUCCESS" "XanMod 内核安装完成"
        break
    else
        retry_count=$((retry_count + 1))
        exit_code=$?

        if [[ $retry_count -lt $max_retries ]]; then
            log "WARN" "内核安装失败，尝试 $retry_count/$max_retries，等待10秒后重试..."
            sleep 10
            wait_for_apt_lock
        else
            handle_error $exit_code "安装 XanMod 内核失败"
            exit $exit_code
        fi
    fi
done

# 更新GRUB
if command -v update-grub >/dev/null 2>&1; then
    update-grub || handle_error $? "更新GRUB失败"
else
    grub-mkconfig -o /boot/grub/grub.cfg || handle_error $? "生成GRUB配置失败"
fi

log "SUCCESS" "XanMod 内核 ($PKG) 安装完成"

# ==============================
# 网络优化
# ==============================
log "INFO" "应用网络优化配置..."

# 确保拥塞控制变量已定义
if [[ -z "$CONGESTION_CONTROL" ]]; then
    if ! modinfo tcp_bbr >/dev/null 2>&1; then
        CONGESTION_CONTROL="cubic"
        QDISC="pfifo"
        log "WARN" "使用默认拥塞控制: cubic"
    else
        CONGESTION_CONTROL="bbr"
        QDISC="fq"
        log "INFO" "使用BBR拥塞控制"
    fi
fi

# 备份原有sysctl配置
create_backup "/etc/sysctl.conf" "sysctl配置"

# 优化网络配置 - 根据系统类型选择参数
if [[ "$DISTRO" == "debian" ]]; then
    log "INFO" "应用Debian 12优化的网络配置..."
    cat > /etc/sysctl.conf << EOF
# =============================
# Debian 12 网络内核优化配置
# =============================

# BBR拥塞控制算法
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CONGESTION_CONTROL

# TCP窗口设置 (Debian 12兼容值)
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 4096 65536 16777216

# TCP连接设置 (保守值)
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 7200
net.ipv4.tcp_keepalive_probes = 9
net.ipv4.tcp_keepalive_intvl = 75
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 5000

# TCP Fast Open (仅在支持时启用)
net.ipv4.tcp_fastopen = 1

# IP和路由设置
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1

# ARP设置 (Debian 12兼容值)
net.ipv4.neigh.default.gc_thresh1 = 128
net.ipv4.neigh.default.gc_thresh2 = 512
net.ipv4.neigh.default.gc_thresh3 = 4096
net.ipv4.neigh.default.gc_stale_time = 60

# 防御设置
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# 系统性能调优
kernel.pid_max = 32768
kernel.threads-max = 65535
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# 文件系统优化
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# 内存管理
vm.overcommit_memory = 1
vm.panic_on_oom = 0
vm.min_free_kbytes = 65536

# 其他优化 (Debian 12兼容)
kernel.sysrq = 1
kernel.nmi_watchdog = 0
EOF
else
    # Ubuntu 22.04 配置
    log "INFO" "应用Ubuntu 22.04优化的网络配置..."
    cat > /etc/sysctl.conf << EOF
# =============================
# Ubuntu 22.04 网络内核优化配置
# =============================

# BBR拥塞控制算法
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CONGESTION_CONTROL

# TCP窗口设置
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 4096 65536 16777216

# TCP连接设置
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 7
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_syn_backlog = 65536
net.core.netdev_max_backlog = 5000

# TCP Fast Open
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fastopen_blackhole_timeout = 30

# TCP拥塞控制
net.ipv4.tcp_slow_start_after_idle = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# IP和路由设置
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1

# ARP设置
net.ipv4.neigh.default.gc_thresh1 = 128
net.ipv4.neigh.default.gc_thresh2 = 512
net.ipv4.neigh.default.gc_thresh3 = 4096
net.ipv4.neigh.default.gc_stale_time = 60
net.ipv4.neigh.default.proxy_qlen = 96
net.ipv4.neigh.proxy_delay = 5

# 防御设置
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# 系统性能调优
kernel.pid_max = 32768
kernel.threads-max = 999999
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# 文件系统优化
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# 内存管理
vm.overcommit_memory = 1
vm.panic_on_oom = 0
vm.min_free_kbytes = 65536

# 其他优化
kernel.sysrq = 1
kernel.nmi_watchdog = 0
kernel.printk_time = 10
kernel.printk_devkmsg = 1
EOF
fi

# 应用sysctl参数 - 增强版本支持检查
if ! sysctl --system 2>&1 | tee /tmp/sysctl_error.log; then
    log "ERROR" "应用网络优化参数失败，尝试逐个验证..."

    # 显示错误信息
    if [[ -f /tmp/sysctl_error.log ]]; then
        echo "=== 错误信息 ==="
        cat /tmp/sysctl_error.log
        echo "========================="
    fi

    # 根据系统类型应用不同的验证策略
    if [[ "$DISTRO" == "debian" ]]; then
        log "INFO" "检测到Debian系统，应用兼容性检查..."
        apply_debian_sysctl_params
    else
        log "INFO" "检测到Ubuntu系统，应用标准验证..."
        apply_ubuntu_sysctl_params
    fi

    # 清理临时文件
    rm -f /tmp/sysctl_error.log
else
    log "SUCCESS" "所有网络优化参数应用成功"
fi
log "SUCCESS" "网络优化配置完成"

# Debian 12特定的sysctl参数应用函数
apply_debian_sysctl_params() {
    local params=(
        "vm.swappiness=10"
        "fs.file-max=1048576"
        "net.ipv4.ip_forward=1"
        "kernel.pid_max=32768"
        "kernel.threads-max=65535"
        "vm.vfs_cache_pressure=50"
        "vm.dirty_ratio=15"
        "vm.dirty_background_ratio=5"
        "fs.inotify.max_user_watches=524288"
    )

    log "INFO" "应用Debian 12兼容参数..."
    for param_set in "${params[@]}"; do
        if sysctl -w "$param_set" 2>/dev/null; then
            log "INFO" "✓ $param_set"
        else
            log "WARN" "✗ $param_set (参数不支持)"
        fi
    done

    # 尝试应用网络参数（Debian 12兼容版本）
    local network_params=(
        "net.ipv4.tcp_window_scaling=1"
        "net.ipv4.tcp_fin_timeout=30"
        "net.ipv4.tcp_keepalive_time=7200"
        "net.ipv4.tcp_max_syn_backlog=4096"
        "net.core.netdev_max_backlog=5000"
    )

    log "INFO" "应用Debian 12网络参数..."
    for param_set in "${network_params[@]}"; do
        if sysctl -w "$param_set" 2>/dev/null; then
            log "INFO" "✓ $param_set"
        else
            log "WARN" "✗ $param_set (网络参数不支持)"
        fi
    done

    # 尝试应用BBR（如果支持）
    if sysctl -w "net.ipv4.tcp_congestion_control=$CONGESTION_CONTROL" 2>/dev/null; then
        log "SUCCESS" "✓ BBR拥塞控制: $CONGESTION_CONTROL"
        sysctl -w "net.core.default_qdisc=$QDISC" 2>/dev/null || log "WARN" "队列调度器 $QDISC 不支持"
    else
        log "WARN" "BBR拥塞控制不支持，保持默认设置"
    fi
}

# Ubuntu 22.04特定的sysctl参数应用函数
apply_ubuntu_sysctl_params() {
    # 尝试应用配置文件，逐个验证参数
    for config_file in /etc/sysctl.d/*.conf; do
        if [[ -f "$config_file" ]]; then
            log "INFO" "尝试应用配置文件: $config_file"
            # 逐行读取并应用参数
            while IFS= read -r line; do
                # 跳过注释和空行
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                [[ -z "${line// }" ]] && continue

                # 提取参数名和值
                if [[ "$line" == *"="* ]]; then
                    param="${line%%=*}"
                    param="${param// /}"
                    value="${line#*=}"
                    value="${value// /}"

                    if sysctl -w "$param=$value" 2>/dev/null; then
                        log "INFO" "✓ $param = $value"
                    else
                        log "WARN" "✗ $param = $value (参数不支持或无效)"
                    fi
                fi
            done < "$config_file"
        fi
    done
}

# ==============================
# 清理和优化
# ==============================
log "INFO" "系统清理和优化..."

# 清理不需要的包
apt-get autoremove -yqq
apt-get autoclean -yqq

# 清理日志文件
find /var/log -type f -name "*.log" -mtime +30 -delete 2>/dev/null || true
find /var/log -type f -name "*.log.*" -mtime +30 -delete 2>/dev/null || true

# 清理临时文件
find /tmp -type f -mtime +7 -delete 2>/dev/null || true
find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true

# 设置日志轮转
cat > /etc/logrotate.d/custom << EOF
/var/log/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644
    sharedscripts
    postrotate
        systemctl reload ${LOG_SERVICE} >/dev/null 2>&1 || true
    endscript
}
EOF

# 配置systemd日志
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-vps.conf << EOF
[Journal]
Storage=volatile
RuntimeMaxUse=100M
SystemMaxUse=100M
EOF

# 重启日志服务
systemctl restart systemd-journald 2>/dev/null || true
if systemctl list-unit-files | grep -q "^${LOG_SERVICE}.service"; then
    systemctl restart ${LOG_SERVICE} 2>/dev/null || true
fi

log "SUCCESS" "系统清理完成"

# ==============================
# Telegram 配置
# ==============================
if [[ "$CONFIGURE_TELEGRAM" =~ ^[Yy]$ ]]; then
    log "INFO" "配置 Telegram 通知..."

    # 设置环境变量文件
    ENV_FILE="/etc/profile.d/ssh_notify.sh.env"
    create_backup "$ENV_FILE" "Telegram环境配置"

    cat << EOF > $ENV_FILE
# Telegram 配置信息
TELEGRAM_TOKEN=$TELEGRAM_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF

    chmod 600 "$ENV_FILE"

    # 下载并设置ssh_notify.sh
    if wget -qO /etc/profile.d/ssh_notify.sh https://raw.githubusercontent.com/gagami/pic/refs/heads/main/ssh_notify.sh; then
        chmod +x /etc/profile.d/ssh_notify.sh
        log "SUCCESS" "Telegram 配置完成"
        log "INFO" "请执行 'source /etc/profile.d/ssh_notify.sh.env' 重新加载配置"
    else
        log "WARN" "下载ssh_notify.sh失败，请手动配置"
    fi
else
    log "INFO" "跳过 Telegram 配置"
fi

# ==============================
# MOTD 和欢迎信息
# ==============================
log "INFO" "设置登录欢迎信息..."

# 清空motd
> /etc/motd
> /etc/update-motd.d/00-header
> /etc/update-motd.d/10-help
> /etc/update-motd.d/99-footer

# 创建美观的motd
cat > /etc/update-motd.d/10-uname << 'EOF'
#!/bin/sh
uname -snr
EOF

cat > /etc/update-motd.d/20-sysinfo << 'EOF'
#!/bin/sh
echo "CPU 信息: $(lscpu | grep 'Model name' | cut -d':' -f2- | xargs)"
echo "内存信息: $(free -h | grep '^Mem:' | awk '{print $3" $7"')"
echo "磁盘使用: $(df -h / | awk 'NR==2 {print $3" $5}')"
echo "系统负载: $(uptime | awk -F'load average:' '{print $2, $3, $4}')"
EOF

cat > /etc/update-motd.d/30-network << 'EOF'
#!/bin/sh
echo "网络接口:"
ip -4 addr show | grep -E "inet\b" | awk '{print "  " $2 ": " $4}' || true
echo ""
echo "监听端口:"
ss -tuln | grep LISTEN | awk '{print "  " $1 " $4 ":" $5}' | sort -k 2 || true
EOF

cat > /etc/update-motd.d/40-security << 'EOF'
#!/bin/sh
echo "最后登录:"
last -n 1 -i | awk '{print "  " $1 " $3 " $4 " $6" $7}' || true
echo ""
echo "失败登录尝试:"
grep "authentication failure" /var/log/auth.log 2>/dev/null | tail -n 5 | awk '{print "  " $1 " $2 $3 $4}' | sed 's/authentication failure//' || true
EOF

# 设置权限
chmod +x /etc/update-motd.d/*

# 生成新的motd
update-motd 2>/dev/null || true

# 下载并设置动态motd
if wget -qO /etc/profile.d/cyberops_motd.sh https://raw.githubusercontent.com/gagami/pic/refs/heads/main/cyberops_motd.sh; then
    chmod +x /etc/profile.d/cyberops_motd.sh
    log "SUCCESS" "动态MOTD设置完成"
else
    log "WARN" "动态MOTD设置失败，请手动配置"
fi

log "SUCCESS" "欢迎信息设置完成"

# ==============================
# 最终检查和总结
# ==============================
END_TIME=$(date +%s)
RUNTIME=$((END_TIME - START_TIME))

# 显示完成信息
echo -e "\n${GREEN}========================================"
echo -e "🎉 VPS 初始化脚本执行完成！"
echo -e "========================================${NC}\n"

echo -e "${WHITE}=== 执行总结 ===${NC}"
echo -e "${CYAN}执行时间:${NC} $((RUNTIME / 60)) 分 $((RUNTIME % 60)) 秒"
echo -e "${CYAN}成功操作:${NC} $SUCCESS_COUNT"
echo -e "${RED}错误操作:${NC} $ERROR_COUNT"
echo -e "${CYAN}日志文件:${NC} $LOG_FILE"
echo -e "${WHITE}==================${NC}\n"

# 显示当前系统信息
echo -e "${PURPLE}=== 当前系统信息 ===${NC}"
echo -e "${CYAN}主机名:${NC} $(hostname)"
echo -e "${CYAN}内核版本:${NC} $(uname -r)"
echo -e "${CYAN}SSH端口:${NC} $SSH_PORT"
echo -e "${CYAN}Swap状态:${NC} $(free -h | grep '^Swap:' | awk '{print $2}')"
echo -e "${WHITE}==================${NC}\n"

# 重要提醒
echo -e "${YELLOW}⚠️  重要提醒：${NC}"
echo -e "${YELLOW}1. 请重启VPS以生效新内核：${NC} ${RED}reboot${NC}"
echo -e "${YELLOW}2. SSH端口已更改为: ${CYAN}$SSH_PORT${NC}"
echo -e "${YELLOW}3. Root密码已设置，请妥善保管${NC}"
echo -e "${WHITE}==================${NC}\n"

# Telegram通知（如果配置了）
if [[ "$CONFIGURE_TELEGRAM" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}📱 Telegram通知已配置${NC}"
fi

exit 0
