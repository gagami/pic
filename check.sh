#!/bin/bash
# ================================================
# VPS 系统状态检查脚本 (优化版 v3.0)
# 全面检查系统配置、性能、安全状态，并提供修复建议
# 作者: yagami + ChatGPT 重构优化
# 系统: Ubuntu 22.04+, Debian 12+
# ================================================

set -euo pipefail

# 全局变量
SCRIPT_VERSION="3.1"
LOG_FILE="/var/log/vps_check.log"
START_TIME=$(date +%s)
ERROR_COUNT=0
WARNING_COUNT=0
SUCCESS_COUNT=0
FIX_AVAILABLE=0

# 系统检测
detect_system() {
    # 初始化变量
    DISTRO="unknown"
    DISTRO_VERSION="unknown"
    ID=""
    VERSION_ID=""

    if [[ -f /etc/os-release ]]; then
        # 安全加载os-release文件
        source /etc/os-release || true
        DISTRO=${ID:-"unknown"}
        DISTRO_VERSION=${VERSION_ID:-"unknown"}
    fi

    log "INFO" "检测到系统: $DISTRO $DISTRO_VERSION"

    # 设置系统特定的包名和服务名
    case "$DISTRO" in
        "debian")
            # Debian 12 使用 systemd-journald
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

# 字符图标
OK="[${GREEN}✓${NC}]"
WARNING="[${YELLOW}⚠${NC}]"
ERROR="[${RED}✗${NC}]"
INFO="[${BLUE}ℹ${NC}]"
FIX="[${PURPLE}🔧${NC}]"

# 日志函数
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 控制台输出
    case "$level" in
        "INFO")
            echo -e "${CYAN}[*]${NC} $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[!]${NC} $message"
            ((WARNING_COUNT++))
            ;;
        "ERROR")
            echo -e "${RED}[❌]${NC} $message"
            ((ERROR_COUNT++))
            ;;
        "SUCCESS")
            echo -e "${GREEN}[✓]${NC} $message"
            ((SUCCESS_COUNT++))
            ;;
        "FIX")
            echo -e "${PURPLE}[🔧]${NC} $message"
            ((FIX_AVAILABLE++))
            ;;
    esac

    # 文件日志
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# 错误处理函数
handle_error() {
    local exit_code=$1
    local operation="$2"
    log "ERROR" "$operation 失败 (错误码: $exit_code)"
    return $exit_code
}

# 进度显示函数
show_progress() {
    local current=$1
    local total=$2
    local description="$3"
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))

    printf "\r${BLUE}[进度]${NC} %3d%% [" "$percent"
    printf "%*s" $filled | tr ' ' '='
    printf "%*s" $empty | tr ' ' '-'
    printf "] %s" "$description"

    if [[ $current -eq $total ]]; then
        echo
    fi
}

# 检查权限
check_permissions() {
    if [[ $EUID -ne 0 ]]; then
        log "WARN" "建议以root权限运行以获得完整检查结果"
        read -p "是否继续？(y/N): " CONTINUE
        CONTINUE=${CONTINUE:-N}
        if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# 权限检查函数
check_command() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 服务状态检查
check_service_status() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        return 0
    elif systemctl list-unit-files | grep -q "^$service.service"; then
        return 1
    else
        return 2
    fi
}

# ==============================
# 基础系统检查
# ==============================

check_system_info() {
    log "INFO" "收集系统基础信息..."

    echo -e "${WHITE}系统信息:${NC}"
    echo "  操作系统: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown')"
    echo "  内核版本: $(uname -r)"
    echo "  架构: $(uname -m)"
    echo "  运行时间: $(uptime -p 2>/dev/null || uptime)"
    echo "  当前用户: $(whoami)"
    echo "  权限: $([ $EUID -eq 0 ] && echo 'root' || echo '普通用户')"
}

check_hostname() {
    log "INFO" "检查主机名配置..."

    local current_hostname=$(hostname)
    local expected_hostname_file="/etc/hostname"
    local expected_hostname=""

    if [[ -f "$expected_hostname_file" ]]; then
        expected_hostname=$(cat "$expected_hostname_file" 2>/dev/null | tr -d '\n')
    fi

    echo "  当前主机名: $current_hostname"

    if [[ -n "$expected_hostname" && "$current_hostname" == "$expected_hostname" ]]; then
        log "SUCCESS" "主机名配置正确"
    elif [[ -z "$expected_hostname" ]]; then
        log "WARN" "未找到主机名配置文件"
    else
        log "WARN" "主机名与配置文件不一致"
        echo "  配置文件主机名: $expected_hostname"
        log "FIX" "可运行: hostnamectl set-hostname $current_hostname"
    fi
}

check_timezone() {
    log "INFO" "检查时区配置..."

    local current_timezone=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')
    if [[ -z "$current_timezone" ]]; then
        current_timezone=$(cat /etc/timezone 2>/dev/null || echo "Unknown")
    fi

    echo "  当前时区: $current_timezone"

    if [[ "$current_timezone" == "Asia/Shanghai" ]]; then
        log "SUCCESS" "时区配置为亚洲/上海"
    else
        log "WARN" "建议设置时区为 Asia/Shanghai"
        log "FIX" "可运行: timedatectl set-timezone Asia/Shanghai"
    fi
}

check_swap() {
    log "INFO" "检查Swap配置..."

    local swap_total=$(free -h | awk '/Swap:/ {print $2}')
    local swap_used=$(free -h | awk '/Swap:/ {print $3}')
    local swap_enabled=false

    if swapon --show 2>/dev/null | grep -q .; then
        swap_enabled=true
        echo "  Swap 总量: $swap_total"
        echo "  Swap 使用: $swap_used"
    fi

    if $swap_enabled; then
        log "SUCCESS" "Swap 已启用"

        # 检查swappiness
        local swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")
        echo "  Swappiness 值: $swappiness"

        if [[ $swappiness -le 10 ]]; then
            log "SUCCESS" "Swappiness 配置合理"
        else
            log "WARN" "建议降低 swappiness 值以优化性能"
            log "FIX" "可运行: echo 'vm.swappiness=10' >> /etc/sysctl.conf"
        fi
    else
        log "WARN" "Swap 未启用"
        log "FIX" "可创建 swap 文件: fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
    fi
}

# ==============================
# 软件包检查
# ==============================

check_packages() {
    log "INFO" "检查重要软件包安装状态..."

    local packages=(
        "wget:网络下载工具"
        "curl:HTTP客户端"
        "git:版本控制"
        "screen:终端复用"
        "tmux:终端复用"
        "tar:压缩工具"
        "unzip:解压工具"
        "nano:文本编辑器"
        "htop:系统监控"
        "net-tools:网络工具"
        "chrony:时间同步"
        "fail2ban:安全防护"
        "ethtool:网卡工具"
        "iptables-persistent:防火墙持久化"
        "software-properties-common:软件源管理"
    )

    # 根据系统类型调整软件包
    case "$DISTRO" in
        "debian")
            # Debian 12 默认使用 systemd-journald，rsyslog是可选的
            packages+=("rsyslog:日志服务")
            ;;
        "ubuntu")
            # Ubuntu 需要rsyslog
            packages+=("rsyslog:日志服务")
            ;;
        *)
            # 其他系统默认包含rsyslog
            packages+=("rsyslog:日志服务")
            ;;
    esac

    local installed_count=0
    local total_count=${#packages[@]}
    local current=0

    echo -e "${WHITE}软件包检查结果:${NC}"

    for package_info in "${packages[@]}"; do
        ((current++))
        show_progress $current $total_count "检查软件包"

        local package=$(echo "$package_info" | cut -d: -f1)
        local description=$(echo "$package_info" | cut -d: -f2)

        if dpkg -l | grep -qw "$package" 2>/dev/null; then
            echo "  $OK $package ($description)"
            ((installed_count++))
        else
            echo "  $WARNING $package ($description) - 未安装"
            log "FIX" "可运行: apt-get install $package -y"
        fi
    done

    echo
    log "INFO" "软件包安装率: $installed_count/$total_count ($((installed_count * 100 / total_count))%)"
}

# ==============================
# 内核与系统参数检查
# ==============================

check_kernel() {
    log "INFO" "检查内核配置..."

    local current_kernel=$(uname -r)
    echo "  当前内核: $current_kernel"

    # 检查是否为XanMod内核
    if echo "$current_kernel" | grep -q "xanmod"; then
        log "SUCCESS" "检测到 XanMod 内核"
    else
        log "WARN" "未使用 XanMod 内核，可能影响网络性能"
        log "FIX" "可参考安装 XanMod 内核以提升性能"
    fi

    # 检查内核版本
    local kernel_version=$(echo "$current_kernel" | cut -d. -f1-2)
    if [[ "$(printf '%s\n' "5.15" "$kernel_version" | sort -V | head -n1)" == "5.15" ]]; then
        log "SUCCESS" "内核版本较新"
    else
        log "WARN" "内核版本较旧，建议升级"
    fi

    # 检查BBR支持状态
    local bbr_loaded=$(lsmod | grep -q "tcp_bbr" && echo "true" || echo "false")
    local congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")

    echo "  拥塞控制算法: $congestion_control"
    echo "  队列调度算法: $qdisc"

    if [[ "$congestion_control" == "bbr" ]]; then
        if $bbr_loaded; then
            log "SUCCESS" "BBR 拥塞控制已启用"
        else
            log "WARN" "BBR 已配置但模块未加载"
        fi
    elif [[ "$congestion_control" == "cubic" ]]; then
        if ! modinfo tcp_bbr >/dev/null 2>&1; then
            log "INFO" "当前内核不支持 BBR，使用 cubic 算法"
        else
            log "WARN" "BBR 可用但未启用，当前使用 cubic"
            log "FIX" "可运行: sysctl -w net.ipv4.tcp_congestion_control=bbr"
        fi
    else
        log "WARN" "未知的拥塞控制算法: $congestion_control"
    fi
}

check_bbr_support() {
    log "INFO" "检查BBR拥塞控制支持..."

    # 检查内核是否支持BBR
    if modinfo tcp_bbr >/dev/null 2>&1; then
        echo "  $OK 内核支持 BBR 模块"

        # 检查模块是否已加载
        if lsmod | grep -q "tcp_bbr"; then
            echo "  $OK BBR 模块已加载"
        else
            echo "  $INFO BBR 模块未加载"
            log "FIX" "可运行: modprobe tcp_bbr"
        fi

        # 检查配置文件中的设置
        local sysctl_bbr=$(grep -h "net.ipv4.tcp_congestion_control.*=.*bbr" /etc/sysctl.d/*.conf 2>/dev/null | head -n1 || echo "")
        if [[ -n "$sysctl_bbr" ]]; then
            echo "  $OK 配置文件中已设置 BBR"
        else
            echo "  $WARN 配置文件未设置 BBR"
        fi
    else
        echo "  $WARN 内核不支持 BBR"
        log "INFO" "建议安装支持 BBR 的内核 (如 XanMod)"
    fi
}

check_sysctl() {
    log "INFO" "检查系统内核参数..."

    declare -A expected=(
        ["net.core.rmem_default"]="262144"
        ["net.core.rmem_max"]="536870912"
        ["net.core.wmem_default"]="262144"
        ["net.core.wmem_max"]="536870912"
        ["net.ipv4.tcp_rmem"]="4096 65536 16777216"
        ["net.ipv4.tcp_wmem"]="4096 65536 16777216"
        ["net.ipv4.tcp_window_scaling"]="1"
        ["net.ipv4.tcp_fin_timeout"]="15"
        ["net.ipv4.tcp_keepalive_time"]="1200"
        ["vm.swappiness"]="10"
        ["vm.vfs_cache_pressure"]="50"
        ["vm.dirty_ratio"]="15"
        ["vm.dirty_background_ratio"]="5"
        ["fs.file-max"]="1048576"
        ["fs.inotify.max_user_watches"]="524288"
        ["net.ipv4.ip_forward"]="1"
        ["kernel.pid_max"]="32768"
        ["kernel.threads-max"]="65535"
    )

    local optimized_count=0
    local total_params=${#expected[@]}

    echo -e "${WHITE}内核参数检查:${NC}"

    for param in "${!expected[@]}"; do
        local expected_value=${expected[$param]}
        local current_value=$(sysctl -n "$param" 2>/dev/null || echo "未设置")

        if [[ "$current_value" == "$expected_value" ]]; then
            echo "  $OK $param = $current_value"
            ((optimized_count++))
        else
            echo "  $WARNING $param = $current_value (期望: $expected_value)"
        fi
    done

    echo
    local optimization_rate=$((optimized_count * 100 / total_params))
    log "INFO" "内核参数优化率: $optimized_count/$total_params ($optimization_rate%)"

    if [[ $optimization_rate -lt 80 ]]; then
        log "WARN" "建议优化内核参数以提升系统性能"
    fi
}

check_limits() {
    log "INFO" "检查系统限制配置..."

    # 检查当前shell限制
    local current_nofile=$(ulimit -n)
    echo "  当前文件描述符限制: $current_nofile"

    if [[ $current_nofile -ge 65536 ]]; then
        log "SUCCESS" "文件描述符限制充足"
    elif [[ $current_nofile -ge 4096 ]]; then
        log "WARN" "文件描述符限制偏低"
        log "FIX" "可运行: ulimit -n 65536 (临时)"
    else
        log "ERROR" "文件描述符限制过低"
        log "FIX" "建议修改 /etc/security/limits.conf"
    fi

    # 检查limits.conf配置
    local limits_conf="/etc/security/limits.conf"
    if [[ -f "$limits_conf" ]]; then
        if grep -q "nofile.*65536" "$limits_conf"; then
            log "SUCCESS" "limits.conf 配置了高文件描述符限制"
        else
            log "WARN" "limits.conf 未配置高文件描述符限制"
            echo "  建议添加以下行到 $limits_conf:"
            echo "    * soft nofile 65536"
            echo "    * hard nofile 65536"
        fi
    else
        log "ERROR" "未找到 limits.conf 文件"
    fi
}

# ==============================
# 网络与服务检查
# ==============================

check_network_interfaces() {
    log "INFO" "检查网络接口配置..."

    echo -e "${WHITE}网络接口:${NC}"
    ip link show | grep -E '^[0-9]+:' | while read line; do
        local interface=$(echo "$line" | cut -d: -f2 | tr -d ' ')
        local status=$(echo "$line" | grep -o 'state [A-Z]*' | cut -d' ' -f2 || echo "UNKNOWN")

        if [[ "$status" == "UP" ]]; then
            echo "  $OK $interface: $status"
        else
            echo "  $WARNING $interface: $status"
        fi

        # 显示IP地址
        local ip_addr=$(ip addr show "$interface" 2>/dev/null | grep 'inet ' | head -n1 | awk '{print $2}' || echo "无IP")
        if [[ -n "$ip_addr" && "$ip_addr" != "无IP" ]]; then
            echo "    IP: $ip_addr"
        fi
    done
}

check_connectivity() {
    log "INFO" "检查网络连通性..."

    local test_hosts=("8.8.8.8" "1.1.1.1" "baidu.com")
    local connected_count=0

    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
            echo "  $OK 连接到 $host"
            ((connected_count++))
        else
            echo "  $ERROR 无法连接到 $host"
        fi
    done

    if [[ $connected_count -eq ${#test_hosts[@]} ]]; then
        log "SUCCESS" "网络连通性良好"
    elif [[ $connected_count -gt 0 ]]; then
        log "WARN" "部分网络连接异常"
    else
        log "ERROR" "网络连接存在问题"
    fi
}

check_ssh_config() {
    log "INFO" "检查SSH配置..."

    local ssh_config="/etc/ssh/sshd_config"
    if [[ ! -f "$ssh_config" ]]; then
        log "ERROR" "SSH配置文件不存在"
        return
    fi

    # 检查SSH端口
    local ssh_port=$(grep -E '^Port' "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "22")
    echo "  SSH 端口: $ssh_port"

    # 检查Root登录
    local permit_root=$(grep -E '^PermitRootLogin' "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "prohibit-password")
    echo "  Root 登录: $permit_root"

    # 检查密码认证
    local password_auth=$(grep -E '^PasswordAuthentication' "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "yes")
    echo "  密码认证: $password_auth"

    # 安全建议
    if [[ "$ssh_port" == "22" ]]; then
        log "WARN" "建议更改SSH默认端口"
    fi

    if [[ "$permit_root" == "yes" ]]; then
        log "WARN" "建议禁用Root直接登录"
    fi

    if [[ "$password_auth" == "yes" ]]; then
        log "WARN" "建议使用密钥认证，禁用密码认证"
    fi
}

check_firewall() {
    log "INFO" "检查防火墙配置..."

    # 检查iptables
    if command -v iptables >/dev/null 2>&1; then
        local iptables_rules=$(iptables -L | wc -l)
        echo "  iptables 规则数: $iptables_rules"

        if [[ $iptables_rules -gt 10 ]]; then
            log "SUCCESS" "iptables 已配置"
        else
            log "WARN" "iptables 规则较少"
        fi
    else
        log "WARN" "iptables 未安装"
    fi

    # 检查ufw状态
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status=$(ufw status 2>/dev/null | head -n1 || echo "Status: unknown")
        echo "  UFW 状态: $ufw_status"
    fi

    # 检查开放端口
    echo -e "${WHITE}监听端口:${NC}"
    netstat -tuln 2>/dev/null | grep LISTEN | head -10 | while read line; do
        local port=$(echo "$line" | awk '{print $4}' | cut -d: -f2)
        local protocol=$(echo "$line" | awk '{print $1}')
        echo "  $OK $port/$protocol"
    done
}

# ==============================
# 服务状态检查
# ==============================

check_services() {
    log "INFO" "检查重要服务状态..."

    local services=(
        "ssh:SSH服务"
        "fail2ban:入侵防护"
        "chrony:时间同步"
        "$SYSLOG_SERVICE:日志服务"
        "nginx:Web服务器"
        "apache2:Web服务器"
        "mysql:数据库服务"
        "postgresql:数据库服务"
        "docker:容器服务"
        "ufw:防火墙服务"
    )

    echo -e "${WHITE}服务状态检查:${NC}"

    for service_info in "${services[@]}"; do
        local service=$(echo "$service_info" | cut -d: -f1)
        local description=$(echo "$service_info" | cut -d: -f2)

        check_service_status "$service"
        local status=$?

        case $status in
            0)
                echo "  $OK $service ($description) - 运行中"
                ;;
            1)
                echo "  $WARNING $service ($description) - 已停止"
                log "FIX" "可运行: systemctl start $service"
                ;;
            2)
                echo "  $INFO $service ($description) - 未安装"
                ;;
        esac
    done
}

check_fail2ban() {
    log "INFO" "检查Fail2Ban配置..."

    if ! check_service_status "fail2ban"; then
        log "WARN" "Fail2Ban 服务未运行"
        return
    fi

    # 检查jail状态
    echo -e "${WHITE}Fail2Ban 监控状态:${NC}"
    fail2ban-client status 2>/dev/null | grep -E "Jail list|Status" | while read line; do
        echo "  $INFO $line"
    done

    # 检查被封IP数量
    local banned_count=$(fail2ban-client status 2>/dev/null | grep "Currently failed:" | awk '{print $3}' || echo "0")
    if [[ $banned_count -gt 0 ]]; then
        log "WARN" "当前有 $banned_count 个IP被封禁"
    else
        log "SUCCESS" "Fail2Ban 工作正常"
    fi
}

# ==============================
# 系统性能检查
# ==============================

check_system_performance() {
    log "INFO" "检查系统性能状态..."

    echo -e "${WHITE}CPU 信息:${NC}"
    echo "  CPU 型号: $(grep 'model name' /proc/cpuinfo 2>/dev/null | head -n1 | cut -d: -f2 | sed 's/^ *//')"
    echo "  CPU 核数: $(nproc)"
    echo "  CPU 使用率: $(top -bn1 | grep "Cpu(s)" 2>/dev/null | awk '{print $2}' | sed 's/%us,//' || echo "无法获取")%"

    echo -e "${WHITE}内存信息:${NC}"
    local memory_info=$(free -h 2>/dev/null)
    echo "$memory_info" | head -n2

    local memory_usage=$(free | awk '/Mem:/ {printf "%.1f", $3/$2 * 100.0}' 2>/dev/null || echo "0")
    if (( $(echo "$memory_usage > 80" | bc -l) )); then
        log "WARN" "内存使用率过高: ${memory_usage}%"
    elif (( $(echo "$memory_usage > 60" | bc -l) )); then
        log "INFO" "内存使用率: ${memory_usage}%"
    else
        log "SUCCESS" "内存使用率正常: ${memory_usage}%"
    fi

    echo -e "${WHITE}负载信息:${NC}"
    local load_avg=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | sed 's/^ *//')
    echo "  系统负载: $load_avg"
}

check_disk_performance() {
    log "INFO" "检查磁盘性能..."

    local disk=$(df / | tail -n1 | awk '{print $1}')
    echo "  系统盘: $disk"

    # 磁盘I/O测试
    if command -v dd >/dev/null 2>&1; then
        echo "  执行磁盘写入测试..."
        local write_speed=$(dd if=/dev/zero of=/tmp/test_file bs=1M count=100 2>&1 | grep -o '[0-9.]\+ MB/s' | head -n1 || echo "测试失败")
        rm -f /tmp/test_file 2>/dev/null || true
        echo "  写入速度: $write_speed"
    fi

    # 检查磁盘使用率
    check_disk_space
}

check_disk_space() {
    echo -e "${WHITE}磁盘空间:${NC}"
    df -h | grep -v tmpfs | while read line; do
        local filesystem=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local used=$(echo "$line" | awk '{print $3}')
        local avail=$(echo "$line" | awk '{print $4}')
        local usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
        local mount=$(echo "$line" | awk '{print $6}')

        if [[ $usage -ge 90 ]]; then
            echo "  $ERROR $filesystem ($mount): ${usage}% 使用 (${used}/${size})"
        elif [[ $usage -ge 80 ]]; then
            echo "  $WARNING $filesystem ($mount): ${usage}% 使用 (${used}/${size})"
        else
            echo "  $OK $filesystem ($mount): ${usage}% 使用 (${used}/${size})"
        fi
    done
}

# ==============================
# 安全检查
# ==============================

check_security() {
    log "INFO" "检查安全配置..."

    # 检测日志路径
    local auth_log_path="/var/log/auth.log"
    if [[ ! -f "$auth_log_path" ]]; then
        auth_log_path="/var/log/secure"
    fi
    if [[ ! -f "$auth_log_path" ]]; then
        auth_log_path="/var/log/messages"
    fi

    log "INFO" "使用安全日志路径: $auth_log_path"

    # 检查登录失败记录
    local failed_logins=$(grep "Failed password" "$auth_log_path" 2>/dev/null | wc -l || echo "0")
    if [[ $failed_logins -gt 100 ]]; then
        log "WARN" "检测到大量登录失败尝试: $failed_logins 次"
    fi

    # 检查sudo配置
    if grep -q "NOPASSWD" /etc/sudoers 2>/dev/null; then
        log "WARN" "发现无密码sudo配置，存在安全风险"
    fi

    # 检查重要文件权限
    local sensitive_files=("/etc/passwd" "/etc/shadow" "/etc/ssh/sshd_config")
    for file in "${sensitive_files[@]}"; do
        if [[ -f "$file" ]]; then
            local perms=$(stat -c "%a" "$file" 2>/dev/null || echo "unknown")
            case "$file" in
                "/etc/passwd")
                    if [[ "$perms" == "644" ]]; then
                        echo "  $OK $file 权限: $perms"
                    else
                        echo "  $WARNING $file 权限: $perms (建议: 644)"
                    fi
                    ;;
                "/etc/shadow")
                    if [[ "$perms" == "600" ]]; then
                        echo "  $OK $file 权限: $perms"
                    else
                        echo "  $ERROR $file 权限: $perms (建议: 600)"
                    fi
                    ;;
                "/etc/ssh/sshd_config")
                    if [[ "$perms" == "600" ]]; then
                        echo "  $OK $file 权限: $perms"
                    else
                        echo "  $WARNING $file 权限: $perms (建议: 600)"
                    fi
                    ;;
            esac
        fi
    done
}

# ==============================
# 交互式修复功能
# ==============================

interactive_fix() {
    if [[ $FIX_AVAILABLE -eq 0 ]]; then
        log "INFO" "系统配置良好，无需修复"
        return
    fi

    echo
    log "INFO" "发现 $FIX_AVAILABLE 个可优化项目"
    read -p "是否查看修复建议？(y/N): " SHOW_FIXES
    SHOW_FIXES=${SHOW_FIXES:-N}

    if [[ "$SHOW_FIXES" =~ ^[Yy]$ ]]; then
        echo -e "\n${PURPLE}=== 修复建议 ===${NC}"
        echo "1. 更新系统包: apt-get update && apt-get upgrade -y"
        echo "2. 安装缺失软件包: apt-get install wget curl git htop -y"
        echo "3. 优化内核参数: echo 'vm.swappiness=10' >> /etc/sysctl.conf"
        echo "4. 配置文件描述符限制: 编辑 /etc/security/limits.conf"
        echo "5. 配置防火墙规则: iptables -A INPUT -p tcp --dport 22 -j ACCEPT"
        echo "6. 修改SSH配置: 编辑 /etc/ssh/sshd_config"
        echo "7. 清理磁盘空间: apt-get clean && journalctl --vacuum-time=7d"

        read -p "是否自动执行基本优化？(y/N): " AUTO_FIX
        AUTO_FIX=${AUTO_FIX:-N}
        if [[ "$AUTO_FIX" =~ ^[Yy]$ ]]; then
            auto_fix_system
        fi
    fi
}

auto_fix_system() {
    log "INFO" "执行自动优化..."

    # 更新包列表
    if check_command "apt-get"; then
        log "INFO" "更新软件包列表..."
        apt-get update >/dev/null 2>&1 || log "WARN" "更新失败"
    fi

    # 优化sysctl参数
    log "INFO" "优化内核参数..."
    cat << EOF >> /etc/sysctl.conf 2>/dev/null || true
# Auto optimization by VPS check script
vm.swappiness=10
net.ipv4.tcp_tw_reuse=1
fs.file-max=1048576
net.ipv4.tcp_keepalive_time=1200
net.ipv4.tcp_fin_timeout=15
EOF

    # 尝试配置BBR（如果支持）
    if modinfo tcp_bbr >/dev/null 2>&1; then
        log "INFO" "配置BBR拥塞控制..."
        cat << EOF >> /etc/sysctl.conf 2>/dev/null || true
# BBR optimization
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        # 尝试加载BBR模块
        modprobe tcp_bbr 2>/dev/null || log "WARN" "BBR模块加载失败"
    fi

    # 重新加载sysctl
    sysctl -p >/dev/null 2>&1 || log "WARN" "sysctl配置重载失败"

    log "SUCCESS" "基本优化完成"
}

# ==============================
# 主程序
# ==============================

main() {
    # 初始化日志
    echo "VPS系统检查开始 - $(date)" > "$LOG_FILE" 2>/dev/null || true

    echo -e "${WHITE}=======================================${NC}"
    echo -e "${WHITE}    VPS 系统状态检查工具 v$SCRIPT_VERSION${NC}"
    echo -e "${WHITE}=======================================${NC}"
    echo

    check_permissions

    # 系统检测
    detect_system

    # 系统信息检查
    check_system_info
    echo

    # 基础配置检查
    check_hostname
    check_timezone
    check_swap
    echo

    # 软件包检查
    check_packages
    echo

    # 内核与参数检查
    check_kernel
    check_bbr_support
    check_sysctl
    check_limits
    echo

    # 网络检查
    check_network_interfaces
    check_connectivity
    check_ssh_config
    check_firewall
    echo

    # 服务检查
    check_services
    check_fail2ban
    echo

    # 性能检查
    check_system_performance
    check_disk_performance
    echo

    # 安全检查
    check_security
    echo

    # 统计信息
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))

    echo -e "${WHITE}=======================================${NC}"
    echo -e "${WHITE}           检查结果统计${NC}"
    echo -e "${WHITE}=======================================${NC}"
    echo -e "  ${GREEN}✓${NC} 正常项目: $SUCCESS_COUNT"
    echo -e "  ${YELLOW}⚠${NC} 警告项目: $WARNING_COUNT"
    echo -e "  ${RED}✗${NC} 错误项目: $ERROR_COUNT"
    echo -e "  ${PURPLE}🔧${NC} 可优化: $FIX_AVAILABLE"
    echo -e "  检查耗时: ${duration} 秒"
    echo -e "  日志文件: $LOG_FILE"
    echo

    if [[ $ERROR_COUNT -eq 0 ]]; then
        if [[ $WARNING_COUNT -eq 0 ]]; then
            echo -e "${GREEN}[✓] 系统状态优秀！${NC}"
        else
            echo -e "${YELLOW}[!] 系统基本正常，有 $WARNING_COUNT 项建议优化${NC}"
        fi
    else
        echo -e "${RED}[✗] 发现 $ERROR_COUNT 个问题需要处理${NC}"
    fi

    echo

    # 交互式修复
    interactive_fix

    echo -e "${GREEN}✓ VPS系统检查完成！${NC}"
}

# 运行主程序
main "$@"
