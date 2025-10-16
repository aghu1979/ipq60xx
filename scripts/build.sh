#!/bin/bash
# =============================================================================
# OpenWrt 企业级编译脚本 (分层构建版)
# 功能：准备基础环境、合并配置、编译固件、处理产出物
# 
# 使用方法:
#   ./scripts/build.sh prepare-base  # 准备基础环境
#   ./scripts/build.sh build-firmware  # 编译固件
# =============================================================================

# 启用严格模式：遇到错误立即退出，未定义的变量视为错误
# 注意：移除了pipefail，以便更好地处理管道命令中的错误
set -eu

# 导入工具函数和日志系统（必须在定义变量之前导入）
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
# 工具函数
# =============================================================================

# 输出分隔线
print_separator() {
    echo -e "${COLOR_CYAN}====================================================================================================${COLOR_RESET}"
}

# 输出步骤标题
print_step_title() {
    echo -e "\n${COLOR_PURPLE}🔷 $1${COLOR_RESET}"
    print_separator
}

# 输出步骤结果
print_step_result() {
    echo -e "\n${COLOR_GREEN}✅ $1${COLOR_RESET}"
    print_separator
}

# 高亮显示缺失的软件包
highlight_missing_packages() {
    local missing_packages="$1"
    if [[ -n "$missing_packages" ]]; then
        echo -e "\n${COLOR_RED}⚠️ 警告：以下软件包在格式化后缺失：${COLOR_RESET}"
        echo -e "${COLOR_RED}${missing_packages}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}💡 建议：检查这些软件包是否存在于feeds或package目录中${COLOR_RESET}"
    else
        echo -e "\n${COLOR_GREEN}✅ 所有软件包都已正确配置${COLOR_RESET}"
    fi
}

# 提取luci软件包列表（修复版）
extract_luci_packages() {
    local config_file="$1"
    local output_file="$2"
    
    # 检查配置文件是否存在
    if [[ ! -f "$config_file" ]]; then
        log_warning "配置文件不存在: $config_file"
        touch "$output_file"
        return 0
    fi
    
    # 提取软件包列表，添加错误处理
    if grep "CONFIG_PACKAGE_luci-app.*=y" "$config_file" 2>/dev/null | sed 's/CONFIG_PACKAGE_//g; s/=y//g' | sort > "$output_file" 2>/dev/null; then
        # 成功提取
        :
    else
        # 提取失败，创建空文件
        log_warning "无法从 $config_file 提取luci软件包"
        touch "$output_file"
    fi
}

# 对比软件包列表
compare_luci_packages() {
    local before_file="$1"
    local after_file="$2"
    local missing_file="$3"
    
    # 确保文件存在
    [[ -f "$before_file" ]] || touch "$before_file"
    [[ -f "$after_file" ]] || touch "$after_file"
    [[ -f "$missing_file" ]] || touch "$missing_file"
    
    # 找出在before中存在但在after中不存在的软件包
    comm -23 "$before_file" "$after_file" > "$missing_file" 2>/dev/null || true
    
    # 输出对比结果
    echo -e "\n${COLOR_BLUE}📊 Luci软件包对比结果：${COLOR_RESET}"
    
    # 显示格式化前的软件包数量
    local before_count=$(wc -l < "$before_file" 2>/dev/null || echo "0")
    echo -e "${COLOR_CYAN}格式化前软件包数量：${before_count}${COLOR_RESET}"
    
    # 显示格式化后的软件包数量
    local after_count=$(wc -l < "$after_file" 2>/dev/null || echo "0")
    echo -e "${COLOR_CYAN}格式化后软件包数量：${after_count}${COLOR_RESET}"
    
    # 如果有缺失的软件包，高亮显示
    if [[ -s "$missing_file" ]]; then
        local missing_packages=$(cat "$missing_file" | tr '\n' ', ' | sed 's/,$//')
        highlight_missing_packages "$missing_packages"
    else
        echo -e "\n${COLOR_GREEN}✅ 无软件包缺失${COLOR_RESET}"
    fi
}

# 安全执行命令函数（处理管道命令）
safe_execute() {
    local description="$1"
    shift
    local command=("$@")
    local log_file="${LOG_DIR}/${REPO_SHORT}-${description}.log"
    
    # 确保日志目录存在
    mkdir -p "$LOG_DIR"
    
    log_info "🔄 执行命令: ${command[*]}"
    
    # 执行命令并捕获退出状态
    local exit_code=0
    "${command[@]}" 2>&1 | tee "$log_file" || exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "✅ 命令执行成功: $description"
    else
        log_warning "⚠️ 命令执行失败 (退出码: $exit_code): $description"
        log_warning "📋 详细日志: $log_file"
        # 不退出脚本，继续执行
    fi
    
    return $exit_code
}

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
#   2. 更新和安装Feeds
#   3. 安装第三方软件包
#   4. 合并基础配置文件
#   5. 应用基础配置
#   6. 预下载依赖
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
    
    # 步骤1：更新Feeds（在合并配置之前）
    print_step_title "步骤1：更新软件源"
    safe_execute "feeds-update" ./scripts/feeds update -a
    
    # 输出feeds更新摘要
    echo -e "\n${COLOR_BLUE}📋 Feeds更新摘要：${COLOR_RESET}"
    if [[ -d "feeds" ]]; then
        echo -e "${COLOR_CYAN}已更新的feeds目录：${COLOR_RESET}"
        ls -la feeds/ | grep '^d' | awk '{print "  - " $9}'
    fi
    
    print_step_result "软件源更新完成"
    
    # 步骤2：安装Feeds
    print_step_title "步骤2：安装软件源"
    safe_execute "feeds-install" ./scripts/feeds install -a
    
    # 输出feeds安装摘要
    echo -e "\n${COLOR_BLUE}📋 Feeds安装摘要：${COLOR_RESET}"
    if [[ -f "feeds.conf" ]]; then
        echo -e "${COLOR_CYAN}已配置的feeds源：${COLOR_RESET}"
        grep -v '^#' feeds.conf | grep -v '^$' | sed 's/^/  - /'
    fi
    
    print_step_result "软件源安装完成"
    
    # 步骤3：应用自定义脚本（安装第三方软件包）
    print_step_title "步骤3：安装第三方软件包"
    log_info "🛠️ 应用自定义脚本安装第三方软件包..."
    
    if [[ -f "${BASE_DIR}/scripts/diy.sh" ]]; then
        log_info "📝 执行diy.sh脚本，传递参数: ${REPO_SHORT} ${SOC_NAME}"
        # 确保脚本有执行权限
        chmod +x "${BASE_DIR}/scripts/diy.sh"
        
        # 创建日志文件
        local diy_log="${LOG_DIR}/${REPO_SHORT}-diy-base.log"
        mkdir -p "$LOG_DIR"
        
        # 调用diy.sh脚本，传递分支名称和芯片名称
        if bash "${BASE_DIR}/scripts/diy.sh" "${REPO_SHORT}" "${SOC_NAME}" > "$diy_log" 2>&1; then
            log_success "✅ DIY脚本执行完成"
        else
            log_warning "⚠️ DIY脚本执行失败，但继续执行"
            log_warning "📋 详细日志: $diy_log"
        fi
        
        # 输出DIY脚本执行摘要
        echo -e "\n${COLOR_BLUE}📋 DIY脚本执行摘要：${COLOR_RESET}"
        echo -e "${COLOR_CYAN}详细日志：${diy_log}${COLOR_RESET}"
        
        print_step_result "第三方软件包安装完成"
    else
        echo -e "\n${COLOR_YELLOW}⚠️ 未找到自定义脚本: ${BASE_DIR}/scripts/diy.sh${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}ℹ️ 跳过第三方软件包安装${COLOR_RESET}"
        print_step_result "跳过第三方软件包安装"
    fi
    
    # 步骤4：重新安装Feeds（确保新添加的软件包被安装）
    print_step_title "步骤4：重新安装软件源"
    safe_execute "feeds-reinstall" ./scripts/feeds install -a
    print_step_result "软件源重新安装完成"
    
    # 步骤5：合并基础配置文件
    print_step_title "步骤5：合并基础配置文件"
    log_info "🔧 合并基础配置: base_${SOC_NAME}.config + base_${REPO_SHORT}.config"
    
    # 创建临时文件保存合并前的配置
    local base_config="${BASE_DIR}/configs/base_${SOC_NAME}.config"
    local branch_config="${BASE_DIR}/configs/base_${REPO_SHORT}.config"
    local merged_config=".config"
    
    # 合并配置文件
    cat "$base_config" "$branch_config" > "$merged_config"
    
    # 输出合并结果摘要
    echo -e "\n${COLOR_BLUE}📋 配置文件合并摘要：${COLOR_RESET}"
    echo -e "${COLOR_CYAN}芯片配置文件：${base_config}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}分支配置文件：${branch_config}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}合并后配置文件：${merged_config}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}合并后配置行数：$(wc -l < "$merged_config")${COLOR_RESET}"
    
    # 提取并显示基础配置中的luci软件包
    local base_luci_file="${LOG_DIR}/${REPO_SHORT}-base-luci-packages.txt"
    extract_luci_packages "$merged_config" "$base_luci_file"
    if [[ -s "$base_luci_file" ]]; then
        echo -e "\n${COLOR_BLUE}📦 基础配置中的Luci软件包：${COLOR_RESET}"
        cat "$base_luci_file" | sed 's/^/  - /'
    fi
    
    print_step_result "基础配置文件合并完成"
    
    # 步骤6：应用基础配置
    print_step_title "步骤6：应用基础配置"
    log_info "⚙️ 应用基础配置..."
    
    # 提取格式化前的luci软件包
    local before_format_file="${LOG_DIR}/${REPO_SHORT}-before-format-luci.txt"
    extract_luci_packages "$merged_config" "$before_format_file"
    
    # 应用配置
    if make defconfig > "${LOG_DIR}/${REPO_SHORT}-make-defconfig-base.log" 2>&1; then
        log_success "✅ 基础配置应用成功"
    else
        log_warning "⚠️ 基础配置应用失败，但继续执行"
    fi
    
    # 提取格式化后的luci软件包
    local after_format_file="${LOG_DIR}/${REPO_SHORT}-after-format-luci.txt"
    extract_luci_packages "$merged_config" "$after_format_file"
    
    # 对比格式化前后的软件包
    local missing_format_file="${LOG_DIR}/${REPO_SHORT}-missing-format-luci.txt"
    compare_luci_packages "$before_format_file" "$after_format_file" "$missing_format_file"
    
    print_step_result "基础配置应用完成"
    
    # 步骤7：预下载依赖
    print_step_title "步骤7：预下载基础依赖"
    log_info "📥 预下载基础依赖..."
    
    if make download -j$(nproc) > "${LOG_DIR}/${REPO_SHORT}-make-download-base.log" 2>&1; then
        log_success "✅ 依赖下载成功"
    else
        log_warning "⚠️ 依赖下载失败，但继续执行"
    fi
    
    # 输出下载摘要
    echo -e "\n${COLOR_BLUE}📋 依赖下载摘要：${COLOR_RESET}"
    if [[ -d "dl" ]]; then
        local download_count=$(find dl -type f | wc -l)
        local download_size=$(du -sh dl | cut -f1)
        echo -e "${COLOR_CYAN}已下载文件数量：${download_count}${COLOR_RESET}"
        echo -e "${COLOR_CYAN}下载文件总大小：${download_size}${COLOR_RESET}"
    fi
    
    print_step_result "基础依赖预下载完成"
    
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
    
    # 步骤1：合并软件包配置
    print_step_title "步骤1：合并软件包配置"
    log_info "🔧 叠加软件包配置: ${CONFIG_LEVEL}.config"
    
    # 备份当前配置
    cp .config .config.backup
    
    # 将软件包配置追加到现有.config文件末尾
    cat "${BASE_DIR}/configs/${CONFIG_LEVEL}.config" >> .config
    
    # 输出合并摘要
    echo -e "\n${COLOR_BLUE}📋 软件包配置合并摘要：${COLOR_RESET}"
    echo -e "${COLOR_CYAN}基础配置行数：$(wc -l < .config.backup)${COLOR_RESET}"
    echo -e "${COLOR_CYAN}软件包配置：${BASE_DIR}/configs/${CONFIG_LEVEL}.config${COLOR_RESET}"
    echo -e "${COLOR_CYAN}软件包配置行数：$(wc -l < "${BASE_DIR}/configs/${CONFIG_LEVEL}.config")${COLOR_RESET}"
    echo -e "${COLOR_CYAN}合并后总行数：$(wc -l < .config)${COLOR_RESET}"
    
    # 提取并显示新增的luci软件包
    local base_luci_file="${LOG_DIR}/${REPO_SHORT}-base-luci-packages.txt"
    local merged_luci_file="${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-merged-luci.txt"
    extract_luci_packages ".config" "$merged_luci_file"
    
    if [[ -f "$base_luci_file" && -s "$base_luci_file" ]]; then
        echo -e "\n${COLOR_BLUE}📦 新增的Luci软件包：${COLOR_RESET}"
        comm -13 "$base_luci_file" "$merged_luci_file" | sed 's/^/  - /' || echo "  - 无新增软件包"
    fi
    
    print_step_result "软件包配置合并完成"
    
    # 步骤2：格式化最终配置文件
    print_step_title "步骤2：格式化最终配置文件"
    log_info "🎨 格式化最终配置文件..."
    
    # 提取格式化前的luci软件包
    local before_final_format_file="${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-before-final-format.txt"
    extract_luci_packages ".config" "$before_final_format_file"
    
    # 格式化配置
    if ./scripts/config conf --defconfig=.config > "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-config-format.log" 2>&1; then
        log_success "✅ 配置格式化成功"
    else
        log_warning "⚠️ 配置格式化失败，但继续执行"
    fi
    
    # 提取格式化后的luci软件包
    local after_final_format_file="${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-after-final-format.txt"
    extract_luci_packages ".config" "$after_final_format_file"
    
    # 对比格式化前后的软件包
    local missing_final_format_file="${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-missing-final-format.txt"
    compare_luci_packages "$before_final_format_file" "$after_final_format_file" "$missing_final_format_file"
    
    print_step_result "最终配置文件格式化完成"
    
    # 步骤3：验证最终配置文件
    print_step_title "步骤3：验证最终配置文件"
    log_info "🔍 验证最终配置文件..."
    
    if ./scripts/config conf --defconfig=.config --check > "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-config-check.log" 2>&1; then
        log_success "✅ 配置文件验证通过"
    else
        log_warning "⚠️ 配置文件验证失败，但继续执行"
    fi
    
    # 输出配置验证摘要
    echo -e "\n${COLOR_BLUE}📋 配置验证摘要：${COLOR_RESET}"
    echo -e "${COLOR_GREEN}✅ 配置文件验证完成${COLOR_RESET}"
    echo -e "${COLOR_CYAN}最终配置行数：$(wc -l < .config)${COLOR_RESET}"
    
    print_step_result "最终配置文件验证完成"
    
    # 步骤4：记录最终Luci软件包列表
    print_step_title "步骤4：记录最终Luci软件包列表"
    log_info "📋 记录合并后的Luci软件包..."
    
    local final_luci_file="${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-luci-apps.log"
    extract_luci_packages ".config" "$final_luci_file"
    
    # 输出最终软件包摘要
    echo -e "\n${COLOR_BLUE}📦 最终Luci软件包列表：${COLOR_RESET}"
    if [[ -s "$final_luci_file" ]]; then
        local package_count=$(wc -l < "$final_luci_file")
        echo -e "${COLOR_CYAN}软件包总数：${package_count}${COLOR_RESET}"
        echo -e "${COLOR_CYAN}软件包列表：${COLOR_RESET}"
        cat "$final_luci_file" | sed 's/^/  - /'
    else
        echo -e "${COLOR_YELLOW}⚠️ 未找到Luci软件包${COLOR_RESET}"
    fi
    
    print_step_result "Luci软件包列表记录完成"
    
    # 步骤5：编译固件
    print_step_title "步骤5：编译固件"
    log_info "🔥 开始编译固件..."
    
    # 记录编译开始时间
    local build_start_time=$(date +%s)
    
    # 编译固件
    if make -j$(nproc) 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-make-build.log"; then
        # 记录编译结束时间
        local build_end_time=$(date +%s)
        local build_duration=$((build_end_time - build_start_time))
        local build_hours=$((build_duration / 3600))
        local build_minutes=$(((build_duration % 3600) / 60))
        local build_seconds=$((build_duration % 60))
        
        # 输出编译摘要
        echo -e "\n${COLOR_BLUE}📋 编译摘要：${COLOR_RESET}"
        echo -e "${COLOR_GREEN}✅ 编译成功${COLOR_RESET}"
        echo -e "${COLOR_CYAN}编译耗时：${build_hours}小时${build_minutes}分钟${build_seconds}秒${COLOR_RESET}"
        
        # 统计生成的固件文件
        if [[ -d "bin/targets" ]]; then
            local firmware_count=$(find bin/targets -name "*.bin" | wc -l)
            echo -e "${COLOR_CYAN}生成固件数量：${firmware_count}${COLOR_RESET}"
        fi
        
        print_step_result "固件编译完成"
    else
        log_error "❌ 编译失败!"
        # 记录错误上下文（最后1000行）
        tail -n 1000 "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-make-build.log" >> "${LOG_DIR}/error.log"
        exit 1
    fi
    
    # 步骤6：处理产出物
    print_step_title "步骤6：处理产出物"
    process_artifacts
    print_step_result "产出物处理完成"
    
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
    
    # 输出设备摘要
    echo -e "\n${COLOR_BLUE}📋 设备列表摘要：${COLOR_RESET}"
    echo -e "${COLOR_CYAN}目标设备数量：${#devices[@]}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}设备列表：${COLOR_RESET}"
    for device in "${devices[@]}"; do
        echo "  - $device"
    done
    
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
            local file_size=$(du -h "$factory_bin" | cut -f1)
            echo -e "  ${COLOR_GREEN}✅${COLOR_RESET} 工厂固件: $new_name (${COLOR_CYAN}${file_size}${COLOR_RESET})"
        else
            echo -e "  ${COLOR_YELLOW}⚠️${COLOR_RESET} 未找到设备 $device 的工厂固件"
        fi
        
        # 处理系统升级固件
        if [[ -n "$sysupgrade_bin" ]]; then
            local new_name="${REPO_SHORT}-${SOC_NAME}-${device}-sysupgrade-${CONFIG_LEVEL}.bin"
            cp "$sysupgrade_bin" "${temp_dir}/${new_name}"
            local file_size=$(du -h "$sysupgrade_bin" | cut -f1)
            echo -e "  ${COLOR_GREEN}✅${COLOR_RESET} 系统升级固件: $new_name (${COLOR_CYAN}${file_size}${COLOR_RESET})"
        else
            echo -e "  ${COLOR_YELLOW}⚠️${COLOR_RESET} 未找到设备 $device 的系统升级固件"
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
    
    # 打包产出物
    log_info "📦 打包产出物..."
    
    # 打包配置文件
    local config_archive="${OUTPUT_DIR}/${SOC_NAME}-${REPO_SHORT}-${CONFIG_LEVEL}-config.tar.gz"
    tar -czf "$config_archive" -C "$temp_dir" *.config *.manifest *.config.buildinfo 2>/dev/null || true
    if [[ -f "$config_archive" ]]; then
        local archive_size=$(du -h "$config_archive" | cut -f1)
        echo -e "  ${COLOR_GREEN}✅${COLOR_RESET} 配置文件包: $(basename "$config_archive") (${COLOR_CYAN}${archive_size}${COLOR_RESET})"
    fi
    
    # 打包软件包
    if [[ -d "bin/packages" ]]; then
        local app_archive="${OUTPUT_DIR}/${SOC_NAME}-${REPO_SHORT}-${CONFIG_LEVEL}-app.tar.gz"
        tar -czf "$app_archive" -C bin/packages . 2>/dev/null || true
        if [[ -f "$app_archive" ]]; then
            local archive_size=$(du -h "$app_archive" | cut -f1)
            echo -e "  ${COLOR_GREEN}✅${COLOR_RESET} 软件包: $(basename "$app_archive") (${COLOR_CYAN}${archive_size}${COLOR_RESET})"
        fi
    fi
    
    # 打包日志文件
    local log_archive="${OUTPUT_DIR}/${SOC_NAME}-${REPO_SHORT}-${CONFIG_LEVEL}-log.tar.gz"
    tar -czf "$log_archive" -C "${LOG_DIR}" . 2>/dev/null || true
    if [[ -f "$log_archive" ]]; then
        local archive_size=$(du -h "$log_archive" | cut -f1)
        echo -e "  ${COLOR_GREEN}✅${COLOR_RESET} 日志文件包: $(basename "$log_archive") (${COLOR_CYAN}${archive_size}${COLOR_RESET})"
    fi
    
    log_success "✅ 产出物处理完成"
}

# =============================================================================
# 脚本入口点
# =============================================================================

# 执行主函数，并传入所有参数
main "$@"
