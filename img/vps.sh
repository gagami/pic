# ==============================
# XanMod 内核选择 + 安装模块
# ==============================

echo "请选择要安装的 XanMod 内核类型:"
select KERNEL_TYPE in "main" "edge"; do
    case "$KERNEL_TYPE" in
        main|edge)
            XANMOD_KERNEL_TYPE=$KERNEL_TYPE
            break
            ;;
        *)
            echo "无效选择，请输入 1 或 2."
            ;;
    esac
done

echo
read -p "是否继续执行优化脚本？(Y/n): " CONFIRM
[[ "$CONFIRM" =~ ^[Nn]$ ]] && { echo "用户取消执行。"; exit 0; }

# ==============================
# 自动检测 ABI 并安装 XanMod 内核
# ==============================
log "检测 CPU 架构并安装 XanMod ${XANMOD_KERNEL_TYPE^^} 内核..."

# 确保 wget 存在
if ! command -v wget &>/dev/null; then
    apt-get install -y wget
fi

# 检测 ABI（安全执行）
ABI=$(bash -c "$(wget -qO- https://dl.xanmod.org/check_x86-64_psabi.sh 2>/dev/null)" || echo "x86-64-v2")
echo "检测到 ABI 架构: $ABI"

# 导入签名密钥与源
wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor | tee /usr/share/keyrings/xanmod-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" \
    | tee /etc/apt/sources.list.d/xanmod-kernel.list >/dev/null

apt-get update -y

# 根据 ABI 自动选择合适内核包
case "$ABI" in
    *x86-64-v1*)
        PKG="linux-xanmod-x64v1"
        if [[ "$XANMOD_KERNEL_TYPE" == "edge" ]]; then
            echo -e "\033[33m[警告]\033[0m v1 架构不支持 Edge 内核，自动切换为 main。"
            XANMOD_KERNEL_TYPE="main"
        fi
        ;;
    *x86-64-v2*)
        PKG="linux-xanmod-${XANMOD_KERNEL_TYPE}-x64v2"
        ;;
    *x86-64-v3*)
        PKG="linux-xanmod-${XANMOD_KERNEL_TYPE}-x64v3"
        ;;
    *x86-64-v4*)
        PKG="linux-xanmod-${XANMOD_KERNEL_TYPE}-x64v4"
        ;;
    *)
        echo -e "\033[33m[警告]\033[0m 未能识别 ABI，默认使用 v3 内核。"
        PKG="linux-xanmod-${XANMOD_KERNEL_TYPE}-x64v3"
        ;;
esac

# 检查包是否存在
if ! apt-cache show "$PKG" >/dev/null 2>&1; then
    echo -e "\033[31m[错误]\033[0m 找不到对应的 XanMod 包 ($PKG)。"
    echo "请检查网络或更换为 main 版本再试。"
    exit 1
fi

# 开始安装内核
log "正在安装: ${PKG}"
apt-get install -y "$PKG"

# 更新引导
if command -v update-grub >/dev/null 2>&1; then
    update-grub
else
    grub-mkconfig -o /boot/grub/grub.cfg
fi

log "✅ XanMod 内核 (${PKG}) 安装完成。"

# ==============================
# 提示重启
# ==============================
log "系统优化与内核安装已完成。"
echo -e "\033[1;33m请执行以下命令重启 VPS 以生效新内核：\033[0m"
echo -e "\033[1;36mreboot\033[0m"
