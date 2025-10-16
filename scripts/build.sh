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
    if grep "CONFIG_PACKAGE_luci-app.*=y" "$config_file" | sed 's/CONFIG_PACKAGE_//g; s/=y//g' | sort > "$output_file" 2>/dev/null; then
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
#   3. 更新和安装Feeds
#   4. 安装第三方软件包
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
    log_info "🔄 更新软件源..."
    ./scripts/feeds update -a 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-feeds-update.log"
    
    # 输出feeds更新摘要
    echo -e "\n${COLOR_BLUE}📋 Feeds更新摘要：${COLOR_RESET}"
    if [[ -d "feeds" ]]; then
        echo -e "${COLOR_CYAN}已更新的feeds目录：${COLOR_RESET}"
        ls -la feeds/ | grep '^d' | awk '{print "  - " $9}'
    fi
    
    print_step_result "软件源更新完成"
    
    # 步骤2：安装Feeds
    print_step_title "步骤2：安装软件源"
    log_info "📦 安装软件源..."
    ./scripts/feeds install -a 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-feeds-install.log"
    
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
        # 调用diy.sh脚本，传递分支名称和芯片名称
        # 将输出同时记录到日志文件和控制台
        bash "${BASE_DIR}/scripts/diy.sh" "${REPO_SHORT}" "${SOC_NAME}" 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-diy-base.log"
        
        # 输出DIY脚本执行摘要
        echo -e "\n${COLOR_BLUE}📋 DIY脚本执行摘要：${COLOR_RESET}"
        echo -e "${COLOR_GREEN}✅ DIY脚本执行完成${COLOR_RESET}"
        echo -e "${COLOR_CYAN}详细日志：${LOG_DIR}/${REPO_SHORT}-diy-base.log${COLOR_RESET}"
        
        print_step_result "第三方软件包安装完成"
    else
        echo -e "\n${COLOR_YELLOW}⚠️ 未找到自定义脚本: ${BASE_DIR}/scripts/diy.sh${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}ℹ️ 跳过第三方软件包安装${COLOR_RESET}"
        print_step_result "跳过第三方软件包安装"
    fi
    
    # 步骤4：重新安装Feeds（确保新添加的软件包被安装）
    print_step_title "步骤4：重新安装软件源"
    log_info "📦 重新安装软件源（包含第三方软件包）..."
    ./scripts/feeds install -a 2>&1 | tee "${LOG_DIR}/${REPO_SHORT}-feeds-reinstall.log"
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
    extract_l
