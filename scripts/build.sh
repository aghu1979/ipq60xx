#!/bin/bash
# OpenWrt 企业级编译脚本 (分层构建版)
# 功能：准备基础环境、合并配置、编译固件、处理产出物

set -euo pipefail

# 导入工具函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/logger.sh"

# 全局变量
REPO_URL="${REPO_URL:-}"
REPO_BRANCH="${REPO_BRANCH:-master}"
REPO_SHORT="${REPO_SHORT:-openwrt}"
SOC_NAME="${SOC_NAME:-ipq60xx}"
CONFIG_LEVEL="${CONFIG_LEVEL:-Pro}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d)}"
BASE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
OUTPUT_DIR="${BASE_DIR}/output"
LOG_DIR="${BASE_DIR}/logs"
# 构建目录按分支分开
BUILD_DIR="${BASE_DIR}/build/${REPO_SHORT}"

# 主函数
main() {
    local command="${1:-}"
    
    case "$command" in
        prepare-base)
            prepare_base_environment
            ;;
        build-firmware)
            build_firmware
            ;;
        *)
            log_error "未知命令: $command"
            exit 1
            ;;
    esac
}

# 准备基础环境 (阶段一)
prepare_base_environment() {
    log_info "🚀 [阶段一] 开始为分支 ${REPO_SHORT} 准备基础环境..."
    
    # 创建目录
    mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}" "${LOG_DIR}"
    
    # 克隆源码
    if [[ ! -d "${BUILD_DIR}/.git" ]]; then
        log_info "📥 克隆源码仓库: ${REPO_URL}"
        git clone "${REPO_URL}" "${BUILD_DIR}" --depth=1 -b "${REPO_BRANCH}"
    fi
    
    cd "${BUILD_DIR}"
    
    # 合并基础配置
    log_info "🔧 合并基础配置: base_${SOC_NAME}.config + base_${REPO_SHORT}.config"
    cat "${BASE_DIR}/configs/base_${SOC_NAME}.config" "${BASE_DIR}/configs/base_${REPO_SHORT}.config" > .config
    
    # 应用基础配置
    log_info "⚙️ 应用基础配置..."
    make defconfig 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-make-defconfig-base.log"
    
    # 更新和安装Feeds
    log_info "🔄 更新软件源..."
    ./scripts/feeds update -a 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-feeds-update.log"
    log_info "📦 安装软件源..."
    ./scripts/feeds install -a 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-feeds-install.log"
    
    # 预下载依赖（可选，但可以加速后续编译）
    log_info "📥 预下载基础依赖..."
    make download -j$(nproc) 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-make-download-base.log"
    
    log_success "✅ 分支 ${REPO_SHORT} 的基础环境准备完成并已缓存"
}

# 编译固件 (阶段二)
build_firmware() {
    log_info "🔨 [阶段二] 开始为分支 ${REPO_SHORT} 编译 ${CONFIG_LEVEL} 配置固件..."
    
    # 检查基础环境是否存在
    if [[ ! -d "${BUILD_DIR}/.git" ]]; then
        log_error "❌ 基础环境不存在: ${BUILD_DIR}"
        log_error "请确保阶段一 'prepare-base' 已成功运行并缓存。"
        exit 1
    fi
    
    cd "${BUILD_DIR}"
    
    # 合并软件包配置
    log_info "🔧 叠加软件包配置: ${CONFIG_LEVEL}.config"
    # 将软件包配置追加到现有.config文件末尾
    cat "${BASE_DIR}/configs/${CONFIG_LEVEL}.config" >> .config
    
    # 格式化并验证最终配置
    log_info "🎨 格式化最终配置文件..."
    ./scripts/config conf --defconfig=.config 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-config-format.log"
    
    log_info "🔍 验证最终配置文件..."
    if ! ./scripts/config conf --defconfig=.config --check; then
        log_error "❌ 最终配置文件验证失败"
        exit 1
    fi
    
    # 记录合并后的Luci软件包
    log_info "📋 记录合并后的Luci软件包..."
    grep "CONFIG_PACKAGE_luci-app.*=y" .config > "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-luci-apps.log" || true
    
    # 应用自定义脚本
    log_info "🛠️ 应用自定义脚本..."
    if [[ -f "${BASE_DIR}/scripts/diy.sh" ]]; then
        bash "${BASE_DIR}/scripts/diy.sh" "${REPO_SHORT}" "${SOC_NAME}" 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-diy.log"
    fi
    
    # 编译固件
    log_info "🔥 开始编译固件..."
    make -j$(nproc) 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-make-build.log" || {
        log_error "❌ 编译失败!"
        tail -n 1000 "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-make-build.log" >> "${LOG_DIR}/error.log"
        exit 1
    }
    
    # 处理产出物
    process_artifacts
    
    log_success "✅ 固件 ${REPO_SHORT}-${CONFIG_LEVEL} 编译完成"
}

# 处理产出物 (函数内容与之前相同，但路径变量已更新)
process_artifacts() {
    log_info "📦 处理产出物..."
    
    local temp_dir="${OUTPUT_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}"
    mkdir -p "$temp_dir"
    
    local devices=()
    while IFS= read -r line; do
        if [[ $line =~ CONFIG_TARGET_DEVICE_.*_DEVICE_(.+)=y ]]; then
            devices+=("${BASH_REMATCH[1]}")
        fi
    done < "${BUILD_DIR}/.config"
    
    log_info "📋 发现设备: ${devices[*]}"
    
    for device in "${devices[@]}"; do
        log_info "🔄 处理设备: $device"
        
        local factory_bin=$(find bin/targets/*/* -name "*${device}*-squashfs-factory.bin" | head -n1)
        local sysupgrade_bin=$(find bin/targets/*/* -name "*${device}*-squashfs-sysupgrade.bin" | head -n1)
        
        if [[ -n "$factory_bin" ]]; then
            local new_name="${REPO_SHORT}-${SOC_NAME}-${device}-factory-${CONFIG_LEVEL}.bin"
            cp "$factory_bin" "${temp_dir}/${new_name}"
            log_info "✅ 生成固件: $new_name"
        fi
        
        if [[ -n "$sysupgrade_bin" ]]; then
            local new_name="${REPO_SHORT}-${SOC_NAME}-${device}-sysupgrade-${CONFIG_LEVEL}.bin"
            cp "$sysupgrade_bin" "${temp_dir}/${new_name}"
            log_info "✅ 生成固件: $new_name"
        fi
        
        # 处理其他文件...
        cp "${BUILD_DIR}/.config" "${temp_dir}/${REPO_SHORT}-${SOC_NAME}-${device}-${CONFIG_LEVEL}.config"
        
        local manifest_file=$(find bin/targets/*/* -name "${device}.manifest" | head -n1)
        if [[ -n "$manifest_file" ]]; then
            cp "$manifest_file" "${temp_dir}/${REPO_SHORT}-${SOC_NAME}-${device}-${CONFIG_LEVEL}.manifest"
        fi
    done
    
    # 打包...
    tar -czf "${OUTPUT_DIR}/${SOC_NAME}-${REPO_SHORT}-${CONFIG_LEVEL}-config.tar.gz" -C "$temp_dir" *.config *.manifest || true
    
    if [[ -d "bin/packages" ]]; then
        tar -czf "${OUTPUT_DIR}/${SOC_NAME}-${REPO_SHORT}-${CONFIG_LEVEL}-app.tar.gz" -C bin/packages . || true
    fi
    
    log_success "✅ 产出物处理完成"
}

# 执行主函数
main "$@"
