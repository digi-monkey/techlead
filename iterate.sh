# OpenCode 持续迭代控制脚本
# 用法: ./iterate.sh [迭代次数]
# 默认迭代 20 次

set -euo pipefail

# 配置
ITERATIONS="${1:-20}"
PROGRAM_FILE="${PROGRAM_FILE:-./program.md}"
OPENCODE_URL="${OPENCODE_URL:-http://localhost:4096}"
WORK_DIR="${WORK_DIR:-.}"
LOG_DIR="${LOG_DIR:-./.iteration-logs}"
MODEL="${MODEL:-}"  # 可选: anthropic/claude-3.5-sonnet 等

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 初始化
init() {
    log_info "初始化迭代环境..."
    
    # 检查 program.md 存在
    if [[ ! -f "$PROGRAM_FILE" ]]; then
        log_error "找不到 $PROGRAM_FILE"
        exit 1
    fi
    
    # 创建日志目录
    mkdir -p "$LOG_DIR"
    
    # 检查当前目录是 git 仓库
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "当前目录不是 git 仓库"
        exit 1
    fi
    
    # 确保在 master 分支开始
    if [[ "$(git branch --show-current)" != "master" ]]; then
        log_warn "当前不在 master 分支，切换到 master..."
        git checkout master
    fi
    
    log_success "初始化完成"
    echo ""
}

# 检查 opencode serve 是否可用
check_opencode() {
    log_info "检查 OpenCode server..."
    
    if ! curl -s "$OPENCODE_URL" > /dev/null 2>&1; then
        log_error "无法连接到 OpenCode server at $OPENCODE_URL"
        log_info "请确保 OpenCode serve 正在运行:"
        log_info "  opencode serve"
        log_info "或者指定其他地址:"
        log_info "  OPENCODE_URL=http://localhost:8080 ./iterate.sh"
        exit 1
    fi
    
    log_success "OpenCode server 连接正常"
    echo ""
}

# 获取当前 experiment 分支（如果有）
get_current_experiment_branch() {
    git branch --show-current | grep '^experiment-' || true
}

# 准备 prompt
prepare_prompt() {
    local iteration="$1"
    local experiment_branch="$2"
    
    # 读取 program.md
    local program_content
    program_content=$(cat "$PROGRAM_FILE")
    
    # 构建 prompt
    cat << EOF
=== 系统消息 ===
你是一个代码改进助手。这是第 $iteration 次迭代。

=== 当前状态 ===
- 当前迭代: $iteration / $ITERATIONS
EOF

    if [[ -n "$experiment_branch" ]]; then
        echo "- 当前分支: $experiment_branch（需要评估）"
        echo "- 需要评估这个分支的工作是否值得保留"
    else
        echo "- 当前分支: master（需要开始新的实验）"
        echo "- 需要创建新的 experiment-* 分支进行改进"
    fi
    
    echo ""
    echo "=== program.md 内容 ==="
    echo "$program_content"
    echo ""
    echo "=== 任务指令 ==="
    echo ""
    
    if [[ -n "$experiment_branch" ]]; then
        cat << 'INSTRUCTIONS'
当前有一个 experiment 分支需要评估。

请执行以下操作：
1. 查看当前分支的改动: git diff master..HEAD
2. 根据 program.md 中的评估标准判断这个改动是否有帮助
3. 做出决策并执行：
   - 如果有帮助：执行 `git checkout master && git merge <分支名>`，然后输出 "DECISION: KEEP"
   - 如果没帮助：执行 `git branch -D <分支名>`，然后输出 "DECISION: DISCARD"
4. 简要说明你的判断理由

请直接执行 git 命令，不要只输出命令。
INSTRUCTIONS
    else
        cat << 'INSTRUCTIONS'
当前在 master 分支，需要开始新的实验。

请执行以下操作：
1. 根据 program.md 中的 Goal 和已有工作，提出一个改进想法
2. 创建一个描述性的分支名（如 experiment-optimize-memory）
3. 执行: `git checkout -b experiment-{你的描述}`
4. 实现你的改进想法（编辑代码、添加功能、优化性能等）
5. 执行: `git add . && git commit -m "迭代X: 你的描述"`
6. 输出 "DECISION: EXPERIMENT_CREATED" 和简要的改进说明

注意：不要 merge 到 master，只 commit 到当前分支。
INSTRUCTIONS
    fi
}

# 调用 OpenCode
invoke_opencode() {
    local iteration="$1"
    local prompt="$2"
    local log_file="$LOG_DIR/iteration-$iteration.log"
    local current_branch
    current_branch=$(git branch --show-current)
    
    log_info "第 $iteration 次迭代：调用 OpenCode..."
    log_info "当前分支: $current_branch"
    
    # 构建 opencode run 命令
    local cmd=(opencode run --attach "$OPENCODE_URL")
    
    # 如果指定了模型，添加 --model
    if [[ -n "$MODEL" ]]; then
        cmd+=(--model "$MODEL")
    fi
    
    # 添加 prompt
    cmd+=("$prompt")
    
    # 执行命令并捕获输出
    log_info "执行: ${cmd[*]}"
    
    if ! "${cmd[@]}" 2>&1 | tee "$log_file"; then
        log_error "调用 OpenCode 失败"
        log_info "日志保存在: $log_file"
        return 1
    fi
    
    # 解析决策
    local decision
    decision=$(grep -oE 'DECISION: (KEEP|DISCARD|EXPERIMENT_CREATED)' "$log_file" | head -1 || true)
    
    if [[ -n "$decision" ]]; then
        case "$decision" in
            "DECISION: KEEP")
                log_success "决策: 保留分支"
                ;;
            "DECISION: DISCARD")
                log_warn "决策: 舍弃分支"
                ;;
            "DECISION: EXPERIMENT_CREATED")
                log_success "决策: 创建了新实验分支"
                ;;
        esac
    else
        log_warn "无法解析决策，请查看日志: $log_file"
    fi
    
    return 0
}

# 清理旧的 experiment 分支（可选）
cleanup_old_branches() {
    local max_branches="${MAX_BRANCHES:-10}"
    local branches
    branches=$(git branch --list 'experiment-*' | wc -l)
    
    if [[ $branches -gt $max_branches ]]; then
        log_warn "experiment 分支数量 ($branches) 超过限制 ($max_branches)"
        log_info "清理旧分支..."
        git branch --list 'experiment-*' | head -n -$max_branches | xargs -r git branch -D
    fi
}

# 主循环
main() {
    echo "========================================"
    echo "  OpenCode 持续迭代系统"
    echo "========================================"
    echo ""
    log_info "配置:"
    log_info "  - 迭代次数: $ITERATIONS"
    log_info "  - Program 文件: $PROGRAM_FILE"
    log_info "  - OpenCode URL: $OPENCODE_URL"
    log_info "  - 日志目录: $LOG_DIR"
    if [[ -n "$MODEL" ]]; then
        log_info "  - 模型: $MODEL"
    fi
    echo ""
    
    # 初始化
    init
    check_opencode
    
    # 迭代循环
    for ((i=1; i<=ITERATIONS; i++)); do
        echo "========================================"
        log_info "第 $i / $ITERATIONS 次迭代"
        echo "========================================"
        echo ""
        
        # 获取当前 experiment 分支
        local experiment_branch
        experiment_branch=$(get_current_experiment_branch)
        
        # 准备 prompt
        local prompt
        prompt=$(prepare_prompt "$i" "$experiment_branch")
        
        # 调用 OpenCode
        if ! invoke_opencode "$i" "$prompt"; then
            log_error "第 $i 次迭代失败，跳过..."
            continue
        fi
        
        # 清理旧分支
        cleanup_old_branches
        
        # 显示当前状态
        echo ""
        log_info "当前 git 状态:"
        git branch -v | grep -E '(master|experiment-)' || true
        echo ""
        
        # 短暂休息，避免请求过快
        if [[ $i -lt $ITERATIONS ]]; then
            log_info "等待 2 秒后开始下一次迭代..."
            sleep 2
        fi
        
        echo ""
    done
    
    echo "========================================"
    log_success "迭代完成！"
    echo "========================================"
    echo ""
    log_info "总结:"
    log_info "  - 总迭代次数: $ITERATIONS"
    log_info "  - 日志目录: $LOG_DIR"
    log_info "  - 当前分支: $(git branch --show-current)"
    echo ""
    log_info "保留的 experiment 分支:"
    git branch -v | grep 'experiment-' || log_info "  无"
    echo ""
    log_info "你可以手动评估这些分支，决定最终保留哪些改进。"
}

# 帮助信息
show_help() {
    cat << 'EOF'
OpenCode 持续迭代控制脚本

用法:
    ./iterate.sh [迭代次数]

环境变量:
    ITERATIONS      默认迭代次数 (默认: 20)
    PROGRAM_FILE    program.md 文件路径 (默认: ./program.md)
    OPENCODE_URL    OpenCode server URL (默认: http://localhost:4096)
    WORK_DIR        工作目录 (默认: 当前目录)
    LOG_DIR         日志目录 (默认: ./.iteration-logs)
    MODEL           模型选择 (可选, 如: anthropic/claude-3.5-sonnet)
    MAX_BRANCHES    最大保留分支数 (默认: 10)

示例:
    # 默认 20 次迭代
    ./iterate.sh

    # 指定 50 次迭代
    ./iterate.sh 50

    # 使用自定义配置
    OPENCODE_URL=http://localhost:8080 MODEL=anthropic/claude-3.5-sonnet ./iterate.sh 30

要求:
    1. 当前目录是 git 仓库
    2. OpenCode serve 在指定 URL 运行
       启动命令: opencode serve
    3. opencode CLI 已安装

工作流程:
    1. 脚本检查当前是否有 experiment-* 分支
    2. 如果有：让 AI 评估是否保留（合并或删除）
    3. 如果没有：让 AI 创建新分支并实施改进
    4. 循环直到达到指定迭代次数

日志:
    每次迭代的详细输出保存在 LOG_DIR/iteration-N.log

EOF
}

# 参数处理
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        main
        ;;
esac
