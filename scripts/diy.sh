#!/bin/bash
# =============================================================================
# OpenWrt 定制脚本：用于修改默认设置、清理官方源、并克隆第三方软件包
# 
# 使用方法:
#   ./scripts/diy.sh <branch_name> <soc_name>
# =============================================================================

# 启用严格模式：遇到错误立即退出，未定义的变量视为错误，管道中任一命令失败则整个管道失败
set -euo pipefail

# --- 图标定义 ---
readonly ICON_SUCCESS="✅"         # 成功图标
readonly ICON_ERROR="❌"           # 错误图标
readonly ICON_WARNING="⚠️"         # 警告图标
readonly ICON_INFO="ℹ️"            # 信息图标
readonly ICON_START="🚀"           # 开始图标
readonly ICON_END="🏁"             # 结束图标
readonly ICON_PROGRESS="⏳"        # 进行中图标
readonly ICON_DEBUG="🔍"           # 调试图标
readonly ICON_CONFIG="⚙️"          # 配置图标
readonly ICON_PACKAGE="📦"         # 软件包图标
readonly ICON_CACHE="💾"           # 缓存图标
readonly ICON_BUILD="🔨"           # 构建图标
readonly ICON_CLEAN="🧹"           # 清理图标

# --- 日志函数 ---
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

# --- 错误处理函数 ---
# 当脚本出错时，记录错误信息并退出
error_handler() {
    local line_number=$1
    log_error "脚本在第 ${line_number} 行发生错误！"
    log_error "请检查上方的日志输出以获取详细信息。"
    exit 1
}

# 设置错误陷阱，任何命令返回非零状态码时都会触发
trap 'error_handler $LINENO' ERR

# --- 主逻辑 ---
main() {
    # 接收从 workflow 传入的参数
    local branch_name="${1:-openwrt}"
    local soc_name="${2:-ipq60xx}"

    # 创建日志目录
    mkdir -p logs
    
    # 将所有输出同时打印到控制台和日志文件
    local log_file="logs/diy-${branch_name}-${soc_name}.log"
    exec > >(tee -a "$log_file")
    exec 2> >(tee -a "$log_file" >&2)

    log_info "=========================================="
    log_info " DIY Script for OpenWrt"
    log_info " Branch: ${branch_name}"
    log_info " SoC:     ${soc_name}"
    log_info "=========================================="

    # 步骤 1: 修改默认IP & 固件名称 & 编译署名
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

# --- 功能函数 ---

# 修改默认设置
modify_default_settings() {
    log_info "  - 修改默认IP为 192.168.111.1"
    sed -i 's/192.168.1.1/192.168.111.1/g' package/base-files/files/bin/config_generate
    
    log_info "  - 修改主机名为 'WRT'"
    sed -i "s/hostname='.*'/hostname='WRT'/g" package/base-files/files/bin/config_generate
    
    log_info "  - 添加编译署名 'Built by Mary'"
    # 检查文件是否存在，避免在某些分支中报错
    if [ -f "feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js" ]; then
        sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ Built by Mary')/g" feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js
    else
        log_warning "  - Luci状态文件未找到，跳过添加编译署名。"
    fi

    log_info "  - 设置默认WiFi SSID和密码"
    if [ -f "package/kernel/mac80211/files/lib/wifi/mac80211.sh" ]; then
        sed -i 's/ssid=OpenWrt/ssid=WRT/g' package/kernel/mac80211/files/lib/wifi/mac80211.sh
        sed -i 's/key=1/key=12345678/g' package/kernel/mac80211/files/lib/wifi/mac80211.sh
    fi
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
            log_info "  - 已删除缓存包: $package"
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
            log_info "  - 已删除工作目录包: $package"
        fi
    done
}

# 克隆定制软件包
clone_custom_packages() {
    # 使用一个函数来处理克隆，增加重试和错误处理
    clone_repo() {
        local url="$1"
        local dest="$2"
        local name="$3"
        log_info "  - 克隆 $name 到 $dest..."
        
        # 如果目标目录已存在，先删除
        if [ -d "$dest" ]; then
            log_info "    - 目录 $dest 已存在，先删除"
            rm -rf "$dest"
        fi
        
        # 克隆仓库
        if git clone --depth=1 "$url" "$dest"; then
            log_success "    - $name 克隆成功"
            
            # 验证是否包含 Makefile（OpenWrt 软件包的标志）
            if [ -f "$dest/Makefile" ]; then
                log_info "    - 找到 Makefile，是有效的 OpenWrt 软件包"
            else
                log_warning "    - 警告：未找到 Makefile，可能不是标准的 OpenWrt 软件包"
            fi
        else
            log_error "    - $name 克隆失败！"
            return 1
        fi
    }

    log_info "开始克隆第三方软件包..."
    
    # laipeng668定制包
    clone_repo "https://github.com/sbwml/packages_lang_golang" "feeds/packages/lang/golang" "Golang"
    clone_repo "https://github.com/sbwml/luci-app-openlist2" "package/openlist" "luci-app-openlist2"
    clone_repo "https://github.com/laipeng668/packages.git" "feeds/packages/net/ariang" "AriaNg (feeds)"
    clone_repo "https://github.com/laipeng668/packages.git" "feeds/packages/net/frp" "FRP (feeds)"
    clone_repo "https://github.com/laipeng668/luci.git" "feeds/luci/applications/luci-app-frpc" "luci-app-frpc"
    clone_repo "https://github.com/laipeng668/luci.git" "feeds/luci/applications/luci-app-frps" "luci-app-frps"
    clone_repo "https://github.com/kenzok8/openwrt-packages.git" "package/adguardhome" "AdGuardHome (package)"
    clone_repo "https://github.com/kenzok8/openwrt-packages.git" "package/luci-app-adguardhome" "luci-app-adguardhome (package)"
    clone_repo "https://github.com/VIKINGYFY/packages.git" "feeds/luci/applications/luci-app-wolplus" "luci-app-wolplus"
    clone_repo "https://github.com/tty228/luci-app-wechatpush.git" "package/luci-app-wechatpush" "luci-app-wechatpush"
    clone_repo "https://github.com/destan19/OpenAppFilter.git" "package/OpenAppFilter" "OpenAppFilter"
    clone_repo "https://github.com/lwb1978/openwrt-gecoosac.git" "package/openwrt-gecoosac" "gecoosac"
    clone_repo "https://github.com/NONGFAH/luci-app-athena-led.git" "package/luci-app-athena-led" "luci-app-athena-led"
    
    # Mary定制包
    clone_repo "https://github.com/sirpdboy/luci-app-netspeedtest.git" "package/netspeedtest" "luci-app-netspeedtest"
    clone_repo "https://github.com/sirpdboy/luci-app-partexp.git" "package/partexp" "luci-app-partexp"
    clone_repo "https://github.com/sirpdboy/luci-app-taskplan.git" "package/taskplan" "luci-app-taskplan"
    clone_repo "https://github.com/tailscale/tailscale.git" "package/tailscale" "Tailscale"
    clone_repo "https://github.com/nikkinikki-org/OpenWrt-momo.git" "package/momo" "Momo"
    clone_repo "https://github.com/nikkinikki-org/OpenWrt-nikki.git" "package/nikki" "Nikki"
    clone_repo "https://github.com/vernesong/OpenClash.git" "package/openclash" "OpenClash"
    clone_repo "https://github.com/VIKINGYFY/packages.git" "package/wolplus" "luci-app-wolplus"  # WolPlus 的处理

    # kenzok8软件源（该软件源仅作为查漏补缺，优先级最低）
    clone_repo "https://github.com/kenzok8/small-package" "smpackage" "kenzok8 small-package"
    
    # 设置特定脚本权限
    if [ -f "package/luci-app-athena-led/root/etc/init.d/athena_led" ]; then
        chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led
        chmod +x package/luci-app-athena-led/root/usr/sbin/athena-led
        log_info "  - 已设置 athena-led 脚本执行权限"
    fi
    
    log_success "所有第三方软件包克隆完成"
}

# --- 执行主函数 ---
# 将所有参数传递给主函数
main "$@"
