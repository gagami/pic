#!/bin/bash
# ================================================
# VPS 全自动初始化优化脚本 (优化版)
# 作者: yagami + ChatGPT 重构优化
# 系统: Ubuntu 22.04+
# ================================================

set -euo pipefail

log() {
    echo -e "\n\033[1;32m[+] $1\033[0m\n"
}

# -----------------------------
# 交互部分
# -----------------------------
echo "========== VPS 初始化脚本 =========="
read -p "请输入 VPS 主机名 (hostname): " NEW_HOSTNAME
[[ -z "$NEW_HOSTNAME" ]] && NEW_HOSTNAME="vps-default"

# -----------------------------
# 设置时区
# -----------------------------
read -p "请输入时区 (默认: Asia/Shanghai): " TIMEZONE_INPUT
TIMEZONE=${TIMEZONE_INPUT:-Asia/Shanghai}

read -p "请输入 root 登录密码: " ROOT_PASS
read -p "请再次输入 root 登录密码确认: " ROOT_PASS2
if [[ "$ROOT_PASS" != "$ROOT_PASS2" ]]; then
    echo "两次密码输入不一致！退出。"
    exit 1
fi


# -----------------------------
# 选择 XanMod 内核类型
# -----------------------------
echo
echo "请选择要安装的 XanMod 内核类型:"
select KERNEL_TYPE in "main" "edge"; do
    [[ "$KERNEL_TYPE" =~ ^(main|edge)$ ]] && XANMOD_KERNEL_TYPE=$KERNEL_TYPE && break
    echo "无效选择，请输入 1 或 2."
done

# -----------------------------
# 是否创建 Swap
# -----------------------------
echo
read -p "是否要创建或重置 swap 交换空间？(Y/n): " CREATE_SWAP
CREATE_SWAP=${CREATE_SWAP:-Y}

if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then
    read -p "请输入要创建的 swap 大小（MB，默认 1024）: " SWAP_SIZE
    SWAP_SIZE=${SWAP_SIZE:-1024}
else
    SWAP_SIZE=0
fi

# -----------------------------
# 安装必备软件
# -----------------------------
log "安装基础软件包..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get update -y
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo "[*] 等待 dpkg 锁释放..."
    sleep 3
done
apt-get install -y wget curl git screen tmux tar unzip aria2 \
ca-certificates gnupg lsb-release build-essential make gcc automake autoconf libtool \
libssl-dev libpam0g-dev net-tools iptables-persistent chrony fail2ban rsyslog ethtool

# -----------------------------
# 系统设置
# -----------------------------
hostnamectl set-hostname "$NEW_HOSTNAME"
echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
echo "root:${ROOT_PASS}" | chpasswd

log "配置主机名为: "$NEW_HOSTNAME"与密码: $ROOT_PASS"

# -----------------------------
# 设置时区
# -----------------------------

timedatectl set-timezone "$TIMEZONE"
apt-get install -y chrony >/dev/null
systemctl enable chrony --now
chronyc -a makestep

log "系统时区与时间同步已设置"


# -----------------------------
# 创建 Swap（可选）
# -----------------------------
if [[ "$SWAP_SIZE" -gt 0 ]]; then
    log "创建 ${SWAP_SIZE}MB Swap 分区..."
    SWAP_FILE="/swapfile"

    if swapon --show | grep -q "$SWAP_FILE"; then
        log "检测到已有 swap，正在删除旧 swap..."
        swapoff "$SWAP_FILE"
        rm -f "$SWAP_FILE"
    fi

    fallocate -l "${SWAP_SIZE}M" "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE" status=none
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" >/dev/null
    swapon "$SWAP_FILE"
    grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab

    sysctl vm.swappiness=10 >/dev/null
    sysctl vm.vfs_cache_pressure=50 >/dev/null

    log "Swap 创建完成 ✅"
else
    log "跳过创建 swap。"
fi

# -----------------------------
# 系统更新
# -----------------------------
log "系统更新与清理..."
# 等待 dpkg 锁释放
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo "[*] 等待 dpkg 锁释放..."
    sleep 3
done
DEBIAN_FRONTEND=noninteractive apt-get upgrade -yq
apt-get autoremove -y
apt-get clean

# -----------------------------
# SSH 设置
# -----------------------------
log "优化 SSH 设置..."
SSH_PORT=52222
sed -i "s/^#Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
sed -i "s/^#PermitRootLogin .*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
echo "ClientAliveInterval 60
ClientAliveCountMax 3" >> /etc/ssh/sshd_config
systemctl restart ssh

# -----------------------------
# Fail2Ban 配置
# -----------------------------
log "配置 Fail2Ban..."
systemctl enable rsyslog
systemctl restart rsyslog
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
filter   = sshd
logpath  = /var/log/auth.log
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# ==============================
# 自动检测 ABI 并安装 XanMod 内核（非交互）
# ==============================
log "正在检测系统 ABI 以选择正确的 XanMod 内核..."

# 获取 CPU 指令集
CPU_FLAGS=$(lscpu | grep "Flags" | awk -F: '{print $2}')

# ABI 检测
if echo "$CPU_FLAGS" | grep -q avx512; then
    ABI="x86-64-v4"
elif echo "$CPU_FLAGS" | grep -q avx2; then
    ABI="x86-64-v3"
elif echo "$CPU_FLAGS" | grep -q sse4_2; then
    ABI="x86-64-v2"
else
    ABI="x86-64-v1"
fi

echo "检测到 ABI: $ABI"

# 默认用户选择，保持之前交互变量 XANMOD_KERNEL_TYPE
# 如果没有交互，可以手动赋值，例如 XANMOD_KERNEL_TYPE="edge" 或 "main"

# 根据 ABI 选择内核包
case "$ABI" in
    x86-64-v1)
        PKG="linux-xanmod-x64v1"
        ;;
    x86-64-v4)
        # v4 CPU 用 v3 内核，但包名必须是 x64v3
        if [[ "$XANMOD_KERNEL_TYPE" == "edge" ]]; then
            PKG="linux-xanmod-edge-x64v3"
        else
            PKG="linux-xanmod-main-x64v3"
        fi
        ;;
    x86-64-v2)
        PKG="linux-xanmod-${XANMOD_KERNEL_TYPE}-x64v2"
        ;;
    x86-64-v3)
        PKG="linux-xanmod-${XANMOD_KERNEL_TYPE}-x64v3"
        ;;
    *)
        echo -e "\033[31m[错误]\033[0m 未识别 ABI: $ABI"
        exit 1
        ;;
esac


# 导入密钥和源
wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor | tee /usr/share/keyrings/xanmod-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" \
    | tee /etc/apt/sources.list.d/xanmod-kernel.list >/dev/null
apt-get update -y

# 检查包是否存在
if ! apt-cache show "$PKG" >/dev/null 2>&1; then
    echo -e "\033[31m[错误]\033[0m 找不到 XanMod 包 ($PKG)"
    exit 1
fi

log "正在安装: $PKG"
apt-get install -y "$PKG"

# 更新 grub
if command -v update-grub >/dev/null 2>&1; then
    update-grub
else
    grub-mkconfig -o /boot/grub/grub.cfg
fi

log "✅ XanMod 内核 ($PKG) 安装完成。"



# -----------------------------
# MOTD 信息
# -----------------------------
log "设置登录欢迎信息..."
cat > /etc/motd <<'EOF'
  ▄ ▄   ▄███▄   █     ▄█▄    ████▄ █▀▄▀█ ▄███▄       ▀▄    ▄ ██     ▄▀  ██   █▀▄▀█ ▄█       ▄
 █   █  █▀   ▀  █     █▀ ▀▄  █   █ █ █ █ █▀   ▀        █  █  █ █  ▄▀    █ █  █ █ █ ██      █
█ ▄   █ ██▄▄    █     █   ▀  █   █ █ ▄ █ ██▄▄           ▀█   █▄▄█ █ ▀▄  █▄▄█ █ ▄ █ ██     █
█  █  █ █▄   ▄▀ ███▄  █▄  ▄▀ ▀████ █   █ █▄   ▄▀        █    █  █ █   █ █  █ █   █ ▐█     █
 █ █ █  ▀███▀       ▀ ▀███▀           █  ▀███▀        ▄▀        █  ███     █    █   ▐
  ▀ ▀                                ▀                         █          █    ▀          ▀
  ┌───┐   ┌───┬───┬───┬───┐ ┌───┬───┬───┬───┐ ┌───┬───┬───┬───┐ ┌───┬───┬───┐
  │Esc│   │ F1│ F2│ F3│ F4│ │ F5│ F6│ F7│ F8│ │ F9│F10│F11│F12│ │P/S│S L│P/B│  ┌┐    ┌┐    ┌┐
  └───┘   └───┴───┴───┴───┘ └───┴───┴───┴───┘ └───┴───┴───┴───┘ └───┴───┴───┘  └┘    └┘    └┘
  ┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───────┐ ┌───┬───┬───┐ ┌───┬───┬───┬───┐
  │~ `│! 1│@ 2│# 3│$ 4│% 5│^ 6│& 7│* 8│( 9│) 0│_ -│+ =│ BacSp │ │Ins│Hom│PUp│ │N L│ / │ * │ - │
  ├───┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─────┤ ├───┼───┼───┤ ├───┼───┼───┼───┤
  │ Tab │ Q │ W │ E │ R │ T │ Y │ U │ I │ O │ P │{ [│} ]│ | \ │ │Del│End│PDn│ │ 7 │ 8 │ 9 │   │
  ├─────┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴┬──┴─────┤ └───┴───┴───┘ ├───┼───┼───┤ + │
  │ Caps │ A │ S │ D │ F │ G │ H │ J │ K │ L │: ;│" '│ Enter  │               │ 4 │ 5 │ 6 │   │
  ├──────┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴─┬─┴────────┤     ┌───┐     ├───┼───┼───┼───┤
  │ Shift  │ Z │ X │ C │ V │ B │ N │ M │< ,│> .│? /│  Shift   │     │ ↑ │     │ 1 │ 2 │ 3 │   │
  ├─────┬──┴─┬─┴──┬┴───┴───┴───┴───┴───┴──┬┴───┼───┴┬────┬────┤ ┌───┼───┼───┐ ├───┴───┼───┤ E││
  │ Ctrl│    │Alt │         Space         │ Alt│    │    │Ctrl│ │ ← │ ↓ │ → │ │   0   │ . │←─┘│
  └─────┴────┴────┴───────────────────────┴────┴────┴────┴────┘ └───┴───┴───┘ └───────┴───┴───┘
EOF

# -----------------------------
# BBR + 网络优化
# -----------------------------
log "应用网络优化与 BBR..."

# 直接写入 sysctl.conf（内容来源于远程文件或固定配置）
cat << 'EOF' > /etc/sysctl.conf
# =============================
# 系统网络内核优化配置
# =============================

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
log "✅ 内核参数已应用完成。"

# 调整TCP和UDP流量的优先级
interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo)
for interface in $interfaces; do
    echo "设置 TCP 和 UDP 流量优先级: $interface"
    iptables -A OUTPUT -t mangle -p tcp -o $interface -j MARK --set-mark 10
    iptables -A OUTPUT -t mangle -p udp -o $interface -j MARK --set-mark 20
    iptables -A PREROUTING -t mangle -i $interface -j MARK --set-mark 10
    iptables -A PREROUTING -t mangle -p udp -i $interface -j MARK --set-mark 20
done

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

# -----------------------------
# 完成提示
# -----------------------------
log "系统优化完成！请手动重启 VPS 生效新内核："
echo -e "\033[1;33mreboot\033[0m"
