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

timedatectl set-timezone Asia/Shanghai
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
# 自动检测 ABI 并安装 XanMod 内核
# ==============================
log "检测 CPU 架构并安装 XanMod 内核..."

# 下载检测脚本
TMP_ABI_SCRIPT="/tmp/check_x86-64_psabi.sh"
wget -qO "$TMP_ABI_SCRIPT" https://dl.xanmod.org/check_x86-64_psabi.sh
chmod +x "$TMP_ABI_SCRIPT"

# 用 awk 执行检测脚本
ABI=$(awk -f "$TMP_ABI_SCRIPT" | tr -d '\r' | head -n1)
rm -f "$TMP_ABI_SCRIPT"

if [[ -z "$ABI" ]]; then
    echo -e "\033[33m[警告]\033[0m 无法检测到 ABI，默认使用 x86-64-v2。"
    ABI="x86-64-v2"
fi

echo "检测到 ABI 架构: ${ABI}"

# 导入签名密钥与源
wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor | tee /usr/share/keyrings/xanmod-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" \
    | tee /etc/apt/sources.list.d/xanmod-kernel.list >/dev/null

apt-get update -y

# 根据 ABI 自动选择合适内核包
case "$ABI" in
    *x86-64-v1*)
        if [[ "$KERNEL_TYPE" == "edge" ]]; then
            echo -e "\033[33m[警告]\033[0m v1 架构不支持 Edge 内核，自动切换为 main。"
            KERNEL_TYPE="main"
        fi
        PKG="linux-xanmod-x64v1"
        ;;
    *x86-64-v2*)
        PKG="linux-xanmod-${KERNEL_TYPE}-x64v2"
        ;;
    *x86-64-v3*)
        PKG="linux-xanmod-${KERNEL_TYPE}-x64v3"
        ;;
    *x86-64-v4*)
        PKG="linux-xanmod-${KERNEL_TYPE}-x64v4"
        ;;
    *)
        echo -e "\033[33m[警告]\033[0m 未能识别 ABI，默认使用 v3 内核。"
        PKG="linux-xanmod-${KERNEL_TYPE}-x64v3"
        ;;
esac

# 检查包是否存在
if ! apt-cache show "$PKG" >/dev/null 2>&1; then
    echo -e "\033[31m[错误]\033[0m 找不到对应的 XanMod 包 ($PKG)。"
    echo "请检查网络或更换为 main 版本再试。"
    exit 1
fi

log "正在安装: ${PKG}"
apt-get install -y "$PKG"

# 更新 grub
if command -v update-grub >/dev/null 2>&1; then
    update-grub
else
    grub-mkconfig -o /boot/grub/grub.cfg
fi

log "✅ XanMod 内核 (${PKG}) 安装完成。"


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
log "应用网络优化与BBR..."

# 获取所有网络接口的名称
interfaces=$(nmcli device status | awk '{print $1}' | grep -v DEVICE)

# 循环遍历每个网络接口
for interface in $interfaces; do
# 使用nmcli增加环缓冲的大小
echo "Setting ring buffer size for interface $interface..."
sudo nmcli connection modify $interface txqueuelen 10000

# 调优网络设备积压队列以避免数据包丢弃
echo "Tuning network device backlog for interface $interface..."
sudo nmcli connection modify $interface rxqueuelen 10000

# 增加NIC的传输队列长度
echo "Increasing NIC transmission queue length for interface $interface..."
sudo nmcli connection modify $interface transmit-hash-policy layer2+3
done

# 备份原始配置文件
cp /etc/sysctl.conf /etc/sysctl.conf.bak

# 配置内核参数
cat << EOF > /etc/sysctl.conf
# ------ 网络调优: 基本 ------
# TTL 配置, Linux 默认 64
# net.ipv4.ip_default_ttl=64

# 参阅 RFC 1323. 应当启用.
net.ipv4.tcp_timestamps=1
# ------ END 网络调优: 基本 ------

# ------ 网络调优: 内核 Backlog 队列和缓存相关 ------
# Ref: https://www.starduster.me/2020/03/02/linux-network-tuning-kernel-parameter/
# Ref: https://blog.cloudflare.com/optimizing-tcp-for-high-throughput-and-low-latency/
# Ref: https://zhuanlan.zhihu.com/p/149372947
# 有条件建议依据实测结果调整相关数值
# 缓冲区相关配置均和内存相关
net.core.wmem_default=16384
net.core.rmem_default=262144
net.core.rmem_max=536870912
net.core.wmem_max=536870912
net.ipv4.tcp_rmem=8192 262144 536870912
net.ipv4.tcp_wmem=4096 16384 536870912
net.ipv4.tcp_adv_win_scale=-2
net.ipv4.tcp_collapse_max_bytes=6291456
net.ipv4.tcp_notsent_lowat=131072
net.core.netdev_max_backlog=10240
net.ipv4.tcp_max_syn_backlog=10240
net.core.somaxconn=8192
net.ipv4.tcp_abort_on_overflow=1
# 流控和拥塞控制相关调优
# Egress traffic control 相关. 可选 fq, cake
# 实测二者区别不大, 保持默认 fq 即可
net.core.default_qdisc=fq_pie
# Xanmod 内核 6.X 版本目前默认使用 bbr3, 无需设置
# 实测比 bbr, bbr2 均有提升
# 不过网络条件不同会影响. 有需求请实测.
# net.ipv4.tcp_congestion_control=bbr3
# 显式拥塞通知
# 已被发现在高度拥塞的网络上是有害的.
# net.ipv4.tcp_ecn=1
# TCP 自动窗口
# 要支持超过 64KB 的 TCP 窗口必须启用
net.ipv4.tcp_window_scaling=1
# 开启后, TCP 拥塞窗口会在一个 RTO 时间
# 空闲之后重置为初始拥塞窗口 (CWND) 大小.
# 大部分情况下, 尤其是大流量长连接, 设置为 0.
# 对于网络情况时刻在相对剧烈变化的场景, 设置为 1.
net.ipv4.tcp_slow_start_after_idle=0
# nf_conntrack 调优
# Add Ref: https://gist.github.com/lixingcong/0e13b4123d29a465e364e230b2e45f60
net.nf_conntrack_max=1000000
net.netfilter.nf_conntrack_max=1000000
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_close_wait=15
net.netfilter.nf_conntrack_tcp_timeout_established=300
net.ipv4.netfilter.ip_conntrack_tcp_timeout_established=7200
# TIME-WAIT 状态调优
# Ref: http://vincent.bernat.im/en/blog/2014-tcp-time-wait-state-linux.html
# Ref: https://www.cnblogs.com/lulu/p/4149312.html
# 4.12 内核中此参数已经永久废弃, 不用纠结是否需要开启
# net.ipv4.tcp_tw_recycle=0
## 只对客户端生效, 服务器连接上游时也认为是客户端
net.ipv4.tcp_tw_reuse=1
# 系统同时保持TIME_WAIT套接字的最大数量
# 如果超过这个数字 TIME_WAIT 套接字将立刻被清除
net.ipv4.tcp_max_tw_buckets=55000
# ------ END 网络调优: 内核 Backlog 队列和缓存相关 ------

# ------ 网络调优: 其他 ------
# Ref: https://zhuanlan.zhihu.com/p/149372947
# Ref: https://www.starduster.me/2020/03/02/linux-network-tuning-kernel-parameter/#netipv4tcp_max_syn_backlog_netipv4tcp_syncookies
# 启用选择应答
# 对于广域网通信应当启用
net.ipv4.tcp_sack=1
# 启用转发应答
# 对于广域网通信应当启用
net.ipv4.tcp_fack=1
# TCP SYN 连接超时重传次数
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
# TCP SYN 连接超时时间, 设置为 5 约为 30s
net.ipv4.tcp_retries2=5
# 开启 SYN 洪水攻击保护
# 注意: tcp_syncookies 启用时, 此时实际上没有逻辑上的队列长度, 
# Backlog 设置将被忽略. syncookie 是一个出于对现实的妥协, 
# 严重违反 TCP 协议的设计, 会造成 TCP option 不可用, 且实现上
# 通过计算 hash 避免维护半开连接也是一种 tradeoff 而非万金油, 
# 勿听信所谓“安全优化教程”而无脑开启
net.ipv4.tcp_syncookies=0

# Ref: https://linuxgeeks.github.io/2017/03/20/212135-Linux%E5%86%85%E6%A0%B8%E5%8F%82%E6%95%B0rp_filter/
# 开启反向路径过滤
# Aliyun 负载均衡实例后端的 ECS 需要设置为 0
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.all.rp_filter=2

# 减少处于 FIN-WAIT-2 连接状态的时间使系统可以处理更多的连接
# Ref: https://www.cnblogs.com/kaishirenshi/p/11544874.html
net.ipv4.tcp_fin_timeout=10

# Ref: https://xwl-note.readthedocs.io/en/latest/linux/tuning.html
# 默认情况下一个 TCP 连接关闭后, 把这个连接曾经有的参数保存到dst_entry中
# 只要 dst_entry 没有失效,下次新建立相同连接的时候就可以使用保存的参数来初始化这个连接.通常情况下是关闭的
net.ipv4.tcp_no_metrics_save=1
# unix socket 最大队列
net.unix.max_dgram_qlen=1024
# 路由缓存刷新频率
net.ipv4.route.gc_timeout=100

# Ref: https://gist.github.com/lixingcong/0e13b4123d29a465e364e230b2e45f60
# 启用 MTU 探测，在链路上存在 ICMP 黑洞时候有用（大多数情况是这样）
net.ipv4.tcp_mtu_probing = 1

# No Ref
# 开启并记录欺骗, 源路由和重定向包
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1
# 处理无源路由的包
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
# TCP KeepAlive 调优
# 最大闲置时间
net.ipv4.tcp_keepalive_time=300
# 最大失败次数, 超过此值后将通知应用层连接失效
net.ipv4.tcp_keepalive_probes=2
# 发送探测包的时间间隔
net.ipv4.tcp_keepalive_intvl=2
# 系统所能处理不属于任何进程的TCP sockets最大数量
net.ipv4.tcp_max_orphans=262144
# arp_table的缓存限制优化
net.ipv4.neigh.default.gc_thresh1=128
net.ipv4.neigh.default.gc_thresh2=512
net.ipv4.neigh.default.gc_thresh3=4096
net.ipv4.neigh.default.gc_stale_time=120
net.ipv4.conf.default.arp_announce=2
net.ipv4.conf.lo.arp_announce=2
net.ipv4.conf.all.arp_announce=2
# ------ END 网络调优: 其他 ------

# ------ 内核调优 ------

# Ref: Aliyun, etc
# 内核 Panic 后 1 秒自动重启
kernel.panic=1
# 允许更多的PIDs, 减少滚动翻转问题
kernel.pid_max=32768
# 内核所允许的最大共享内存段的大小（bytes）
kernel.shmmax=4294967296
# 在任何给定时刻, 系统上可以使用的共享内存的总量（pages）
kernel.shmall=1073741824
# 设定程序core时生成的文件名格式
kernel.core_pattern=core_%e
# 当发生oom时, 自动转换为panic
vm.panic_on_oom=1
# 表示强制Linux VM最低保留多少空闲内存（Kbytes）
# vm.min_free_kbytes=1048576
# 该值高于100, 则将导致内核倾向于回收directory和inode cache
vm.vfs_cache_pressure=250
# 表示系统进行交换行为的程度, 数值（0-100）越高, 越可能发生磁盘交换
vm.swappiness=10
# 仅用10%做为系统cache
vm.dirty_ratio=10
vm.overcommit_memory=1
# 增加系统文件描述符限制
# Fix error: too many open files
fs.file-max=1048575
fs.inotify.max_user_instances=8192
fs.inotify.max_user_instances=8192
# 内核响应魔术键
kernel.sysrq=1
# 弃用
# net.ipv4.tcp_low_latency=1

# Ref: https://gist.github.com/lixingcong/0e13b4123d29a465e364e230b2e45f60
# 当某个节点可用内存不足时, 系统会倾向于从其他节点分配内存. 对 Mongo/Redis 类 cache 服务器友好
vm.zone_reclaim_mode=0
EOF

# 应用新的内核参数
sysctl -p

echo "sysctl 配置已更新并生效。"

# 调整网络队列处理算法（Qdiscs），优化TCP重传次数
for interface in $interfaces; do
echo "Tuning network queue disciplines (Qdiscs) and TCP retransmission for interface $interface..."
tc qdisc add dev $interface root fq
tc qdisc change dev $interface root fq maxrate 90mbit
tc qdisc change dev $interface root fq burst 15k
tc qdisc add dev $interface ingress
tc filter add dev $interface parent ffff: protocol ip u32 match u32 0 0 action connmark action mirred egress redirect dev ifb0
tc qdisc add dev ifb0 root sfq perturb 10
ip link set dev ifb0 up
ethtool -K $interface tx off rx off
done

# 调整TCP和UDP流量的优先级
for interface in $interfaces; do
echo "Setting priority for TCP and UDP traffic on interface $interface..."
iptables -A OUTPUT -t mangle -p tcp -o $interface -j MARK --set-mark 10
iptables -A OUTPUT -t mangle -p udp -o $interface -j MARK --set-mark 20
iptables -A PREROUTING -t mangle -i $interface -j MARK --set-mark 10
iptables -A PREROUTING -t mangle -p udp -i $interface -j MARK --set-mark 20
done

# 设置文件描述符限制脚本
#!/bin/bash

# 获取内存大小（单位：MB）
total_memory=$(free -m | awk '/^Mem:/{print $2}')

# 计算文件描述符限制数值
if [[ $total_memory -eq 512 ]]; then
limit=4096
else
# 每增加512MB内存，文件描述符限制数值乘以2
multiplier=$((total_memory / 512))
limit=$((4096 * multiplier))
fi

# 设置文件描述符限制
echo "* hard nofile $limit" >> /etc/security/limits.conf
echo "* soft nofile $limit" >> /etc/security/limits.conf

echo "文件描述符限制已设置为 $limit"

# -----------------------------
# 完成提示
# -----------------------------
log "系统优化完成！请手动重启 VPS 生效新内核："
echo -e "\033[1;33mreboot\033[0m"
