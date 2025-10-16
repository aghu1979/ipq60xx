#!/bin/bash
# 企业级日志系统
# 功能：提供结构化日志记录，支持高亮输出和文件记录

# 日志级别
readonly LOG_ERROR=1
readonly LOG_WARN=2
readonly LOG_INFO=3
readonly LOG_SUCCESS=4

# 颜色定义
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_PURPLE='\033[0;35m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_WHITE='\033[1;37m'
readonly COLOR_RESET='\033[0m'

# 日志文件
LOG_DIR="${LOG_DIR:-$(pwd)/logs}"
LOG_FILE="${LOG_DIR}/build-$(date +%Y%m%d).log"

# 初始化日志
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
}

# 记录日志
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local pid=$$     
    case $level in
        $LOG_ERROR)
            echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} ${timestamp} [${pid}] ${message}"
            ;;
        $LOG_WARN)
            echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} ${timestamp} [${pid}] ${message}"
            ;;
        $LOG_INFO)
            echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} ${timestamp} [${pid}] ${message}"
            ;;
        $LOG_SUCCESS)
            echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} ${timestamp} [${pid}] ${message}"
            ;;
    esac
}

# 错误日志
log_error() {
    log $LOG_ERROR "$1"
}

# 警告日志
log_warning() {
    log $LOG_WARN "$1"
}

# 信息日志
log_info() {
    log $LOG_INFO "$1"
}

# 成功日志
log_success() {
    log $LOG_SUCCESS "$1"
}

# 错误处理
handle_error() {
    local line_no=$1
    log_error "脚本在第 ${line_no} 行发生错误!"
    log_error "错误命令: ${BASH_COMMAND}"
    
    # 记录错误上下文
    log_error "错误上下文:"
    tail -n 1000 "$LOG_FILE" >> "${LOG_FILE}.error"
    
    exit 1
}

# 设置错误处理
set -E
trap 'handle_error $LINENO' ERR

# 初始化日志
init_log
