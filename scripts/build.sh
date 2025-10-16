#!/bin/bash
# OpenWrt 企业级编译脚本
# 功能：准备环境、合并配置、编译固件、处理产出物

set -euo pipefail  # 严格模式：遇到错误立即退出

# 导入工具函数
source "$(dirname "$0")/utils.sh"
source "$(dirname "$0")/logger.sh"

# 全局变量
REPO_URL="${REPO_URL:-https://github.com/openwrt/openwrt.git}"
REPO_BRANCH="${REPO_BRANCH:-master}"
REPO_SHORT="${REPO_SHORT:-openwrt}"
SOC_NAME="${SOC_NAME:-ipq60xx}"
CONFIG_LEVEL="${CONFIG_LEVEL:-Pro}"
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d)}"
BASE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
OUTPUT_DIR="${BASE_DIR}/output"
LOG_DIR="${BASE_DIR}/logs"
BUILD_DIR="${BASE_DIR}/build"

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

# 准备基础环境
prepare_base_environment() {
    log_info "🚀 开始准备基础环境..."
    
    # 创建目录
    mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}" "${LOG_DIR}"
    
    # 克隆源码
    if [[ ! -d "${BUILD_DIR}/${REPO_SHORT}" ]]; then
        log_info "📥 克隆源码仓库: ${REPO_URL}"
        git clone "${REPO_URL}" "${BUILD_DIR}/${REPO_SHORT}" --depth=1 -b "${REPO_BRANCH}"
    fi
    
    cd "${BUILD_DIR}/${REPO_SHORT}"
    
    # 更新feeds
    log_info "🔄 更新软件源..."
    ./scripts/feeds update -a 2>&1 | tee "${LOG_DIR}/feeds-update.log"
    
    # 安装feeds
    log_info "📦 安装软件源..."
    ./scripts/feeds install -a 2>&1 | tee "${LOG_DIR}/feeds-install.log"
    
    # 保存基础环境
    log_info "💾 保存基础环境..."
    mkdir -p "${BASE_DIR}/base-env"
    cp -r . "${BASE_DIR}/base-env"
    
    log_success "✅ 基础环境准备完成"
}

# 编译固件
build_firmware() {
    log_info "🔨 开始编译固件..."
    
    # 恢复基础环境
    if [[ ! -d "${BUILD_DIR}/${REPO_SHORT}" ]]; then
        log_info "📂 恢复基础环境..."
        cp -r "${BASE_DIR}/base-env" "${BUILD_DIR}/${REPO_SHORT}"
    fi
    
    cd "${BUILD_DIR}/${REPO_SHORT}"
    
    # 合并配置文件
    merge_configs
    
    # 应用自定义脚本
    apply_diy_script
    
    # 编译固件
    compile_firmware
    
    # 处理产出物
    process_artifacts
    
    log_success "✅ 固件编译完成"
}

# 合并配置文件
merge_configs() {
    log_info "🔧 合并配置文件..."
    
    local base_config="${BASE_DIR}/configs/base_${SOC_NAME}.config"
    local branch_config="${BASE_DIR}/configs/base_${REPO_SHORT}.config"
    local level_config="${BASE_DIR}/configs/${CONFIG_LEVEL}.config"
    local final_config="${BUILD_DIR}/${REPO_SHORT}/${CONFIG_FILE}"
    
    # 检查配置文件存在
    for config in "$base_config" "$branch_config" "$level_config"; do
        if [[ ! -f "$config" ]]; then
            log_error "❌ 配置文件不存在: $config"
            exit 1
        fi
    done
    
    # 合并配置 (优先级: level > branch > base)
    cat "$base_config" "$branch_config" "$level_config" > "$final_config"
    
    # 格式化配置文件
    log_info "🎨 格式化配置文件..."
    ./scripts/config conf --defconfig="$final_config" 2>&1 | tee "${LOG_DIR}/config-format.log"
    
    # 验证配置
    log_info "🔍 验证配置文件..."
    if ! ./scripts/config conf --defconfig="$final_config" --check; then
        log_error "❌ 配置文件验证失败"
        exit 1
    fi
    
    # 记录合并后的软件包
    log_info "📋 记录合并后的软件包..."
    grep "CONFIG_PACKAGE_luci-app.*=y" "$final_config" > "${LOG_DIR}/luci-apps-merged.log" || true
    
    log_success "✅ 配置文件合并完成"
}

# 应用自定义脚本
apply_diy_script() {
    log_info "🛠️ 应用自定义脚本..."
    
    # 执行diy.sh
    if [[ -f "${BASE_DIR}/scripts/diy.sh" ]]; then
        bash "${BASE_DIR}/scripts/diy.sh" "${REPO_SHORT}" "${SOC_NAME}" 2>&1 | tee "${LOG_DIR}/diy.log"
    else
        log_warning "⚠️ 未找到diy.sh脚本"
    fi
    
    log_success "✅ 自定义脚本应用完成"
}

# 编译固件
compile_firmware() {
    log_info "🔥 开始编译固件..."
    
    # 设置编译线程数
    local threads=$(nproc)
    log_info "⚙️ 使用 ${threads} 线程编译"
    
    # 下载依赖
    log_info "📥 下载依赖..."
    make defconfig 2>&1 | tee "${LOG_DIR}/make-defconfig.log"
    make download -j${threads} 2>&1 | tee "${LOG_DIR}/make-download.log"
    
    # 编译固件
    log_info "🔨 编译固件..."
    make -j${threads} 2>&1 | tee "${LOG_DIR}/make-build.log" || {
        log_error "❌ 编译失败!"
        tail -n 1000 "${LOG_DIR}/make-build.log" >> "${LOG_DIR}/error.log"
        exit 1
    }
    
    log_success "✅ 固件编译完成"
}

# 处理产出物
process_artifacts() {
    log_info "📦 处理产出物..."
    
    # 创建临时目录
    local temp_dir="${OUTPUT_DIR}/${REPO_SHORT}-${SOC_NAME}-${CONFIG_LEVEL}"
    mkdir -p "$temp_dir"
    
    # 提取设备列表
    local devices=()
    while IFS= read -r line; do
        if [[ $line =~ CONFIG_TARGET_DEVICE_.*_DEVICE_(.+)=y ]]; then
            devices+=("${BASH_REMATCH[1]}")
        fi
    done < "${BUILD_DIR}/${REPO_SHORT}/${CONFIG_FILE}"
    
    log_info "📋 发现设备: ${devices[*]}"
    
    # 处理每个设备的产出物
    for device in "${devices[@]}"; do
        log_info "🔄 处理设备: $device"
        
        # 查找固件文件
        local factory_bin=$(find bin/targets/*/* -name "*${device}*-squashfs-factory.bin" | head -n1)
        local sysupgrade_bin=$(find bin/targets/*/* -name "*${device}*-squashfs-sysupgrade.bin" | head -n1)
        
        # 重命名固件
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
        
        # 处理配置文件
        local config_file="${BUILD_DIR}/${REPO_SHORT}/${CONFIG_FILE}"
        local new_config="${REPO_SHORT}-${SOC_NAME}-${device}-${CONFIG_LEVEL}.config"
        cp "$config_file" "${temp_dir}/${new_config}"
        
        # 处理manifest文件
        local manifest_file=$(find bin/targets/*/* -name "${device}.manifest" | head -n1)
        if [[ -n "$manifest_file" ]]; then
            local new_manifest="${REPO_SHORT}-${SOC_NAME}-${device}-${CONFIG_LEVEL}.manifest"
            cp "$manifest_file" "${temp_dir}/${new_manifest}"
        fi
        
        # 处理buildinfo文件
        local buildinfo_file=$(find bin/targets/*/* -name "config.buildinfo" | head -n1)
        if [[ -n "$buildinfo_file" ]]; then
            local new_buildinfo="${REPO_SHORT}-${SOC_NAME}-${device}-${CONFIG_LEVEL}.config.buildinfo"
            cp "$buildinfo_file" "${temp_dir}/${new_buildinfo}"
        fi
    done
    
    # 打包配置文件
    tar -czf "${OUTPUT_DIR}/${SOC_NAME}-config.tar.gz" -C "$temp_dir" *.config *.manifest *.config.buildinfo
    
    # 打包软件包
    if [[ -d "bin/packages" ]]; then
        tar -czf "${OUTPUT_DIR}/${SOC_NAME}-app.tar.gz" -C bin/packages .
    fi
    
    # 打包日志
    tar -czf "${OUTPUT_DIR}/${SOC_NAME}-log.tar.gz" -C "${LOG_DIR}" .
    
    log_success "✅ 产出物处理完成"
}

# 执行主函数
main "$@"
