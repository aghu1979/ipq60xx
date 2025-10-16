#!/bin/bash
# 企业级工具函数库
# 功能：提供通用工具函数

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查文件是否存在
file_exists() {
    [[ -f "$1" ]]
}

# 检查目录是否存在
dir_exists() {
    [[ -d "$1" ]]
}

# 获取文件大小
get_file_size() {
    if [[ -f "$1" ]]; then
        stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# 格式化文件大小
format_size() {
    local size=$1
    if [[ $size -gt 1073741824 ]]; then
        echo "$(( size / 1073741824 ))GB"
    elif [[ $size -gt 1048576 ]]; then
        echo "$(( size / 1048576 ))MB"
    elif [[ $size -gt 1024 ]]; then
        echo "$(( size / 1024 ))KB"
    else
        echo "${size}B"
    fi
}

# 生成随机字符串
random_string() {
    local length=${1:-16}
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
}

# 检查网络连接
check_network() {
    if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 获取CPU核心数
get_cpu_cores() {
    nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "1"
}

# 获取内存大小
get_memory_size() {
    local mem_size
    if [[ -f /proc/meminfo ]]; then
        mem_size=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        echo $(( mem_size / 1024 ))
    else
        echo "0"
    fi
}

# 清理临时文件
cleanup() {
    log_info "🧹 清理临时文件..."
    rm -rf /tmp/openwrt-*
    log_success "✅ 清理完成"
}

# 设置清理陷阱
trap cleanup EXIT
