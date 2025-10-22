#!/bin/bash
# ================================================
# VPS 硬盘空间清理脚本 (兼容 Debian 12 & Ubuntu 22.04)
# 作者: AI Assistant
# 版本: 1.0
# 功能: 安全清理系统垃圾文件，释放磁盘空间
# ================================================

set -euo pipefail

# 全局变量
SCRIPT_VERSION="1.0"
LOG_FILE="/var/log/disk_cleanup.log"
START_TIME=$(date +%s)
FREED_SPACE=0
CLEANED_COUNT=0

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
PROGRESS="[${PURPLE}⟳${NC}]"

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

    # 设置系统特定的命令和路径
    case "$DISTRO" in
        "debian")
            PACKAGE_MANAGER="apt-get"
            LOG_DIR="/var/log"
            CACHE_DIR="/var/cache/apt"
            ;;
        "ubuntu")
            PACKAGE_MANAGER="apt-get"
            LOG_DIR="/var/log"
            CACHE_DIR="/var/cache/apt"
            ;;
        *)
            log "ERROR" "不支持的系统: $DISTRO"
            exit 1
            ;;
    esac
}

# 日志函数
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 控制台输出
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
        "PROGRESS")
            echo -e "${PROGRESS} $message"
            ;;
    esac

    # 文件日志
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

# 检查权限
check_permissions() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "此脚本需要root权限运行"
        echo "请使用: sudo bash $0"
        exit 1
    fi
}

# 获取目录大小
get_dir_size() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        du -sb "$dir" 2>/dev/null | cut -f1 || echo "0"
    else
        echo "0"
    fi
}

# 格式化显示大小
format_size() {
    local size="$1"
    if [[ $size -gt 1073741824 ]]; then
        echo "$(($size / 1073741824)) GB"
    elif [[ $size -gt 1048576 ]]; then
        echo "$(($size / 1048576)) MB"
    elif [[ $size -gt 1024 ]]; then
        echo "$(($size / 1024)) KB"
    else
        echo "$size B"
    fi
}

# 显示磁盘使用情况
show_disk_usage() {
    log "INFO" "当前磁盘使用情况:"
    echo "─────────────────────────────────────────────────────"
    df -h | grep -E '^/dev/' | while read line; do
        local filesystem=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local used=$(echo "$line" | awk '{print $3}')
        local avail=$(echo "$line" | awk '{print $4}')
        local usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
        local mount=$(echo "$line" | awk '{print $6}')

        if [[ $usage -ge 90 ]]; then
            echo -e "${ERROR} $filesystem ($mount): ${usage}% 使用 (${used}/${size}) - 剩余: ${avail}"
        elif [[ $usage -ge 80 ]]; then
            echo -e "${WARNING} $filesystem ($mount): ${usage}% 使用 (${used}/${size}) - 剩余: ${avail}"
        else
            echo -e "${OK} $filesystem ($mount): ${usage}% 使用 (${used}/${size}) - 剩余: ${avail}"
        fi
    done
    echo "─────────────────────────────────────────────────────"
}

# 清理APT缓存
cleanup_apt_cache() {
    log "PROGRESS" "清理APT软件包缓存..."

    local old_size=$(get_dir_size "$CACHE_DIR")

    # 清理旧版本软件包
    if $PACKAGE_MANAGER autoremove -yqq 2>/dev/null; then
        log "INFO" "移除不需要的软件包"
    fi

    # 清理软件包缓存
    if $PACKAGE_MANAGER autoclean -yqq 2>/dev/null; then
        log "INFO" "清理软件包缓存"
    fi

    # 彻底清理缓存
    if $PACKAGE_MANAGER clean -yqq 2>/dev/null; then
        log "INFO" "彻底清理APT缓存"
    fi

    local new_size=$(get_dir_size "$CACHE_DIR")
    local freed=$((old_size - new_size))

    if [[ $freed -gt 0 ]]; then
        log "SUCCESS" "APT缓存清理完成，释放: $(format_size $freed)"
        FREED_SPACE=$((FREED_SPACE + freed))
        ((CLEANED_COUNT++))
    else
        log "INFO" "APT缓存已经是空的"
    fi
}

# 清理日志文件
cleanup_logs() {
    log "PROGRESS" "清理系统日志文件..."

    local old_size=$(get_dir_size "$LOG_DIR")

    # 清理旧的系统日志 (保留最近7天)
    find "$LOG_DIR" -name "*.log.*" -mtime +7 -delete 2>/dev/null || true
    find "$LOG_DIR" -name "*.log" -mtime +30 -size +100M -truncate -s 0 2>/dev/null || true
    find "$LOG_DIR" -name "*.gz" -mtime +7 -delete 2>/dev/null || true

    # 清理journal日志
    if command -v journalctl >/dev/null 2>&1; then
        # 保留最近7天的journal日志
        journalctl --vacuum-time=7d >/dev/null 2>&1 || true

        # 限制journal日志大小
        if [[ -f /etc/systemd/journald.conf ]]; then
            if ! grep -q "^SystemMaxUse" /etc/systemd/journald.conf; then
                echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf
                systemctl restart systemd-journald >/dev/null 2>&1 || true
                log "INFO" "设置journal日志大小限制为100M"
            fi
        fi
    fi

    # 清理特定应用的日志
    local app_logs=(
        "$LOG_DIR/nginx"
        "$LOG_DIR/apache2"
        "$LOG_DIR/mysql"
        "$LOG_DIR/postgresql"
        "$LOG_DIR/redis"
        "$LOG_DIR/docker"
    )

    for app_log in "${app_logs[@]}"; do
        if [[ -d "$app_log" ]]; then
            find "$app_log" -name "*.log.*" -mtime +7 -delete 2>/dev/null || true
            find "$app_log" -name "*.log" -size +50M -truncate -s 0 2>/dev/null || true
        fi
    done

    local new_size=$(get_dir_size "$LOG_DIR")
    local freed=$((old_size - new_size))

    if [[ $freed -gt 0 ]]; then
        log "SUCCESS" "日志文件清理完成，释放: $(format_size $freed)"
        FREED_SPACE=$((FREED_SPACE + freed))
        ((CLEANED_COUNT++))
    else
        log "INFO" "日志文件无需清理"
    fi
}

# 清理临时文件
cleanup_temp_files() {
    log "PROGRESS" "清理临时文件..."

    local temp_dirs=(
        "/tmp"
        "/var/tmp"
        "/var/run"
        "/usr/tmp"
    )

    local total_freed=0

    for temp_dir in "${temp_dirs[@]}"; do
        if [[ -d "$temp_dir" ]]; then
            local old_size=$(get_dir_size "$temp_dir")

            # 清理超过7天的临时文件
            find "$temp_dir" -type f -mtime +7 -delete 2>/dev/null || true

            # 清理空的临时目录
            find "$temp_dir" -type d -empty -delete 2>/dev/null || true

            local new_size=$(get_dir_size "$temp_dir")
            local freed=$((old_size - new_size))

            if [[ $freed -gt 0 ]]; then
                log "INFO" "$temp_dir 清理完成，释放: $(format_size $freed)"
                total_freed=$((total_freed + freed))
            fi
        fi
    done

    if [[ $total_freed -gt 0 ]]; then
        log "SUCCESS" "临时文件清理完成，释放: $(format_size $total_freed)"
        FREED_SPACE=$((FREED_SPACE + total_freed))
        ((CLEANED_COUNT++))
    else
        log "INFO" "临时文件无需清理"
    fi
}

# 清理用户缓存
cleanup_user_cache() {
    log "PROGRESS" "清理用户缓存文件..."

    local total_freed=0

    # 获取所有用户目录
    while IFS=':' read -r username password uid gid gecos home shell; do
        if [[ $uid -ge 1000 ]] && [[ -d "$home" ]]; then
            # 清理用户缓存目录
            local cache_dirs=(
                "$home/.cache"
                "$home/.thumbnails"
                "$home/.local/share/Trash/files"
                "$home/tmp"
            )

            for cache_dir in "${cache_dirs[@]}"; do
                if [[ -d "$cache_dir" ]]; then
                    local old_size=$(get_dir_size "$cache_dir")

                    # 清理超过30天的缓存文件
                    find "$cache_dir" -type f -mtime +30 -delete 2>/dev/null || true

                    # 清理大的缓存文件 (>100MB)
                    find "$cache_dir" -type f -size +100M -delete 2>/dev/null || true

                    local new_size=$(get_dir_size "$cache_dir")
                    local freed=$((old_size - new_size))

                    if [[ $freed -gt 0 ]]; then
                        log "INFO" "用户 $username 缓存清理，释放: $(format_size $freed)"
                        total_freed=$((total_freed + freed))
                    fi
                fi
            done
        fi
    done < /etc/passwd

    if [[ $total_freed -gt 0 ]]; then
        log "SUCCESS" "用户缓存清理完成，释放: $(format_size $total_freed)"
        FREED_SPACE=$((FREED_SPACE + total_freed))
        ((CLEANED_COUNT++))
    else
        log "INFO" "用户缓存无需清理"
    fi
}

# 清理Docker相关文件
cleanup_docker() {
    if command -v docker >/dev/null 2>&1; then
        log "PROGRESS" "清理Docker相关文件..."

        local old_size=0

        # 计算Docker占用的空间
        if docker system df --format "{{.Size}}" 2>/dev/null | grep -v "0B" >/dev/null; then
            old_size=$(docker system df --format "{{.Size}}" 2>/dev/null | \
                awk '{if ($1 ~ /GB$/) print $1*1024*1024*1024; else if ($1 ~ /MB$/) print $1*1024*1024; else if ($1 ~ /KB$/) print $1*1024; else print $1}' | \
                awk '{sum+=$1} END {print sum+0}')
        fi

        # 清理Docker系统
        if docker system prune -af --volumes >/dev/null 2>&1; then
            log "INFO" "清理Docker未使用的容器、网络、镜像和卷"
        fi

        # 计算清理后的空间
        local new_size=0
        if docker system df --format "{{.Size}}" 2>/dev/null | grep -v "0B" >/dev/null; then
            new_size=$(docker system df --format "{{.Size}}" 2>/dev/null | \
                awk '{if ($1 ~ /GB$/) print $1*1024*1024*1024; else if ($1 ~ /MB$/) print $1*1024*1024; else if ($1 ~ /KB$/) print $1*1024; else print $1}' | \
                awk '{sum+=$1} END {print sum+0}')
        fi

        local freed=$((old_size - new_size))

        if [[ $freed -gt 0 ]]; then
            log "SUCCESS" "Docker清理完成，释放: $(format_size $freed)"
            FREED_SPACE=$((FREED_SPACE + freed))
            ((CLEANED_COUNT++))
        else
            log "INFO" "Docker无需清理"
        fi
    else
        log "INFO" "Docker未安装，跳过"
    fi
}

# 清理Snap包
cleanup_snaps() {
    if command -v snap >/dev/null 2>&1; then
        log "PROGRESS" "清理Snap包..."

        local old_size=0
        if [[ -d /var/lib/snapd/cache ]]; then
            old_size=$(get_dir_size "/var/lib/snapd/cache")
        fi

        # 移除旧版本的Snap包
        if snap list --all | awk '/disabled/{print $1, $3}' | \
            while read snapname revision; do
                snap remove "$snapname" --revision="$revision" >/dev/null 2>&1 || true
            done 2>/dev/null; then
            log "INFO" "移除旧版本的Snap包"
        fi

        local new_size=0
        if [[ -d /var/lib/snapd/cache ]]; then
            new_size=$(get_dir_size "/var/lib/snapd/cache")
        fi

        local freed=$((old_size - new_size))

        if [[ $freed -gt 0 ]]; then
            log "SUCCESS" "Snap清理完成，释放: $(format_size $freed)"
            FREED_SPACE=$((FREED_SPACE + freed))
            ((CLEANED_COUNT++))
        else
            log "INFO" "Snap无需清理"
        fi
    else
        log "INFO" "Snap未安装，跳过"
    fi
}

# 清理内核文件
cleanup_kernels() {
    log "PROGRESS" "检查旧内核文件..."

    # 获取当前运行的内核版本
    local current_kernel=$(uname -r)
    log "INFO" "当前内核版本: $current_kernel"

    # 列出已安装但未使用的内核
    local old_kernels=()

    # Debian/Ubuntu系统
    if [[ -d /boot ]]; then
        for kernel_file in /boot/vmlinuz-*; do
            if [[ -f "$kernel_file" ]]; then
                local kernel_version=$(basename "$kernel_file" | sed 's/vmlinuz-//')
                if [[ "$kernel_version" != "$current_kernel" ]]; then
                    old_kernels+=("$kernel_version")
                fi
            fi
        done
    fi

    if [[ ${#old_kernels[@]} -gt 0 ]]; then
        log "INFO" "发现 ${#old_kernels[@]} 个旧内核版本"

        # 提示用户确认
        echo -e "${WARNING}发现以下旧内核:${NC}"
        for kernel in "${old_kernels[@]}"; do
            echo "  - $kernel"
        done

        read -p "是否删除这些旧内核？(y/N): " remove_kernels
        if [[ "$remove_kernels" =~ ^[Yy]$ ]]; then
            local old_size=0

            # 计算旧内核占用的空间
            for kernel in "${old_kernels[@]}"; do
                for kernel_file in /boot/*"$kernel"*; do
                    if [[ -f "$kernel_file" ]]; then
                        old_size=$((old_size + $(get_dir_size "$kernel_file")))
                    fi
                done
            done

            # 使用包管理器移除旧内核
            local kernel_packages=()
            for kernel in "${old_kernels[@]}"; do
                # 构建包名
                local package_name="linux-image-${kernel}"
                if dpkg -l | grep -q "$package_name"; then
                    kernel_packages+=("$package_name")
                fi

                package_name="linux-headers-${kernel}"
                if dpkg -l | grep -q "$package_name"; then
                    kernel_packages+=("$package_name")
                fi

                package_name="linux-modules-${kernel}"
                if dpkg -l | grep -q "$package_name"; then
                    kernel_packages+=("$package_name")
                fi
            done

            if [[ ${#kernel_packages[@]} -gt 0 ]]; then
                if $PACKAGE_MANAGER remove -y "${kernel_packages[@]}" >/dev/null 2>&1; then
                    log "SUCCESS" "旧内核清理完成，释放: $(format_size $old_size)"
                    FREED_SPACE=$((FREED_SPACE + old_size))
                    ((CLEANED_COUNT++))
                else
                    log "WARN" "旧内核清理失败，请手动处理"
                fi
            fi
        else
            log "INFO" "跳过旧内核清理"
        fi
    else
        log "INFO" "没有发现旧内核文件"
    fi
}

# 清理回收站
cleanup_trash() {
    log "PROGRESS" "清理回收站..."

    local total_freed=0

    # 系统回收站
    if [[ -d /tmp/.trash ]]; then
        local old_size=$(get_dir_size "/tmp/.trash")
        rm -rf /tmp/.trash/* 2>/dev/null || true
        local new_size=$(get_dir_size "/tmp/.trash")
        local freed=$((old_size - new_size))
        total_freed=$((total_freed + freed))
    fi

    # 用户回收站
    while IFS=':' read -r username password uid gid gecos home shell; do
        if [[ $uid -ge 1000 ]] && [[ -d "$home" ]]; then
            local trash_dirs=(
                "$home/.local/share/Trash/files"
                "$home/.Trash"
            )

            for trash_dir in "${trash_dirs[@]}"; do
                if [[ -d "$trash_dir" ]]; then
                    local old_size=$(get_dir_size "$trash_dir")
                    rm -rf "$trash_dir"/* 2>/dev/null || true
                    local new_size=$(get_dir_size "$trash_dir")
                    local freed=$((old_size - new_size))
                    total_freed=$((total_freed + freed))
                fi
            done
        fi
    done < /etc/passwd

    if [[ $total_freed -gt 0 ]]; then
        log "SUCCESS" "回收站清理完成，释放: $(format_size $total_freed)"
        FREED_SPACE=$((FREED_SPACE + freed))
        ((CLEANED_COUNT++))
    else
        log "INFO" "回收站无需清理"
    fi
}

# 显示清理摘要
show_cleanup_summary() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))

    echo
    echo -e "${WHITE}========================================${NC}"
    echo -e "${WHITE}         磁盘清理完成摘要${NC}"
    echo -e "${WHITE}========================================${NC}"
    echo -e "  ${GREEN}✓${NC} 清理项目数: $CLEANED_COUNT"
    echo -e "  ${GREEN}✓${NC} 释放空间: $(format_size $FREED_SPACE)"
    echo -e "  ${GREEN}✓${NC} 耗时: ${duration} 秒"
    echo -e "  ${GREEN}✓${NC} 日志文件: $LOG_FILE"
    echo

    # 显示清理后的磁盘使用情况
    log "INFO" "清理后磁盘使用情况:"
    show_disk_usage

    if [[ $FREED_SPACE -gt 0 ]]; then
        echo -e "${GREEN}🎉 恭喜！成功释放 $(format_size $FREED_SPACE) 磁盘空间${NC}"
    else
        echo -e "${YELLOW}ℹ️  系统已经很干净，没有释放额外空间${NC}"
    fi
}

# 主函数
main() {
    echo -e "${WHITE}========================================${NC}"
    echo -e "${WHITE}    VPS 硬盘空间清理工具 v$SCRIPT_VERSION${NC}"
    echo -e "${WHITE}    兼容 Debian 12 & Ubuntu 22.04${NC}"
    echo -e "${WHITE}========================================${NC}"
    echo

    # 检查权限
    check_permissions

    # 系统检测
    detect_system

    # 显示当前磁盘使用情况
    show_disk_usage

    echo
    log "INFO" "开始清理操作..."

    # 执行清理操作
    cleanup_apt_cache
    cleanup_logs
    cleanup_temp_files
    cleanup_user_cache
    cleanup_docker
    cleanup_snaps
    cleanup_kernels
    cleanup_trash

    # 显示清理摘要
    show_cleanup_summary

    echo -e "${GREEN}✓ 磁盘清理完成！${NC}"
}

# 运行主程序
main "$@"