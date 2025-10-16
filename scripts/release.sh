#!/bin/bash
# 企业级发布脚本
# 功能：准备发布内容，生成Release说明

set -euo pipefail

# 导入工具函数
source "$(dirname "$0")/utils.sh"
source "$(dirname "$0")/logger.sh"

# 全局变量
RELEASE_DIR="${BASE_DIR}/release"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d)}"

# 主函数
main() {
    local command="${1:-}"
    
    case "$command" in
        prepare-release)
            prepare_release
            ;;
        *)
            log_error "未知命令: $command"
            exit 1
            ;;
    esac
}

# 准备发布
prepare_release() {
    log_info "🚀 准备发布内容..."
    
    # 创建发布目录
    mkdir -p "$RELEASE_DIR"
    
    # 合并所有产出物
    for artifact in artifacts/firmware-*; do
        if [[ -d "$artifact" ]]; then
            cp -r "$artifact"/* "$RELEASE_DIR/"
        fi
    done
    
    # 生成Release说明
    generate_release_notes
    
    log_success "✅ 发布内容准备完成"
}

# 生成Release说明
generate_release_notes() {
    log_info "📝 生成Release说明..."
    
    local release_notes="${BASE_DIR}/release-notes.md"
    local kernel_version=""
    local luci_apps=""
    
    # 获取内核版本
    if [[ -f "${RELEASE_DIR}/config.buildinfo" ]]; then
        kernel_version=$(grep "CONFIG_KERNEL" "${RELEASE_DIR}/config.buildinfo" | head -n1 | cut -d'=' -f2)
    fi
    
    # 获取Luci应用列表
    if [[ -f "${LOG_DIR}/luci-apps-merged.log" ]]; then
        luci_apps=$(sed 's/CONFIG_PACKAGE_//g; s/=y//g' "${LOG_DIR}/luci-apps-merged.log" | tr '\n' ', ' | sed 's/,$//')
    fi
    
    # 生成Release内容
    cat > "$release_notes" <<EOF
# OpenWrt 固件发布 - ${TIMESTAMP}

## 📋 基本信息
- **默认管理地址**: 192.168.111.1
- **默认用户**: root
- **默认密码**: none
- **默认WIFI密码**: 12345678

## 🔧 固件信息
- **支持分支**: OpenWrt, ImmortalWrt, LibWrt
- **支持芯片**: IPQ60xx
- **配置级别**: Pro, Max, Ultra
- **内核版本**: ${kernel_version}

## 📦 包含的Luci应用
 ${luci_apps}

## 📥 下载说明
- 固件命名规则: \`分支-芯片-设备-类型-配置级别.bin\`
- 配置文件: \`分支-芯片-设备-配置级别.config\`
- 软件包: \`芯片-app.tar.gz\`
- 日志文件: \`芯片-log.tar.gz\`

## 👤 作者信息
- **作者**: Mary
- **发布时间**: $(date '+%Y-%m-%d %H:%M:%S')

## ⚠️ 注意事项
1. 刷机前请备份原固件
2. 首次刷机建议使用Factory固件
3. 后续更新可使用Sysupgrade固件
4. 刷机后需恢复出厂设置

---
*由 OpenWrt 企业级编译系统自动生成*
EOF
    
    log_success "✅ Release说明生成完成"
}

# 执行主函数
main "$@"
