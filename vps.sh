#!/bin/bash
# ==========================================================
# VPS 全自动初始化优化脚本 v12.8（整合增强版）
# 作者: yagami + ChatGPT 优化重构
# 系统: Ubuntu 22.04+
# ==========================================================

set -euo pipefail

# ------------------------------------------------
# 🧩 临时锁文件防止并发执行
# ------------------------------------------------
LOCK_FILE="/tmp/vps_init.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo -e "\033[31m[!] 已有脚本实例在运行，请稍后再试。\033[0m"
    exit 1
fi

# ------------------------------------------------
# 🧹 捕获异常自动清理临时文件
# ------------------------------------------------
cleanup() {
    echo -e "\n\033[33m[*] 检测到退出，正在清理临时文件...\033[0m"
    rm -f /tmp/check_abi_* "$LOCK_FILE" 2>/dev/null || true
}
trap cleanup EXIT

log() { echo -e "\n\033[1;32m[+] $1\033[0m\n"; }

# ------------------------------------------------
# ⚙️ apt 调用优化与 dpkg 锁处理函数
# ------------------------------------------------
wait_dpkg_lock() {
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        echo "[*] 等待 dpkg 锁释放..."
        sleep 2
    done
}

safe_apt() {
    wait_dpkg_lock
    DEBIAN_FRONTEND=noninteractive apt-get "$@" -yq
}

# ------------------------------------------------
# 交互输入
# ------------------------------------------------
echo "========== VPS 初始化脚本 =========="
read -p "请输入 VPS 主机名 (hostname): " NEW_HOSTNAME
[[ -z "$NEW_HOSTNAME" ]] && NEW_HOSTNAME="vps-default"

read -p "请输入时区 (默认: Asia/Shanghai): " TIMEZONE_INPUT
TIMEZONE=${TIMEZONE_INPUT:-Asia/Shanghai}

read -s -p "请输入 root 登录密码: " ROOT_PASS; echo
read -s -p "请再次输入 root 登录密码确认: " ROOT_PASS2; echo
if [[ "$ROOT_PASS" != "$ROOT_PASS2" ]]; then
    echo -e "\033[31m两次密码不一致，退出。\033[0m"
    exit 1
fi

echo
echo "请选择要安装的 XanMod 内核类型:"
select KERNEL_TYPE in "main" "edge"; do
    [[ "$KERNEL_TYPE" =~ ^(main|edge)$ ]] && XANMOD_KERNEL_TYPE=$KERNEL_TYPE && break
    echo "无效选择，请输入 1 或 2."
done

echo
read -p "是否要创建或重置 swap 交换空间？(Y/n): " CREATE_SWAP
CREATE_SWAP=${CREATE_SWAP:-Y}
if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then
    read -p "请输入要创建的 swap 大小（MB，默认 1024）: " SWAP_SIZE
    SWAP_SIZE=${SWAP_SIZE:-1024}
else
    SWAP_SIZE=0
fi

# ------------------------------------------------
# 配置 Telegram Token 和 Chat ID
# ------------------------------------------------
echo "========== 配置 Telegram Bot 信息 =========="
read -p "是否配置 Telegram Bot 信息？(Y/n): " CONFIGURE_TELEGRAM
CONFIGURE_TELEGRAM=${CONFIGURE_TELEGRAM:-Y}

if [[ "$CONFIGURE_TELEGRAM" =~ ^[Yy]$ ]]; then
    read -p "请输入 Telegram Bot 的 API Token: " TELEGRAM_TOKEN
    read -p "请输入 Telegram Chat ID（可以是个人的 ID 或群组的 ID）: " TELEGRAM_CHAT_ID

    # 设置 .env 文件路径
    ENV_FILE="/etc/profile.d/ssh_notify.sh.env"

    # 将信息写入 .env 文件
    echo "创建配置文件: $ENV_FILE"
    cat <<EOF > $ENV_FILE
# Telegram 配置信息
TELEGRAM_TOKEN=$TELEGRAM_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
EOF

    # 设置文件权限
    chmod 644 $ENV_FILE

    log "✅ Telegram 配置文件已创建：$ENV_FILE"

    # 提示重新加载配置文件
    echo "为了使配置生效，请执行 'source /etc/profile.d/ssh_notify.sh.env' 或重新启动终端。"

    # 下载并设置 ssh_notify.sh
    wget -qO /etc/profile.d/ssh_notify.sh https://raw.githubusercontent.com/gagami/pic/refs/heads/main/ssh_notify.sh
    chmod +x /etc/profile.d/ssh_notify.sh
    log "✅ ssh_notify.sh 脚本已下载并设置完成"
else
    log "跳过 Telegram 配置和相关脚本下载。"
fi

# ------------------------------------------------
# 安装基础包
# ------------------------------------------------
log "安装基础软件包..."
safe_apt update
safe_apt install wget curl git screen tmux tar unzip aria2 ca-certificates gnupg \
lsb-release build-essential make gcc automake autoconf libtool libssl-dev \
libpam0g-dev net-tools iptables-persistent chrony fail2ban rsyslog ethtool net-tools iproute2

sensors-detect --auto
log "✅ 基础软件包已安装"

# ------------------------------------------------
# 系统设置
# ------------------------------------------------
hostnamectl set-hostname "$NEW_HOSTNAME"
echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
echo "root:${ROOT_PASS}" | chpasswd
log "配置主机名为: $NEW_HOSTNAME"

timedatectl set-timezone "$TIMEZONE"
safe_apt install chrony
systemctl enable chrony --now
chronyc -a makestep
log "✅ 系统时区与时间同步已设置"

# ------------------------------------------------
# 💾 Swap 优化：自动检测已有 swap 并调整大小
# ------------------------------------------------
if [[ "$SWAP_SIZE" -gt 0 ]]; then
    log "检查 swap 状态..."
    EXISTING_SWAP=$(swapon --show=NAME --noheadings || true)
    if [[ -n "$EXISTING_SWAP" ]]; then
        CUR_SIZE=$(lsblk -bno SIZE "$EXISTING_SWAP" 2>/dev/null || echo 0)
        CUR_SIZE_MB=$((CUR_SIZE / 1024 / 1024))
        if (( CUR_SIZE_MB != SWAP_SIZE )); then
            log "检测到现有 swap ($EXISTING_SWAP, ${CUR_SIZE_MB}MB)，调整为 ${SWAP_SIZE}MB..."
            swapoff "$EXISTING_SWAP"
            rm -f "$EXISTING_SWAP"
            fallocate -l "${SWAP_SIZE}M" /swapfile 2>/dev/null || \
                dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE" status=none
            chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
            sed -i '/swapfile/d' /etc/fstab
            echo "/swapfile none swap sw 0 0" >> /etc/fstab
        else
            log "swap 大小一致，无需调整。"
        fi
    else
        log "未检测到 swap，创建 ${SWAP_SIZE}MB..."
        fallocate -l "${SWAP_SIZE}M" /swapfile 2>/dev/null || \
            dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE" status=none
        chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    sysctl vm.swappiness=10 >/dev/null
    sysctl vm.vfs_cache_pressure=50 >/dev/null
    log "Swap 配置完成 ✅"
else
    log "跳过创建 swap。"
fi

# ------------------------------------------------
# 系统更新与清理
# ------------------------------------------------
log "系统更新中..."
safe_apt upgrade
safe_apt autoremove
apt-get clean

# ------------------------------------------------
# SSH 设置
# ------------------------------------------------
log "优化 SSH 设置..."
SSH_PORT=52222
sed -i "s/^#Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
sed -i "s/^#PermitRootLogin .*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
echo "ClientAliveInterval 60
ClientAliveCountMax 3" >> /etc/ssh/sshd_config
systemctl restart ssh

log "✅ SSH 已设置..."

# ------------------------------------------------
# Fail2Ban 配置
# ------------------------------------------------
log "配置 Fail2Ban..."
systemctl enable rsyslog --now
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1
bantime  = 24h
findtime = 60
maxretry = 3
banaction = iptables-allports
[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = /var/log/auth.log
EOF
systemctl enable fail2ban --now
systemctl restart fail2ban

log "✅ Fail2Ban 已配置"

# ------------------------------------------------
# 自动检测 ABI 并安装 XanMod 内核
# ------------------------------------------------
log "正在检测 CPU ABI..."
CPU_FLAGS=$(lscpu | grep "Flags" | awk -F: '{print $2}')
if echo "$CPU_FLAGS" | grep -q avx512; then ABI="x86-64-v4"
elif echo "$CPU_FLAGS" | grep -q avx2; then ABI="x86-64-v3"
elif echo "$CPU_FLAGS" | grep -q sse4_2; then ABI="x86-64-v2"
else ABI="x86-64-v1"; fi
echo "检测到 ABI: $ABI"

case "$ABI" in
    x86-64-v1) PKG="linux-xanmod-x64v1" ;;
    x86-64-v4|x86-64-v3) PKG="linux-xanmod-${XANMOD_KERNEL_TYPE}-x64v3" ;;
    x86-64-v2) PKG="linux-xanmod-${XANMOD_KERNEL_TYPE}-x64v2" ;;
esac

wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor | tee /usr/share/keyrings/xanmod-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" > /etc/apt/sources.list.d/xanmod-kernel.list
safe_apt update
safe_apt install "$PKG"
update-grub || grub-mkconfig -o /boot/grub/grub.cfg
log "✅ XanMod 内核 ($PKG) 安装完成。"

# 直接写入 sysctl.conf（内容来源于远程文件或固定配置）
cat << 'EOF' > /etc/sysctl.conf
# ------------------------------------------------
# BBR + 网络优化
# ------------------------------------------------
log "应用 BBR 与网络优化..."
net.ipv4.tcp_timestamps = 1
net.core.wmem_default = 16384
net.core.rmem_default = 262144
net.core.rmem_max = 536870912
net.core.wmem_max = 536870912
net.ipv4.tcp_rmem = 8192 262144 536870912
net.ipv4.tcp_wmem = 4096 16384 536870912
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_notsent_lowat = 131072
net.core.netdev_max_backlog = 10240
net.ipv4.tcp_max_syn_backlog = 10240
net.core.somaxconn = 8192
net.ipv4.tcp_abort_on_overflow = 1
net.core.default_qdisc = fq_pie
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 55000
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_syncookies = 0
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_no_metrics_save = 1
net.unix.max_dgram_qlen = 1024
net.ipv4.route.gc_timeout = 100
net.ipv4.tcp_mtu_probing = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 2
net.ipv4.tcp_keepalive_intvl = 2
net.ipv4.tcp_max_orphans = 262144
net.ipv4.neigh.default.gc_thresh1 = 128
net.ipv4.neigh.default.gc_thresh2 = 512
net.ipv4.neigh.default.gc_thresh3 = 4096
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2
kernel.panic = 1
kernel.pid_max = 32768
kernel.shmmax = 4294967296
kernel.shmall = 1073741824
kernel.core_pattern = core_%e
vm.panic_on_oom = 1
vm.vfs_cache_pressure = 250
vm.swappiness = 10
vm.dirty_ratio = 10
vm.overcommit_memory = 1
fs.file-max = 1048575
fs.inotify.max_user_instances = 8192
kernel.sysrq = 1
vm.zone_reclaim_mode = 0
EOF
# 应用 sysctl 参数
sysctl -p
log "✅ BBR 与内核网络优化已应用。"

# 设置文件描述符限制
total_memory=$(free -m | awk '/^Mem:/{print $2}')
if [[ $total_memory -le 512 ]]; then
    limit=4096
else
    multiplier=$((total_memory / 512))
    limit=$((4096 * multiplier))
fi

echo "* hard nofile $limit" >> /etc/security/limits.conf
echo "* soft nofile $limit" >> /etc/security/limits.conf
log "✅ 文件描述符限制已设置为 $limit"

# ------------------------------------------------
# MOTD 欢迎信息
# ------------------------------------------------
log "设置登录欢迎信息..."
> /etc/motd
wget -qO /etc/profile.d/cyberops_motd.sh https://raw.githubusercontent.com/gagami/pic/refs/heads/main/cyberops_motd.sh
chmod +x /etc/profile.d/cyberops_motd.sh
#chmod -x /etc/update-motd.d/*

# ------------------------------------------------
# 完成提示
# ------------------------------------------------
log "✅ 系统优化完成！请执行 \033[1;33mreboot\033[0m 以启用新内核。"
