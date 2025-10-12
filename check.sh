#!/bin/bash
# =============================
# VPS 优化检查脚本
# =============================

echo "============================="
echo "[+] 检查 sysctl 内核参数"
echo "============================="
declare -a sysctl_params=(
"net.ipv4.tcp_timestamps"
"net.ipv4.tcp_rmem"
"net.ipv4.tcp_wmem"
"net.core.default_qdisc"
"net.ipv4.tcp_congestion_control"
"net.core.netdev_max_backlog"
"net.core.somaxconn"
"net.ipv4.tcp_max_syn_backlog"
"net.ipv4.tcp_tw_reuse"
"net.ipv4.tcp_max_tw_buckets"
)

for param in "${sysctl_params[@]}"; do
    value=$(sysctl -n $param 2>/dev/null)
    if [[ $? -eq 0 ]]; then
        echo "$param = $value"
    else
        echo "$param = 未启用或不可用"
    fi
done

echo
echo "============================="
echo "[+] 检查文件描述符限制"
echo "============================="
ulimit_value=$(ulimit -n)
echo "当前 shell 最大文件描述符限制: $ulimit_value"

echo "查看 /etc/security/limits.conf 中设置:"
grep -E "nofile" /etc/security/limits.conf

echo
echo "============================="
echo "[+] 检查 iptables 流量标记 (mangle 表)"
echo "============================="
iptables -t mangle -L -v -n | grep -E "MARK|Chain"

echo
echo "============================="
echo "[+] 检查 TCP 拥塞控制算法和队列调度器"
echo "============================="
cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
echo "TCP 拥塞控制算法: ${cc:-未启用}"
echo "默认队列调度器: ${qdisc:-未启用}"

echo
echo "============================="
echo "[+] 检查当前 TCP 连接状态统计"
echo "============================="
ss -s

echo
echo "[+] 检查完成。请确认各项值与优化脚本配置一致。"
