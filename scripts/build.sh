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
# 新增：全局文件名标准化函数
# =============================================================================

# 标准化项目中的关键文件名为小写
standardize_project_filenames() {
    log_info "🔧 检查并标准化项目文件名..."
    local renamed_count=0

    # 1. 标准化 configs 目录下的 .config 文件
    local configs_dir="${BASE_DIR}/configs"
    if [[ -d "$configs_dir" ]]; then
        while IFS= read -r -d '' config_file; do
            local base_name=$(basename "$config_file" .config)
            local lower_name=$(echo "$base_name" | tr '[:upper:]' '[:lower:]')
            if [[ "$base_name" != "$lower_name" ]]; then
                local new_path="${configs_dir}/${lower_name}.config"
                log_info "  - 重命名配置文件: $config_file -> $new_path"
                mv "$config_file" "$new_path"
                ((renamed_count++))
            fi
        done < <(find "$configs_dir" -maxdepth 1 -name "*.config")
    else
        log_warning "configs目录不存在，跳过配置文件标准化。"
    fi

    # 2. 标准化 scripts 目录下的 .sh 文件
    local scripts_dir="${BASE_DIR}/scripts"
    if [[ -d "$scripts_dir" ]]; then
        while IFS= read -r -d '' script_file; do
            local base_name=$(basename "$script_file" .sh)
            local lower_name=$(echo "$base_name" | tr '[:upper:]' '[:lower:]')
            if [[ "$base_name" != "$lower_name" ]]; then
                local new_path="${scripts_dir}/${lower_name}.sh"
                log_info "  - 重命名脚本文件: $script_file -> $new_path"
                mv "$script_file" "$new_path"
                ((renamed_count++))
            fi
        done < <(find "$scripts_dir" -maxdepth 1 -name "*.sh")
    else
        log_warning "scripts目录不存在，跳过脚本文件标准化。"
    fi

    if [[ $renamed_count -gt 0 ]]; then
        log_success "✅ 项目文件名标准化完成，共重命名 $renamed_count 个文件。"
    else
        log_info "✅ 所有项目文件名已是标准小写，无需操作。"
    fi
}

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

# 对比软件包列表并显示差异 (增强版)
compare_and_show_package_diff() {
    local before_file="$1"
    local after_file="$2"
    local stage_name="$3"
    
    # 确保文件存在
    [[ -f "$before_file" ]] || touch "$before_file"
    [[ -f "$after_file" ]] || touch "$after_file"
    
    echo -e "\n${COLOR_BLUE}📊 ${stage_name} Luci软件包对比结果：${COLOR_RESET}"
    print_separator
    
    local before_count=$(wc -l < "$before_file" 2>/dev/null || echo "0")
    local after_count=$(wc -l < "$after_file" 2>/dev/null || echo "0")
    echo -e "${COLOR_CYAN}补全前软件包数量：${before_count}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}补全后软件包数量：${after_count}${COLOR_RESET}"
    
    # 找出在补全后新增的软件包
    local added_file=$(mktemp)
    comm -13 "$before_file" "$after_file" > "$added_file"
    echo -e "\n${COLOR_GREEN}✅ 新增的软件包 (由依赖自动引入)：${COLOR_RESET}"
    if [[ -s "$added_file" ]]; then
        echo -e "${COLOR_YELLOW}文件名列表：${COLOR_RESET}"
        cat "$added_file" | sed 's/^/  - /'
        echo -e "\n${COLOR_YELLOW}详细信息：${COLOR_RESET}"
        while IFS= read -r package; do
            echo -e "  ${COLOR_CYAN}📦 $package${COLOR_RESET}"
            # 尝试获取软件包描述
            if ./scripts/feeds info "$package" 2>/dev/null | grep -A 5 "Description:" | sed 's/^/    /'; then
                echo ""
            fi
        done < "$added_file"
    else
        echo -e "  - 无"
    fi
    
    # 找出在补全后消失的软件包 (通常因为依赖不满足)
    local removed_file=$(mktemp)
    comm -23 "$before_file" "$after_file" > "$removed_file"
    echo -e "\n${COLOR_RED}❌ 移除的软件包 (因依赖不满足)：${COLOR_RESET}"
    if [[ -s "$removed_file" ]]; then
        echo -e "${COLOR_YELLOW}文件名列表：${COLOR_RESET}"
        cat "$removed_file" | sed 's/^/  - /'
        echo -e "\n${COLOR_YELLOW}详细信息：${COLOR_RESET}"
        while IFS= read -r package; do
            echo -e "  ${COLOR_RED}📦 $package${COLOR_RESET}"
            # 尝试获取软件包信息和依赖
            echo -e "    ${COLOR_YELLOW}尝试获取软件包信息...${COLOR_RESET}"
            if ./scripts/feeds info "$package" 2>/dev/null > /dev/null; then
                echo -e "    ${COLOR_GREEN}✅ 软件包存在于feeds中${COLOR_RESET}"
                # 显示依赖
                local deps=$(./scripts/feeds info "$package" 2>/dev/null | grep "Depends:" | sed 's/Depends://' || echo "无明确依赖信息")
                if [[ -n "$deps" && "$deps" != "无明确依赖信息" ]]; then
                    echo -e "    ${COLOR_CYAN}🔗 依赖项：${COLOR_RESET}"
                    for dep in $deps; do
                        # 清理依赖名称
                        dep=$(echo "$dep" | sed 's/[<>=].*//' | sed 's/^+//')
                        if [[ -n "$dep" && "$dep" != "@@" ]]; then
                            # 检查依赖是否满足
                            if grep -q "^CONFIG_PACKAGE_${dep}=y" .config 2>/dev/null; then
                                echo -e "      ${COLOR_GREEN}✅ $dep (已满足)${COLOR_RESET}"
                            else
                                echo -e "      ${COLOR_RED}❌ $dep (未满足)${COLOR_RESET}"
                            fi
                        fi
                    done
                fi
            else
                echo -e "    ${COLOR_RED}❌ 软件包不存在于feeds中${COLOR_RESET}"
            fi
            echo ""
        done < "$removed_file"
    else
        echo -e "  - 无"
    fi
    
    rm -f "$added_file" "$removed_file"
}

# 安全执行命令函数 (增强版)
safe_execute() {
    local description="$1"
    shift
    local command=("$@")
    local log_file="${LOG_DIR}/${REPO_SHORT}-${description}.log"
    
    mkdir -p "$LOG_DIR"
    
    log_info "🔄 执行命令: ${command[*]}"
    log_info "📋 详细日志: $log_file"
    
    # 创建临时文件来捕获输出
    local temp_output=$(mktemp)
    local exit_code=0
    
    # 执行命令并捕获输出
    "${command[@]}" > "$temp_output" 2>&1 || exit_code=$?
    
    # 同时输出到控制台和日志文件
    tee -a "$log_file" < "$temp_output"
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "✅ 命令执行成功: $description"
    else
        # 高亮显示错误
        echo -e "\n${COLOR_RED}========================================${COLOR_RESET}"
        echo -e "${COLOR_RED}❌ 命令执行失败${COLOR_RESET}"
        echo -e "${COLOR_RED}========================================${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}命令: ${command[*]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}退出码: $exit_code${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}日志文件: $log_file${COLOR_RESET}"
        echo -e "${COLOR_RED}========================================${COLOR_RESET}"
        
        # 显示错误输出的最后20行
        echo -e "\n${COLOR_RED}错误输出 (最后20行)：${COLOR_RESET}"
        tail -n 20 "$temp_output" | while IFS= read -r line; do
            echo -e "${COLOR_RED}$line${COLOR_RESET}"
        done
        echo -e "${COLOR_RED}========================================${COLOR_RESET}"
        
        log_warning "⚠️ 命令执行失败 (退出码: $exit_code): $description"
        log_warning "📋 详细日志: $log_file"
    fi
    
    rm -f "$temp_output"
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
# 新增：软件包依赖检查和强制保留函数 (增强版)
# =============================================================================

# 检查并强制保留用户指定的软件包
# 参数:
#   $1 - 阶段标识 (base, pro, max, ultra)
check_and_enforce_package_dependencies() {
    local stage="$1"
    log_info "🔍 检查${stage}配置的软件包依赖并强制保留用户指定软件包..."
    print_separator
    
    # 1. 提取补全前的luci软件包（用户需要的软件包）
    local before_file="${LOG_DIR}/${REPO_SHORT}-${stage}-before-defconfig.txt"
    extract_luci_packages ".config" "$before_file"
    
    # 2. 创建用户需要的软件包列表（强制保留）
    local required_packages_file="${LOG_DIR}/${REPO_SHORT}-${stage}-required-packages.txt"
    cp "$before_file" "$required_packages_file"
    
    # 显示用户需要的软件包列表
    if [[ -s "$required_packages_file" ]]; then
        echo -e "\n${COLOR_BLUE}📋 用户需要的Luci软件包列表：${COLOR_RESET}"
        while IFS= read -r package; do
            echo -e "  ${COLOR_CYAN}📦 $package${COLOR_RESET}"
        done < "$required_packages_file"
        echo ""
    fi
    
    # 3. 首次运行 make defconfig 补全依赖
    log_info "🔄 首次运行 'make defconfig' 补全配置依赖..."
    local defconfig_log="${LOG_DIR}/${REPO_SHORT}-${stage}-defconfig.log"
    
    # 使用safe_execute来执行defconfig，以便高亮显示错误
    if safe_execute "${stage}-defconfig" make defconfig; then
        log_success "✅ ${stage}配置首次补全成功"
    else
        log_error "❌ ${stage}配置首次补全失败"
        log_error "📋 错误详情 (最后20行):"
        tail -n 20 "$defconfig_log" >&2
        log_error "📋 完整日志: $defconfig_log"
        return 1
    fi
    
    # 4. 检查是否有用户需要的软件包被移除
    local after_file="${LOG_DIR}/${REPO_SHORT}-${stage}-after-defconfig.txt"
    extract_luci_packages ".config" "$after_file"
    
    local removed_file=$(mktemp)
    comm -23 "$required_packages_file" "$after_file" > "$removed_file"
    
    if [[ -s "$removed_file" ]]; then
        # 高亮显示警告
        echo -e "\n${COLOR_RED}========================================${COLOR_RESET}"
        echo -e "${COLOR_RED}⚠️ 检测到用户需要的软件包被移除${COLOR_RESET}"
        echo -e "${COLOR_RED}========================================${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}阶段: ${stage}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}被移除的软件包数量: $(wc -l < "$removed_file")${COLOR_RESET}"
        echo -e "${COLOR_RED}========================================${COLOR_RESET}"
        
        log_warning "⚠️ 检测到 ${stage} 配置中有用户需要的软件包被移除"
        log_warning "📋 被移除的软件包列表："
        cat "$removed_file" | sed 's/^/  - /'
        
        # 5. 尝试强制恢复被移除的软件包并添加其依赖
        log_info "🔧 尝试强制恢复被移除的软件包并添加其依赖..."
        local fix_log="${LOG_DIR}/${REPO_SHORT}-${stage}-force-restore-packages.log"
        local error_report="${LOG_DIR}/${REPO_SHORT}-${stage}-dependency-errors.log"
        local restored_count=0
        local failed_count=0
        
        # 初始化错误报告
        cat > "$error_report" << EOF
===============================================================================
 ${stage} 配置软件包依赖错误报告
生成时间: $(date)
仓库: $REPO_URL ($REPO_BRANCH)
===============================================================================

EOF
        
        while IFS= read -r package; do
            echo -e "\n${COLOR_YELLOW}🔧 处理软件包: $package${COLOR_RESET}"
            echo "" >> "$error_report"
            echo "处理软件包: $package" >> "$error_report"
            echo "----------------------------------------" >> "$error_report"
            
            # 强制启用软件包
            echo "CONFIG_PACKAGE_${package}=y" >> .config
            
            # 尝试查找并添加依赖
            log_info "    🔍 查找软件包 $package 的依赖..."
            local deps_found=false
            
            # 方法1: 尝试从feeds信息中获取依赖
            if ./scripts/feeds info "$package" > "${LOG_DIR}/${REPO_SHORT}-${stage}-${package}-info.log" 2>&1; then
                log_info "    📋 获取软件包信息成功"
                deps_found=true
                
                # 提取依赖项
                local deps=$(grep "Depends:" "${LOG_DIR}/${REPO_SHORT}-${stage}-${package}-info.log" | sed 's/Depends://')
                if [[ -n "$deps" ]]; then
                    log_info "    🔗 发现依赖: $deps"
                    echo "发现的依赖: $deps" >> "$error_report"
                    
                    # 尝试添加依赖
                    for dep in $deps; do
                        # 清理依赖名称（移除版本要求等）
                        dep=$(echo "$dep" | sed 's/[<>=].*//' | sed 's/^+//')
                        if [[ -n "$dep" && "$dep" != "@@" ]]; then
                            log_info "      - 尝试添加依赖: $dep"
                            echo "尝试添加依赖: $dep" >> "$error_report"
                            
                            # 检查依赖是否是软件包
                            if ./scripts/feeds list "$dep" > /dev/null 2>&1; then
                                echo "CONFIG_PACKAGE_${dep}=y" >> .config
                                log_success "        ✅ 依赖 $dep 已添加"
                                echo "  结果: 成功添加" >> "$error_report"
                            else
                                log_warning "        ❌ 依赖 $dep 不是软件包或不存在"
                                echo "  结果: 不是软件包或不存在" >> "$error_report"
                            fi
                        fi
                    done
                else
                    log_info "    ℹ️ 未找到明确的依赖信息"
                    echo "未找到明确的依赖信息" >> "$error_report"
                fi
            else
                log_warning "    ❌ 无法获取软件包信息"
                echo "无法获取软件包信息" >> "$error_report"
                echo "错误详情:" >> "$error_report"
                cat "${LOG_DIR}/${REPO_SHORT}-${stage}-${package}-info.log" >> "$error_report"
            fi
            
            # 方法2: 尝试安装软件包（这会自动处理依赖）
            log_info "    🔄 尝试安装软件包及其依赖..."
            if ./scripts/feeds install "$package" >> "$fix_log" 2>&1; then
                log_success "    ✅ 软件包 $package 安装成功"
                echo "Feeds安装结果: 成功" >> "$error_report"
                deps_found=true
            else
                log_warning "    ❌ 软件包 $package 安装失败"
                echo "Feeds安装结果: 失败" >> "$error_report"
                echo "错误详情:" >> "$error_report"
                tail -n 20 "${LOG_DIR}/${REPO_SHORT}-${stage}-${package}-install.log" >> "$error_report" 2>/dev/null || true
            fi
            
            # 再次运行 defconfig 检查是否修复成功
            log_info "    🔄 再次运行 defconfig 检查..."
            if make defconfig >> "$fix_log" 2>&1; then
                # 检查软件包是否被保留
                if grep -q "^CONFIG_PACKAGE_${package}=y" .config; then
                    log_success "    ✅ 软件包 $package 强制恢复成功"
                    echo "最终结果: 成功恢复" >> "$error_report"
                    ((restored_count++))
                else
                    # 高亮显示失败
                    echo -e "\n${COLOR_RED}❌ 软件包 $package 恢复失败${COLOR_RESET}"
                    echo "    📋 软件包信息日志: ${LOG_DIR}/${REPO_SHORT}-${stage}-${package}-info.log"
                    echo "    📋 修复日志: $fix_log"
                    
                    log_error "    ❌ 软件包 $package 仍然被移除"
                    echo "最终结果: 恢复失败" >> "$error_report"
                    
                    # 添加到错误报告
                    echo "错误详情:" >> "$error_report"
                    echo "  软件包信息日志: ${LOG_DIR}/${REPO_SHORT}-${stage}-${package}-info.log" >> "$error_report"
                    echo "  修复日志: $fix_log" >> "$error_report"
                    
                    # 尝试获取更多错误信息
                    echo "defconfig输出中的相关错误:" >> "$error_report"
                    grep -i "$package" "$defconfig_log" | tail -n 10 >> "$error_report" 2>/dev/null || echo "未找到相关错误信息" >> "$error_report"
                    
                    ((failed_count++))
                fi
            else
                # 高亮显示错误
                echo -e "\n${COLOR_RED}❌ 软件包 $package 修复过程中出错${COLOR_RESET}"
                log_error "    ❌ 软件包 $package 修复过程中出错"
                echo "最终结果: 修复过程出错" >> "$error_report"
                echo "defconfig错误:" >> "$error_report"
                tail -n 20 "$fix_log" >> "$error_report"
                ((failed_count++))
            fi
        done < "$removed_file"
        
        # 6. 输出恢复结果摘要
        if [[ $restored_count -gt 0 ]]; then
            log_success "✅ 成功恢复 $restored_count 个软件包"
        fi
        
        if [[ $failed_count -gt 0 ]]; then
            # 高亮显示错误摘要
            echo -e "\n${COLOR_RED}========================================${COLOR_RESET}"
            echo -e "${COLOR_RED}软件包依赖错误摘要${COLOR_RESET}"
            echo -e "${COLOR_RED}========================================${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}阶段: ${stage}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}失败软件包数量: ${failed_count}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}详细错误日志: ${error_report}${COLOR_RESET}"
            echo -e "${COLOR_RED}========================================${COLOR_RESET}"
            
            log_error "❌ 未能恢复 $failed_count 个软件包"
            log_error "📋 详细错误报告: $error_report"
            
            # 将错误报告添加到全局错误日志
            cat "$error_report" >> "${LOG_DIR}/dependency-errors.log"
            
            # 如果有失败的软件包，返回错误状态
            return 1
        fi
        
        # 7. 重新提取补全后的软件包列表
        extract_luci_packages ".config" "$after_file"
        
        # 8. 最终对比并显示差异
        log_info "📊 修复后的软件包对比："
        compare_and_show_package_diff "$required_packages_file" "$after_file" "${stage} (最终)"
    else
        log_success "✅ ${stage}配置中所有用户需要的软件包均保留"
    fi
    
    rm -f "$removed_file"
    log_success "✅ ${stage}配置软件包依赖检查完成"
    return 0
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    # --- 修改点：在脚本开始时执行标准化 ---
    standardize_project_filenames
    
    # 初始化全局错误日志
    mkdir -p "${LOG_DIR}"
    echo "OpenWrt 构建软件包依赖错误日志" > "${LOG_DIR}/dependency-errors.log"
    echo "生成时间: $(date)" >> "${LOG_DIR}/dependency-errors.log"
    echo "========================================" >> "${LOG_DIR}/dependency-errors.log"
    echo "" >> "${LOG_DIR}/dependency-errors.log"

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

# 格式化配置文件并补全依赖 (修改版)
# 参数:
#   $1 - 阶段标识 (base, pro, max, ultra)
format_and_defconfig() {
    local stage="$1"
    log_info "🎨 格式化${stage}配置文件并补全依赖..."
    
    # 使用新的依赖检查和强制保留函数
    if ! check_and_enforce_package_dependencies "$stage"; then
        log_error "❌ ${stage}配置软件包依赖处理失败，但继续执行构建"
        # 注意：这里不退出，而是继续执行，但记录错误
    fi
    
    log_success "✅ ${stage}配置文件处理完成"
}

# =============================================================================
# 阶段一：准备基础环境
# =============================================================================

prepare_base_environment() {
    log_info "🚀 [阶段一] 开始为分支 ${REPO_SHORT} 准备基础环境..."
    show_system_resources
    mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}" "${LOG_DIR}"
    
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
        
        # 显示最终软件包列表
        echo -e "\n${COLOR_BLUE}📋 最终Luci软件包列表：${COLOR_RESET}"
        while IFS= read -r package; do
            echo -e "  ${COLOR_CYAN}📦 $package${COLOR_RESET}"
        done < "$final_luci_file"
    else
        echo -e "${COLOR_YELLOW}⚠️ 未找到Luci软件包${COLOR_RESET}"
    fi
    print_step_result "Luci软件包列表记录完成"
    
    # 步骤4: 编译固件
    print_step_title "步骤4: 编译固件"
    log_info "🔥 开始编译固件..."
    local build_start_time=$(date +%s)
    
    # 使用safe_execute来执行编译，以便高亮显示错误
    if safe_execute "${CONFIG_LEVEL}-build" make -j$(nproc); then
        local build_end_time=$(date +%s)
        local build_duration=$((build_end_time - build_start_time))
        local build_hours=$((build_duration / 3600))
        local build_minutes=$(((build_duration % 3600) / 60))
        echo -e "\n${COLOR_BLUE}📋 编译摘要：${COLOR_RESET}"
        echo -e "${COLOR_GREEN}✅ 编译成功${COLOR_RESET}"
        echo -e "${COLOR_CYAN}编译耗时：${build_hours}小时${build_minutes}分钟${COLOR_RESET}"
        print_step_result "固件编译完成"
    else
        # 高亮显示编译失败
        echo -e "\n${COLOR_RED}========================================${COLOR_RESET}"
        echo -e "${COLOR_RED}❌ 编译失败${COLOR_RESET}"
        echo -e "${COLOR_RED}========================================${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}日志文件: ${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-make-build.log${COLOR_RESET}"
        echo -e "${COLOR_RED}========================================${COLOR_RESET}"
        
        log_error "❌ 编译失败!"
        tail -n 1000 "${LOG_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-make-build.log" >> "${LOG_DIR}/error.log"
        exit 1
    fi
    
    # 步骤5: 处理产出物
    print_step_title "步骤5: 处理产出物"
    process_artifacts
    print_step_result "产出物处理完成"
    
    # 检查是否有依赖错误
    if [[ -f "${LOG_DIR}/dependency-errors.log" && -s "${LOG_DIR}/dependency-errors.log" ]]; then
        # 高亮显示依赖错误
        echo -e "\n${COLOR_RED}========================================${COLOR_RESET}"
        echo -e "${COLOR_RED}⚠️ 检测到软件包依赖错误${COLOR_RESET}"
        echo -e "${COLOR_RED}========================================${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}详细日志: ${LOG_DIR}/dependency-errors.log${COLOR_RESET}"
        echo -e "${COLOR_RED}========================================${COLOR_RESET}"
        
        log_error "❌ 检测到软件包依赖错误，请查看日志: ${LOG_DIR}/dependency-errors.log"
        # 将错误日志作为构建产物上传
        cp "${LOG_DIR}/dependency-errors.log" "${OUTPUT_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}-dependency-errors.log"
    fi
    
    cleanup_temp_files
    show_system_resources
    log_success "✅ 固件 ${REPO_SHORT}-${CONFIG_LEVEL} 编译完成"
}

# =============================================================================
# 修改点：产出物处理
# =============================================================================

process_artifacts() {
    log_info "📦 处理产出物..."
    local temp_dir="${OUTPUT_DIR}/${REPO_SHORT}-${CONFIG_LEVEL}"
    mkdir -p "$temp_dir"
    
    # 复制错误日志（如果存在）
    if [[ -f "${LOG_DIR}/dependency-errors.log" && -s "${LOG_DIR}/dependency-errors.log" ]]; then
        cp "${LOG_DIR}/dependency-errors.log" "${temp_dir}/${REPO_SHORT}-${CONFIG_LEVEL}-dependency-errors.log"
        log_info "📋 已包含软件包依赖错误日志"
    fi
    
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
            local new_name="${REPO_SHORT}-${SOC_NAME}-${device}-sysupgrade-${CONFIG_LEVEL}.ini"
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
