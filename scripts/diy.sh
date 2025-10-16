#!/bin/bash
# scripts/diy.sh
# OpenWrt 定制脚本

# 启用严格模式
set -euo pipefail

# 图标定义
readonly ICON_SUCCESS="✅"
readonly ICON_ERROR="❌"
readonly ICON_WARNING="⚠️"
readonly ICON_INFO="ℹ️"
readonly ICON_START="🚀"
readonly ICON_END="🏁"
readonly ICON_PROGRESS="⏳"
readonly ICON_DEBUG="🔍"
readonly ICON_CONFIG="⚙️"
readonly ICON_PACKAGE="📦"
readonly ICON_CACHE="💾"
readonly ICON_BUILD="🔨"
readonly ICON_CLEAN="🧹"

# 日志函数
log_info() {
    echo -e "${ICON_INFO} $1"
}

log_success() {
    echo -e "${ICON_SUCCESS} $1"
}

log_error() {
    echo -e "${ICON_ERROR} $1" >&2
}

log_warning() {
    echo -e "${ICON_WARNING} $1"
}

log_progress() {
    echo -e "${ICON_PROGRESS} $1"
}

# 错误处理函数
error_handler() {
    local line_number=$1
    log_error "脚本在第 $line_number 行发生错误！"
    
    # 记录错误前的1000行日志
    echo "=== 错误日志 ===" >> error.log
    tail -n 1000 build.log >> error.log 2>&1 || true
    
    exit 1
}

# 设置错误陷阱
trap 'error_handler $LINENO' ERR

# 主函数
main() {
    # 接收参数
    local branch_name="${1:-openwrt}"
    local soc_name="${2:-ipq60xx}"
    
    # 创建日志文件
    exec 1> >(tee -a build.log)
    exec 2> >(tee -a build.log >&2)
    
    log_info "=========================================="
    log_info " DIY Script for OpenWrt"
    log_info " Branch: ${branch_name}"
    log_info " SoC:     ${soc_name}"
    log_info "=========================================="
    
    # 步骤 1: 修改默认设置
    log_progress "==> Step 1: Modifying default settings..."
    modify_default_settings
    log_success "✅ Default settings modified."
    
    # 步骤 2: 预删除官方软件源缓存
    log_progress "==> Step 2: Pre-deleting official package caches..."
    delete_official_caches
    log_success "✅ Official caches deleted."
    
    # 步骤 3: 预删除feeds工作目录
    log_progress "==> Step 3: Pre-deleting feeds working directories..."
    delete_feeds_work_dirs
    log_success "✅ Feeds work directories deleted."
    
    # 步骤 4: 克隆定制化软件包
    log_progress "==> Step 4: Cloning custom packages..."
    clone_custom_packages
    log_success "✅ Custom packages cloned."
    
    log_info "==> DIY script finished successfully."
}

# 修改默认设置
modify_default_settings() {
    # 修改默认IP
    sed -i 's/192.168.1.1/192.168.111.1/g' package/base-files/files/bin/config_generate
    
    # 修改主机名
    sed -i "s/hostname='.*'/hostname='WRT'/g" package/base-files/files/bin/config_generate
    
    # 添加编译署名
    sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ Built by Mary')/g" feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js
    
    # 设置默认WiFi密码
    sed -i 's/ssid=OpenWrt/ssid=WRT/g' package/kernel/mac80211/files/lib/wifi/mac80211.sh
    sed -i 's/key=12345678/key=12345678/g' package/kernel/mac80211/files/lib/wifi/mac80211.sh
}

# 删除官方缓存包
delete_official_caches() {
    local packages=(
        "package/feeds/packages/golang"
        "package/feeds/packages/ariang"
        "package/feeds/packages/frp"
        "package/feeds/packages/adguardhome"
        "package/feeds/packages/wolplus"
        "package/feeds/packages/lucky"
        "package/feeds/packages/wechatpush"
        "package/feeds/packages/open-app-filter"
        "package/feeds/packages/gecoosac"
        "package/feeds/luci/luci-app-frpc"
        "package/feeds/luci/luci-app-frps"
        "package/feeds/luci/luci-app-adguardhome"
        "package/feeds/luci/luci-app-wolplus"
        "package/feeds/luci/luci-app-lucky"
        "package/feeds/luci/luci-app-wechatpush"
        "package/feeds/luci/luci-app-athena-led"
        "package/feeds/packages/netspeedtest"
        "package/feeds/packages/partexp"
        "package/feeds/packages/taskplan"
        "package/feeds/packages/tailscale"
        "package/feeds/packages/momo"
        "package/feeds/packages/nikki"
        "package/feeds/luci/luci-app-netspeedtest"
        "package/feeds/luci/luci-app-partexp"
        "package/feeds/luci/luci-app-taskplan"
        "package/feeds/luci/luci-app-tailscale"
        "package/feeds/luci/luci-app-momo"
        "package/feeds/luci/luci-app-nikki"
        "package/feeds/luci/luci-app-openclash"
    )
    
    for package in "${packages[@]}"; do
        if [ -d "$package" ]; then
            rm -rf "$package"
            log_info "已删除缓存包: $package"
        fi
    done
}

# 删除feeds工作目录
delete_feeds_work_dirs() {
    local packages=(
        "feeds/packages/lang/golang"
        "feeds/packages/net/ariang"
        "feeds/packages/net/frp"
        "feeds/packages/net/adguardhome"
        "feeds/packages/net/wolplus"
        "feeds/packages/net/lucky"
        "feeds/packages/net/wechatpush"
        "feeds/packages/net/open-app-filter"
        "feeds/packages/net/gecoosac"
        "feeds/luci/applications/luci-app-frpc"
        "feeds/luci/applications/luci-app-frps"
        "feeds/luci/applications/luci-app-adguardhome"
        "feeds/luci/applications/luci-app-wolplus"
        "feeds/luci/applications/luci-app-lucky"
        "feeds/luci/applications/luci-app-wechatpush"
        "feeds/luci/applications/luci-app-athena-led"
        "feeds/packages/net/netspeedtest"
        "feeds/packages/utils/partexp"
        "feeds/packages/utils/taskplan"
        "feeds/packages/net/tailscale"
        "feeds/packages/net/momo"
        "feeds/packages/net/nikki"
        "feeds/luci/applications/luci-app-netspeedtest"
        "feeds/luci/applications/luci-app-partexp"
        "feeds/luci/applications/luci-app-taskplan"
        "feeds/luci/applications/luci-app-tailscale"
        "feeds/luci/applications/luci-app-momo"
        "feeds/luci/applications/luci-app-nikki"
        "feeds/luci/applications/luci-app-openclash"
    )
    
    for package in "${packages[@]}"; do
        if [ -d "$package" ]; then
            rm -rf "$package"
            log_info "已删除工作目录包: $package"
        fi
    done
}

# 克隆定制软件包
clone_custom_packages() {
    # laipeng668定制包
    git clone --depth=1 https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang || log_warning "Failed to clone golang"
    git clone --depth=1 https://github.com/sbwml/luci-app-openlist2 package/openlist || log_warning "Failed to clone openlist2"
    git clone --depth=1 https://github.com/laipeng668/packages.git feeds/packages/net/ariang || log_warning "Failed to clone ariang"
    git clone --depth=1 https://github.com/laipeng668/packages.git feeds/packages/net/frp || log_warning "Failed to clone frp"
    git clone --depth=1 https://github.com/laipeng668/luci.git feeds/luci/applications/luci-app-frpc || log_warning "Failed to clone luci-app-frpc"
    git clone --depth=1 https://github.com/laipeng668/luci.git feeds/luci/applications/luci-app-frps || log_warning "Failed to clone luci-app-frps"
    git clone --depth=1 https://github.com/kenzok8/openwrt-packages.git package/adguardhome || log_warning "Failed to clone adguardhome"
    git clone --depth=1 https://github.com/kenzok8/openwrt-packages.git package/luci-app-adguardhome || log_warning "Failed to clone luci-app-adguardhome"
    git clone --depth=1 https://github.com/VIKINGYFY/packages.git feeds/luci/applications/luci-app-wolplus || log_warning "Failed to clone wolplus"
    git clone --depth=1 https://github.com/tty228/luci-app-wechatpush.git package/luci-app-wechatpush || log_warning "Failed to clone wechatpush"
    git clone --depth=1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter || log_warning "Failed to clone OpenAppFilter"
    git clone --depth=1 https://github.com/lwb1978/openwrt-gecoosac.git package/openwrt-gecoosac || log_warning "Failed to clone gecoosac"
    git clone --depth
