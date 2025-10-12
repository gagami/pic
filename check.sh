#!/bin/bash
# ================================================
# VPS 初始化结果检查脚本（增强版）
# 包含网络、端口、负载及交互式硬盘清理与优化后复查
# ================================================

log() {
    echo -e "\n\033[1;34m[*] $1\033[0m\n"
}

# -----------------------------
# 基础检查
# -----------------------------
check_hostname() {
    log "检查主机名..."
    echo "当前主机名: $(hostname)"
}

check_timezone() {
    log "检查系统时区..."
    echo "当前时区: $(timedatectl | grep 'Time zone')"
}

check_swap() {
    log "检查 Swap 是否生效..."
    if swapon --show | grep -q "/swapfile"; then
        echo -e "\033[1;32m[OK]\033[0m Swap 已启用"
    else
        echo -e "\033[1;31m[❌] 未启用 Swap\033[0m"
    fi
}

check_packages() {
    log "检查常用软件包是否安装..."
    packages=(wget curl git screen tmux tar unzip aria2 chrony fail2ban rsyslog ethtool)
    for pkg in "${packages[@]}"; do
        if dpkg -l | grep -qw "$pkg"; then
            echo -e "\033[1;32m[OK]\033[0m $pkg 已安装"
        else
            echo -e "\033[1;33m[⚠️] $pkg 未安装\033[0m"
        fi
    done
}

check_kernel() {
    log "检查内核版本与 XanMod 内核..."
    kernel=$(uname -r)
    echo "内核版本: $kernel"
    if echo "$kernel" | grep -q xanmod; then
        echo -e "\033[1;32m[OK] 当前使用 XanMod 内核\033[0m"
    else
        echo -e "\033[1;33m[⚠️] 未使用 XanMod 内核\033[0m"
    fi
}

check_sysctl() {
    log "检查关键 sysctl 参数..."
    declare -A expected=(
        [net.ipv4.tcp_timestamps]=1
        [net.core.wmem_default]=16384
        [net.core.rmem_default]=262144
        [net.ipv4.tcp_window_scaling]=1
        [net.ipv4.tcp_tw_reuse]=1
        [net.ipv4.tcp_max_tw_buckets]=55000
        [vm.swappiness]=10
        [fs.file-max]=1048575
    )
    for p in "${!expected[@]}"; do
        val=$(sysctl -n "$p" 2>/dev/null || echo "未设置")
        if [[ "$val" == "${expected[$p]}" ]]; then
            echo -e "\033[1;32m[OK]\033[0m $p = $val"
        else
            echo -e "\033[1;33m[⚠️] $p = $val (期望: ${expected[$p]})\033[0m"
        fi
    done
}

check_limits() {
    log "检查文件描述符限制..."
    limits=$(ulimit -n)
    if [[ "$limits" -ge 4096 ]]; then
        echo -e "\033[1;32m[OK]\033[0m 当前 shell 文件描述符限制: $limits"
    else
        echo -e "\033[1;33m[⚠️] 当前 shell 文件描述符限制过低: $limits\033[0m"
    fi
    grep -E 'nofile' /etc/security/limits.conf || echo -e "\033[1;33m[⚠️] limits.conf 中未找到 nofile 设置\033[0m"
}

check_ssh() {
    log "检查 SSH 配置..."
    SSH_PORT=$(grep -E '^Port' /etc/ssh/sshd_config | awk '{print $2}')
    PermitRootLogin=$(grep -E '^PermitRootLogin' /etc/ssh/sshd_config | awk '{print $2}')
    if [[ "$SSH_PORT" == "52222" ]]; then
        echo -e "\033[1;32m[OK]\033[0m SSH 端口: $SSH_PORT"
    else
        echo -e "\033[1;33m[⚠️] SSH 端口: $SSH_PORT (期望: 52222)\033[0m"
    fi
    if [[ "$PermitRootLogin" == "yes" ]]; then
        echo -e "\033[1;32m[OK]\033[0m PermitRootLogin 已开启"
    else
        echo -e "\033[1;33m[⚠️] PermitRootLogin 未开启\033[0m"
    fi
}

check_fail2ban() {
    log "检查 Fail2Ban 状态..."
    if systemctl is-active --quiet fail2ban; then
        echo -e "\033[1;32m[OK]\033[0m Fail2Ban 正常运行"
    else
        echo -e "\033[1;31m[❌] Fail2Ban 未运行\033[0m"
    fi
}

# -----------------------------
# 高级检查
# -----------------------------
check_load() {
    log "检查 CPU / 内存负载..."
    echo "CPU 核数: $(nproc)"
    echo "当前 CPU 使用率: $(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')%"
    echo "当前内存使用: $(free -h | awk '/Mem:/ {print $3 "/" $2}')"
}

check_disk() {
    log "检查硬盘空间..."
    df -h --output=source,size,used,avail,pcent,target | grep -v tmpfs
    threshold_warn=20
    threshold_crit=80

    root_usage=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')

    if [[ "$root_usage" -ge $threshold_crit ]]; then
        echo -e "\033[1;31m[❌] 根分区 / 使用率高: $root_usage%\033[0m"
        echo "建议清理方案："
        echo " 1. 清理 apt 缓存"
        echo " 2. 删除旧日志"
        echo " 3. 查找大文件"

        read -p "是否自动执行清理操作？(y/N): " CLEAN_CHOICE
        CLEAN_CHOICE=${CLEAN_CHOICE:-N}

        if [[ "$CLEAN_CHOICE" =~ ^[Yy]$ ]]; then
            log "开始清理 apt 缓存..."
            apt-get clean

            log "清理 7 天前的日志..."
            journalctl --vacuum-time=7d

            log "查找系统大文件（前 20 个）..."
            du -ahx / | sort -rh | head -20

            log "✅ 硬盘清理完成，正在重新检查根分区使用率..."
            root_usage_new=$(df -h / | tail -1 | awk '{print $5}')
            echo "根分区 / 当前使用率: $root_usage_new"
        else
            echo "跳过自动清理。"
        fi
    elif [[ "$root_usage" -ge $threshold_warn ]]; then
        echo -e "\033[1;33m[⚠️] 根分区 / 使用率: $root_usage%\033[0m"
    else
        echo -e "\033[1;32m[OK]\033[0m 根分区 / 使用率: $root_usage%"
    fi

    # 其他挂载点显示状态
    df -h --output=source,size,used,avail,pcent,target | grep -v tmpfs | tail -n +2 | grep -v "^/dev/root"
}

# ==============================
# 执行检查
# ==============================
check_hostname
check_timezone
check_swap
check_packages
check_kernel
check_sysctl
check_limits
check_ssh
check_fail2ban
check_disk
check_load

echo -e "\n\033[1;32m✅ VPS 初始化全方位检查完成！\033[0m\n"
