echo "请选择要安装的 XanMod 内核类型:"
select KERNEL_TYPE in "main" "edge"; do
    [[ "$KERNEL_TYPE" =~ ^(main|edge)$ ]] && XANMOD_KERNEL_TYPE=$KERNEL_TYPE && break
    echo "无效选择，请输入 1 或 2."
done

echo
read -p "是否继续执行优化脚本？(Y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Nn]$ ]] && exit 0

# -----------------------------
# XanMod 内核自动检测与安装
# -----------------------------
log "检测 CPU 架构并安装 XanMod 内核..."
ABI=$(awk -f <(wget -qO- https://dl.xanmod.org/check_x86-64_psabi.sh))
echo "检测到 ABI: ${ABI}"

wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor | tee /usr/share/keyrings/xanmod-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" \
    | tee /etc/apt/sources.list.d/xanmod-kernel.list >/dev/null
apt-get update -y

if [[ "$ABI" =~ "x86-64-v1" ]]; then
    PKG="linux-xanmod-x64v1"
    if [[ "$KERNEL_TYPE" == "edge" ]]; then
        echo "Edge 内核不支持 v1，自动切换为 main。"
    fi
elif [[ "$ABI" =~ "x86-64-v2" ]]; then
    PKG="linux-xanmod-${KERNEL_TYPE}-x64v2"
elif [[ "$ABI" =~ "x86-64-v3" ]]; then
    PKG="linux-xanmod-${KERNEL_TYPE}-x64v3"
else
    PKG="linux-xanmod-${KERNEL_TYPE}-x64v3"
fi

apt-get install -y "${PKG}"

# -----------------------------
# 完成提示
# -----------------------------
log "系统优化完成！请手动重启 VPS 生效新内核："
echo -e "\033[1;33mreboot\033[0m"