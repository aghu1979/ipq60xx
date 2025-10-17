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
# --- 修改点：确保CONFIG_LEVEL为小写 ---
CONFIG_LEVEL="${CONFIG_LEVEL:-Pro}"
CONFIG_LEVEL=$(echo "$CONFIG_LEVEL" | tr '[:upper:]' '[:lower:]')

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

# 提取luci软件包列表
extract_luci_packages() {
    local config_file="$1"
    local output_file="$2"
    
    if [[ ! -f "$config_file" ]]; then
        log_warning "配置文件不存在: $config_file"
        touch "$output_file"
        return 0
    fi
    
    if grep "CONFIG_PACKAGE_luci-app.*=y" "$config_file" 2>/dev/null | sed 's/CONFIG_PACKAGE_//g; s/=y//g' | sort > "$output_file" 2>/dev/null; then
        :
    else
        log_warning "无法从 $config_file 提取luci软件包"
        touch "$output_file"
    fi
}

# 对比软件包列表并显示差异 (优化版)
compare_and_show_package_diff() {
    local before_file="$1"
    local after_file="$2"
    local stage_name="$3"
    
    # 确保文件存在
    [[ -f "$before_file" ]] || touch "$before_file"
    [[ -f "$after_file" ]] || touch "$after_file"
    
    echo -e "\n${COLOR_BLUE}📊 ${stage_name} Luci软件包对比结果：${COLOR_RESET}"
    
    local before_count=$(wc -l < "$before_file" 2>/dev/null || echo "0")
    local after_count=$(wc -l < "$after_file" 2>/dev/null || echo "0")
    echo -e "${COLOR_CYAN}补全前软件包数量：${before_count}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}补全后软件包数量：${after_count}${COLOR_RESET}"
    
    # 找出在补全后新增的软件包
    local added_file=$(mktemp)
    comm -13 "$before_file" "$after_file" > "$added_file"
    echo -e "\n${COLOR_GREEN}✅ 新增的软件包 (由依赖自动引入)：${COLOR_RESET}"
    if [[ -s "$added_file" ]]; then
        cat "$added_file" | sed 's/^/  - /'
    else
        echo -e "  - 无"
    fi
    
    # 找出在补全后消失的软件包 (通常因为依赖不满足)
    local removed_file=$(mktemp)
    comm -23 "$before_file" "$after_file" > "$removed_file"
    echo -e "\n${COLOR_RED}❌ 移除的软件包 (因依赖不满足)：${COLOR_RESET}"
    if [[ -s "$removed_file" ]]; then
        cat "$removed_file" | sed 's/^/  - /'
    else
        echo -e "  - 无"
    fi
    
    rm -f "$added_file" "$removed_file"
}

# 安全执行命令函数
safe_execute() {
    local description="$1"
    shift
    local command=("$@")
    local log_file="${LOG_DIR}/${REPO_SHORT}-${description}.log"
    
    mkdir -p "$LOG_DIR"
    
    log_info "🔄 执行命令: ${command[*]}"
    
    local exit_code=0
    "${command[@]}" 2>&1 | tee "$log_file" || exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "✅ 命令执行成功: $description"
    else
        log_warning "⚠️ 命令执行失败 (退出码: $exit_code): $description"
        log_warning "📋 详细日志: $log_file"
    fi
    
    return $exit_code
}

# 显示系统资源使用情况
show_system_resources() {
    echo -e "\n${COLOR_BLUE}📊 系统资源使用情况${COLOR_RESET}"
    print_separator
    df -h
    free -h
    if command -v lscpu >/dev/null 2>&1; then
        lscpu | grep -E "(Model name|CPU\(s\))" || echo "无法获取CPU信息"
    else
        cat /proc/cpuinfo | grep -E "(processor|model name)" | head -5
    fi
    print_separator
}

# 清理临时文件和缓存
cleanup_temp_files() {
    log_info "🧹 清理临时文件和缓存..."
    if [[ -d "${BUILD_DIR}" ]]; then
        find "${BUILD_DIR}" -name "*.o" -delete 2>/dev/null || true
        find "${BUILD_DIR}" -name "*.tmp" -delete 2>/dev/null || true
    fi
    if [[ -d "${LOG_DIR}" ]]; then
        find "${LOG_DIR}" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    fi
    log_success "✅ 临时文件清理完成"
}

# =============================================================================
# 新增：健壮性函数
# =============================================================================

# 标准化配置文件名为小写 (双重保险)
normalize_config_filenames() {
    log_info "🔧 检查并标准化配置文件名 (双重保险)..."
    local configs_dir="${BASE_DIR}/configs"
    if [[ ! -d "$configs_dir" ]]; then
        log_warning "configs目录不存在，跳过文件名标准化。"
        return
    fi
    
    local renamed_count=0
    while IFS= read -r -d '' config_file; do
        local base_name=$(basename "$config_file" .config)
        local lower_name=$(echo "$base_name" | tr '[:upper:]' '[:lower:]')
        if [[ "$base_name" != "$lower_name" ]]; then
            local new_path="${configs_dir}/${lower_name}.config"
            log_info "  - 重命名: $config_file -> $new_path"
            mv "$config_file" "$new_path"
            ((renamed_count++))
        fi
    done < <(find "$configs_dir" -maxdepth 1 -name "*.config")

    if [[ $renamed_count -gt 0 ]]; then
        log_success "✅ 文件名标准化完成，共重命名 $renamed_count 个文件。"
    else
        log_info "✅ 所有配置文件名已是标准小写，无需操作。"
    fi
}

# =============================================================================
# 主函数
# =============================================================================

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
# 核心配置处理函数
# =============================================================================

# 使用 cat 合并配置文件 (最简单可靠的方法)
# 参数:
#   $1 - 输出文件路径
#   $@ - 要合并的配置文件列表 (按顺序)
merge_configs_with_cat() {
    local output_file="$1"
    shift
    local config_files=("$@")
    
    log_info "🔧 使用 cat 合并配置文件..."
    log_info "  - 输出文件: $output_file"
    log_info "  - 合并顺序:"
    for cfg in "${config_files[@]}"; do
        log_info "    - $cfg"
        if [[ ! -f "$cfg" ]]; then
            log_error "❌ 配置文件不存在: $cfg"
            exit 1
        fi
    done
    
    if cat "${config_files[@]}" > "$output_file"; then
        log_success "✅ 配置文件合并成功"
    else
        log_error "❌ 配置文件合并失败!"
        exit 1
    fi
}

# 格式化配置文件并补全依赖
# 参数:
#   $1 - 阶段标识 (base, pro, max, ultra)
format_and_defconfig() {
    local stage="$1"
    log_info "🎨 格式化${stage}配置文件并补全依赖..."
    
    # 1. 提取补全前的luci软件包
    local before_file="${LOG_DIR}/${REPO_SHORT}-${stage}-before-defconfig.txt"
    extract_luci_packages ".config" "$before_file"
    
    # 2. 使用 make defconfig 补全依赖
    log_info "🔄 使用 'make defconfig' 补全配置依赖..."
    local defconfig_log="${LOG_DIR}/${REPO_SHORT}-${stage}-defconfig.log"
    if make defconfig > "$defconfig_log" 2>&1; then
        log_success "✅ ${stage}配置补全成功"
    else
        log_error "❌ ${stage}配置补全失败!"
        log_error "📋 错误详情 (最后20行):"
        tail -n 20 "$defconfig_log" >&2
        log_error "📋 完整日志: $defconfig_log"
        exit 1
    fi
    
    # 3. 提取补全后的luci软件包
    local after_file="${LOG_DIR}/${REPO_SHORT}-${stage}-after-defconfig.txt"
    extract_luci_packages ".config" "$after_file"
    
    # 4. 对比并显示差异
    compare_and_show_package_diff "$before_file" "$after_file" "${stage}"
    
    log_success "✅ ${stage}配置文件处理完成"
}

# =============================================================================
# 阶段一：准备基础环境
# =============================================================================

prepare_base_environment() {
    log_info "🚀 [阶段一] 开始为分支 ${REPO_SHORT} 准备基础环境..."
    show_system_resources
    mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}" "${LOG_DIR}"
    
    # --- 新增：执行文件名标准化 ---
    normalize_config_filenames

    if [[ ! -d "${BUILD_DIR}/.git" ]]; then
        log_info "📥 克隆源码仓库: ${REPO_URL}"
        git clone "${REPO_URL}" "${BUILD_DIR}" --depth=1 -b "${REPO_BRANCH}"
    else
        log_info "📁 源码目录已存在，跳过克隆步骤"
    fi
    
    cd "${BUILD_DIR}"
    
    # 步骤1-4: 更新和安装Feeds
    print_step_title "步骤1-4: 更新和安装Feeds"
    safe_execute "feeds-update" ./scripts/feeds update -a
    safe_execute "feeds-install" ./scripts/feeds install -a
    
    # 步骤5: 应用自定义脚本
    print_step_title "步骤5: 安装第三方软件包"
    if [[ -f "${BASE_DIR}/scripts/diy.sh" ]]; then
        chmod +x "${BASE_DIR}/scripts/diy.sh"
        if bash "${BASE_DIR}/scripts/diy.sh" "${REPO_SHORT}" "${SOC_NAME}" > "${LOG_DIR}/${REPO_SHORT}-diy-base.log" 2>&1; then
            log_success "✅ DIY脚本执行完成"
        else
            log_warning "⚠️ DIY脚本执行失败，但继续执行"
        fi
        safe_execute "feeds-reinstall" ./scripts/feeds install -a
    else
        log_warning "⚠️ 未找到自定义脚本，跳过"
    fi
    print_step_result "Feeds和第三方软件包安装完成"
    
    # 步骤6: 合并基础配置文件
    print_step_title "步骤6: 合并基础配置文件"
    local base_config="${BASE_DIR}/configs/base_${SOC_NAME}.config"
    local branch_config="${BASE_DIR}/configs/base_${REPO_SHORT}.config"
    merge_configs_with_cat ".config" "$base_config" "$branch_config"
    print_step_result "基础配置文件合并完成"
    
    # 步骤7: 格式化并补全依赖
    print_step_title "步骤7: 格式化并补全基础配置依赖"
    format_and_defconfig "base"
    print_step_result "基础配置处理完成"
    
    # 步骤8: 预下载依赖 (关键步骤：缓存前必须完成)
    print_step_title "步骤8: 预下载基础依赖 (为缓存做准备)"
    log_info "📥 预下载基础依赖，此步骤完成后将进行缓存..."
    if make download -j$(nproc) > "${LOG_DIR}/${REPO_SHORT}-make-download-base.log" 2>&1; then
        log_success "✅ 依赖下载成功"
        
        # 输出下载摘要
        echo -e "\n${COLOR_BLUE}📋 依赖下载摘要：${COLOR_RESET}"
        if [[ -d "dl" ]]; then
            local download_count=$(find dl -type f | wc -l)
            local download_size=$(du -sh dl | cut -f1)
            echo -e "${COLOR_CYAN}已下载文件数量：${download_count}${COLOR_RESET}"
            echo -e "${COLOR_CYAN}下载文件总大小：${download_size}${COLOR_RESET}"
        fi
        
    else
        log_warning "⚠️ 依赖下载失败，但继续执行"
    fi
    print_step_result "基础依赖预下载完成"
    
    cleanup_temp_files
    show_system_resources
    log_success "✅ 分支 ${REPO_SHORT} 的基础环境准备完成并已缓存"
}

# =============================================================================
# 阶段二：编译固件
# =============================================================================

build_firmware() {
    log_info "🔨 [阶段二] 开始为分支 ${REPO_SHORT} 编译 ${CONFIG_LEVEL} 配置固件..."
    show_system_resources
    
    if [[ ! -d "${BUILD_DIR}/.git" ]]; then
        log_error "❌ 基础环境不存在: ${BUILD_DIR}"
        exit 1
    fi
    
    cd "${BUILD_DIR}"
    
    # 步骤1: 合并软件包配置
    print_step_title "步骤1: 合并软件包配置"
    local config_file="${BASE_DIR}/configs/${CONFIG_LEVEL}.config"
    if [[ ! -f "$config_file" ]]; then
        log_error "❌ 软件包配置文件不存在: $config_file"
        log_error "📁 configs目录内容："
        ls -la "${BASE_DIR}/configs/" || echo "configs目录不存在"
        exit 1
    fi
    
    # 使用cat合并：基础配置 + 软件包配置
    merge_configs_with_cat ".config" ".config" "$config_file"
    print_step_result "软件包配置合并完成"
    
    # 步骤2: 格式化并补全依赖
    print_step_title "步骤2: 格式化并补全最终配置依赖"
    log_info "即将对 ${CONFIG_LEVEL} 配置进行依赖补全，并对比补全前后的软件包差异..."
    format_and_defconfig "${CONFIG_LEVEL}"
    print_step_result "最终配置处理完成"
    
    # 步骤3: 记录最终Luci软件包列表
    print_step_title "步骤3: 记录最终Luci软件包列表"
    local final_luci_file="${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-luci-apps.log"
    extract_luci_packages ".config" "$final_luci_file"
    if [[ -s "$final_luci_file" ]]; then
        local package_count=$(wc -l < "$final_luci_file")
        echo -e "${COLOR_CYAN}软件包总数：${package_count}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}⚠️ 未找到Luci软件包${COLOR_RESET}"
    fi
    print_step_result "Luci软件包列表记录完成"
    
    # 步骤4: 编译固件
    print_step_title "步骤4: 编译固件"
    log_info "🔥 开始编译固件..."
    local build_start_time=$(date +%s)
    
    if make -j$(nproc) 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-make-build.log"; then
        local build_end_time=$(date +%s)
        local build_duration=$((build_end_time - build_start_time))
        local build_hours=$((build_duration / 3600))
        local build_minutes=$(((build_duration % 3600) / 60))
        echo -e "\n${COLOR_BLUE}📋 编译摘要：${COLOR_RESET}"
        echo -e "${COLOR_GREEN}✅ 编译成功${COLOR_RESET}"
        echo -e "${COLOR_CYAN}编译耗时：${build_hours}小时${build_minutes}分钟${COLOR_RESET}"
        print_step_result "固件编译完成"
    else
        log_error "❌ 编译失败!"
        tail -n 1000 "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-make-build.log" >> "${LOG_DIR}/error.log"
        exit 1
    fi
    
    # 步骤5: 处理产出物
    print_step_title "步骤5: 处理产出物"
    process_artifacts
    print_step_result "产出物处理完成"
    
    cleanup_temp_files
    show_system_resources
    log_success "✅ 固件 ${REPO_SHORT}-${CONFIG_LEVEL} 编译完成"
}

# =============================================================================
# 产出物处理
# =============================================================================

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
    
    echo -e "\n${COLOR_BLUE}📋 设备列表摘要：${COLOR_RESET}"
    echo -e "${COLOR_CYAN}目标设备数量：${#devices[@]}${COLOR_RESET}"
    for device in "${devices[@]}"; do
        log_info "🔄 处理设备: $device"
        local factory_bin=$(find bin/targets/*/* -name "*${device}*-squashfs-factory.bin" | head -n1)
        local sysupgrade_bin=$(find bin/targets/*/* -name "*${device}*-squashfs-sysupgrade.bin" | head -n1)
        
        if [[ -n "$factory_bin" ]]; then
            local new_name="${REPO_SHORT}-${SOC_NAME}-${device}-factory-${CONFIG_LEVEL}.bin"
            cp "$factory_bin" "${temp_dir}/${new_name}"
            echo -e "  ${COLOR_GREEN}✅${COLOR_RESET} 工厂固件: $new_name"
        fi
        if [[ -n "$sysupgrade_bin" ]]; then
            local new_name="${REPO_SHORT}-${SOC_NAME}-${device}-sysupgrade-${CONFIG_LEVEL}.bin"
            cp "$sysupgrade_bin" "${temp_dir}/${new_name}"
            echo -e "  ${COLOR_GREEN}✅${COLOR_RESET} 系统升级固件: $new_name"
        fi
        cp "${BUILD_DIR}/.config" "${temp_dir}/${REPO_SHORT}-${SOC_NAME}-${device}-${CONFIG_LEVEL}.config"
    done
    
    log_success "✅ 产出物处理完成"
}

# =============================================================================
# 脚本入口点
# =============================================================================

main "$@"
