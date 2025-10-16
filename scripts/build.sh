#!/bin/bash
# =============================================================================
# OpenWrt 企业级编译脚本 (分层构建版)
# 功能：准备基础环境、合并配置、编译固件、处理产出物
# 
# 使用方法:
#   ./scripts/build.sh prepare-base  # 准备基础环境
#   ./scripts/build.sh build-firmware  # 编译固件
# =============================================================================

# 启用严格模式：遇到错误立即退出，未定义的变量视为错误，管道中任一命令失败则整个管道失败
set -euo pipefail

# 导入工具函数和日志系统
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/logger.sh"

# =============================================================================
# 全局变量定义
# =============================================================================

# 仓库信息（从环境变量获取，如果未设置则使用默认值）
REPO_URL="${REPO_URL:-https://github.com/openwrt/openwrt.git}"
REPO_BRANCH="${REPO_BRANCH:-master}"
REPO_SHORT="${REPO_SHORT:-openwrt}"

# 芯片和配置信息（从环境变量获取，如果未设置则使用默认值）
SOC_NAME="${SOC_NAME:-ipq60xx}"
CONFIG_LEVEL="${CONFIG_LEVEL:-Pro}"

# 时间戳（从环境变量获取，如果未设置则使用当前日期）
TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d)}"

# 目录路径定义
BASE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
OUTPUT_DIR="${BASE_DIR}/output"
LOG_DIR="${BASE_DIR}/logs"
# 构建目录按分支分开，确保不同分支的构建文件不会冲突
BUILD_DIR="${BASE_DIR}/build/${REPO_SHORT}"

# =============================================================================
# 主函数
# =============================================================================

# 主函数：根据传入的参数执行相应的操作
# 参数:
#   $1 - 命令名称 (prepare-base 或 build-firmware)
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
            log_error "使用方法: $0 {prepare-base|build-firmware}"
            exit 1
            ;;
    esac
}

# =============================================================================
# 阶段一：准备基础环境
# =============================================================================

# 准备基础环境函数
# 功能：
#   1. 克隆源码
#   2. 合并基础配置文件
#   3. 应用基础配置
#   4. 更新和安装Feeds
#   5. 预下载依赖
prepare_base_environment() {
    log_info "🚀 [阶段一] 开始为分支 ${REPO_SHORT} 准备基础环境..."
    
    # 创建必要的目录
    mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}" "${LOG_DIR}"
    
    # 检查是否已存在源码目录，如果没有则克隆
    if [[ ! -d "${BUILD_DIR}/.git" ]]; then
        log_info "📥 克隆源码仓库: ${REPO_URL}"
        git clone "${REPO_URL}" "${BUILD_DIR}" --depth=1 -b "${REPO_BRANCH}"
    else
        log_info "📁 源码目录已存在，跳过克隆步骤"
    fi
    
    # 切换到构建目录
    cd "${BUILD_DIR}"
    
    # 合并基础配置文件
    log_info "🔧 合并基础配置: base_${SOC_NAME}.config + base_${REPO_SHORT}.config"
    cat "${BASE_DIR}/configs/base_${SOC_NAME}.config" "${BASE_DIR}/configs/base_${REPO_SHORT}.config" > .config
    
    # 应用基础配置
    log_info "⚙️ 应用基础配置..."
    make defconfig 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-make-defconfig-base.log"
    
    # 更新Feeds（软件源列表）
    log_info "🔄 更新软件源..."
    ./scripts/feeds update -a 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-feeds-update.log"
    
    # 安装Feeds中的软件包
    log_info "📦 安装软件源..."
    ./scripts/feeds install -a 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-feeds-install.log"
    
    # 预下载依赖（可选，但可以加速后续编译）
    log_info "📥 预下载基础依赖..."
    make download -j$(nproc) 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-make-download-base.log"
    
    log_success "✅ 分支 ${REPO_SHORT} 的基础环境准备完成并已缓存"
}

# =============================================================================
# 阶段二：编译固件
# =============================================================================

# 编译固件函数
# 功能：
#   1. 检查基础环境是否存在
#   2. 合并软件包配置
#   3. 格式化并验证最终配置
#   4. 记录合并后的Luci软件包
#   5. 应用自定义脚本
#   6. 编译固件
#   7. 处理产出物
build_firmware() {
    log_info "🔨 [阶段二] 开始为分支 ${REPO_SHORT} 编译 ${CONFIG_LEVEL} 配置固件..."
    
    # 检查基础环境是否存在
    if [[ ! -d "${BUILD_DIR}/.git" ]]; then
        log_error "❌ 基础环境不存在: ${BUILD_DIR}"
        log_error "请确保阶段一 'prepare-base' 已成功运行并缓存。"
        exit 1
    fi
    
    # 切换到构建目录
    cd "${BUILD_DIR}"
    
    # 合并软件包配置
    log_info "🔧 叠加软件包配置: ${CONFIG_LEVEL}.config"
    # 将软件包配置追加到现有.config文件末尾
    cat "${BASE_DIR}/configs/${CONFIG_LEVEL}.config" >> .config
    
    # 格式化最终配置文件
    log_info "🎨 格式化最终配置文件..."
    ./scripts/config conf --defconfig=.config 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-config-format.log"
    
    # 验证最终配置文件
    log_info "🔍 验证最终配置文件..."
    if ! ./scripts/config conf --defconfig=.config --check; then
        log_error "❌ 最终配置文件验证失败"
        exit 1
    fi
    
    # 记录合并后的Luci软件包
    log_info "📋 记录合并后的Luci软件包..."
    grep "CONFIG_PACKAGE_luci-app.*=y" .config > "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-luci-apps.log" || true
    
    # 应用自定义脚本（如果存在）
    log_info "🛠️ 应用自定义脚本..."
    if [[ -f "${BASE_DIR}/scripts/diy.sh" ]]; then
        bash "${BASE_DIR}/scripts/diy.sh" "${REPO_SHORT}" "${SOC_NAME}" 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-diy.log"
    else
        log_info "ℹ️ 未找到自定义脚本，跳过此步骤"
    fi
    
    # 编译固件
    log_info "🔥 开始编译固件..."
    make -j$(nproc) 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-make-build.log" || {
        log_error "❌ 编译失败!"
        # 记录错误上下文（最后1000行）
        tail -n 1000 "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-make-build.log" >> "${LOG_DIR}/error.log"
        exit 1
    }
    
    # 处理产出物
    process_artifacts
    
    log_success "✅ 固件 ${REPO_SHORT}-${CONFIG_LEVEL} 编译完成"
}

# =============================================================================
# 产出物处理
# =============================================================================

# 处理产出物函数
# 功能：
#   1. 提取设备列表
#   2. 查找并重命名固件文件
#   3. 复制配置文件、清单文件等
#   4. 打包产出物
process_artifacts() {
    log_info "📦 处理产出物..."
    
    # 创建临时目录用于存放当前配置的产出物
    local temp_dir="${OUTPUT_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}"
    mkdir -p "$temp_dir"
    
    # 从配置文件中提取设备列表
    local devices=()
    while IFS= read -r line; do
        # 使用正则表达式匹配设备名称
        if [[ $line =~ CONFIG_TARGET_DEVICE_.*_DEVICE_(.+)=y ]]; then
            devices+=("${BASH_REMATCH[1]}")
        fi
    done < "${BUILD_DIR}/.config"
    
    log_info "📋 发现设备: ${devices[*]}"
    
    # 为每个设备处理产出物
    for device in "${devices[@]}"; do
        log_info "🔄 处理设备: $device"
        
        # 查找工厂固件和系统升级固件
        local factory_bin=$(find bin/targets/*/* -name "*${device}*-squashfs-factory.bin" | head -n1)
        local sysupgrade_bin=$(find bin/targets/*/* -name "*${device}*-squashfs-sysupgrade.bin" | head -n1)
        
        # 处理工厂固件
        if [[ -n "$factory_bin" ]]; then
            local new_name="${REPO_SHORT}-${SOC_NAME}-${device}-factory-${CONFIG_LEVEL}.bin"
            cp "$factory_bin" "${temp_dir}/${new_name}"
            log_info "✅ 生成工厂固件: $new_name"
        else
            log_warning "⚠️ 未找到设备 $device 的工厂固件"
        fi
        
        # 处理系统升级固件
        if [[ -n "$sysupgrade_bin" ]]; then
            local new_name="${REPO_SHORT}-${SOC_NAME}-${device}-sysupgrade-${CONFIG_LEVEL}.bin"
            cp "$sysupgrade_bin" "${temp_dir}/${new_name}"
            log_info "✅ 生成系统升级固件: $new_name"
        else
            log_warning "⚠️ 未找到设备 $device 的系统升级固件"
        fi
        
        # 复制配置文件
        cp "${BUILD_DIR}/.config" "${temp_dir}/${REPO_SHORT}-${SOC_NAME}-${device}-${CONFIG_LEVEL}.config"
        
        # 复制清单文件（如果存在）
        local manifest_file=$(find bin/targets/*/* -name "${device}.manifest" | head -n1)
        if [[ -n "$manifest_file" ]]; then
            cp "$manifest_file" "${temp_dir}/${REPO_SHORT}-${SOC_NAME}-${device}-${CONFIG_LEVEL}.manifest"
        fi
        
        # 复制构建信息文件（如果存在）
        local buildinfo_file=$(find bin/targets/*/* -name "config.buildinfo" | head -n1)
        if [[ -n "$buildinfo_file" ]]; then
            cp "$buildinfo_file" "${temp_dir}/${REPO_SHORT}-${SOC_NAME}-${device}-${CONFIG_LEVEL}.config.buildinfo"
        fi
    done
    
    # 打包配置文件
    log_info "📦 打包配置文件..."
    tar -czf "${OUTPUT_DIR}/${SOC_NAME}-${REPO_SHORT}-${CONFIG_LEVEL}-config.tar.gz" -C "$temp_dir" *.config *.manifest *.config.buildinfo || true
    
    # 打包软件包
    if [[ -d "bin/packages" ]]; then
        log_info "📦 打包软件包..."
        tar -czf "${OUTPUT_DIR}/${SOC_NAME}-${REPO_SHORT}-${CONFIG_LEVEL}-app.tar.gz" -C bin/packages . || true
    fi
    
    # 打包日志文件
    log_info "📦 打包日志文件..."
    tar -czf "${OUTPUT_DIR}/${SOC_NAME}-${REPO_SHORT}-${CONFIG_LEVEL}-log.tar.gz" -C "${LOG_DIR}" . || true
    
    log_success "✅ 产出物处理完成"
}

# =============================================================================
# 脚本入口点
# =============================================================================

# 执行主函数，并传入所有参数
main "$@"
