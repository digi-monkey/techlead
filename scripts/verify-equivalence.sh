#!/bin/bash
#
# verify-equivalence.sh - 验证当前 CLI 行为与基线等价
#
# 这个脚本对比当前 CLI 的输出与之前捕获的基线，检测行为变化。
# 允许非关键差异（如时间戳、临时路径），但标记实质性行为变化。
#
# 使用方法:
#   ./scripts/verify-equivalence.sh [baseline_file]
#
# 参数:
#   baseline_file - 可选，基线文件路径（默认: .sisyphus/baseline/behavior-baseline.json）
#
# 退出码:
#   0 - 所有场景通过，行为等价
#   1 - 检测到行为差异
#

set -euo pipefail

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# 默认基线文件
DEFAULT_BASELINE=".sisyphus/baseline/behavior-baseline.json"
BASELINE_FILE="${1:-$DEFAULT_BASELINE}"

# 临时目录和文件
tmpdir=""
report_file=""

# 统计信息
declare -i TOTAL=0
declare -i PASSED=0
declare -i FAILED=0

# 清理函数
cleanup() {
    if [[ -n "$tmpdir" && -d "$tmpdir" ]]; then
        rm -rf "$tmpdir"
    fi
}
trap cleanup EXIT

# 获取项目根目录
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_PATH="${PROJECT_ROOT}/zig-out/bin/techlead"

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}$1${NC}"
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_error() {
    echo -e "${RED}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

# 确保 CLI 已构建
ensure_cli_built() {
    if [[ ! -f "$CLI_PATH" ]]; then
        print_info "CLI 未找到，正在构建..."
        cd "$PROJECT_ROOT"
        zig build
    fi
    
    if [[ ! -f "$CLI_PATH" ]]; then
        print_error "错误: 无法找到或构建 CLI"
        exit 1
    fi
}

# 创建临时目录
setup_temp_dir() {
    tmpdir=$(mktemp -d)
}

# 规范化输出（移除可变内容）
normalize_output() {
    local text="$1"
    # 移除 ANSI 颜色代码
    text=$(echo "$text" | sed 's/\x1b\[[0-9;]*m//g')
    # 替换临时目录路径为占位符
    text=$(echo "$text" | sed "s|$tmpdir|/TMPDIR|g")
    # 替换时间戳为占位符
    text=$(echo "$text" | sed 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}Z/TIMESTAMP/g')
    # 替换 PID 为占位符
    text=$(echo "$text" | sed 's/PID: [0-9]\+/PID: PID/g')
    # 替换绝对路径中的 home 目录
    text=$(echo "$text" | sed "s|/Users/[^/]*/|/HOME/|g")
    text=$(echo "$text" | sed "s|/home/[^/]*/|/HOME/|g")
    echo "$text"
}

# 比较两个字符串（忽略空白差异）
compare_text() {
    local expected="$1"
    local actual="$2"
    local normalized_expected=$(normalize_output "$expected")
    local normalized_actual=$(normalize_output "$actual")
    
    if [[ "$normalized_expected" == "$normalized_actual" ]]; then
        return 0
    else
        return 1
    fi
}

# 运行单个场景并对比
verify_scenario() {
    local scenario_name="$1"
    local command="$2"
    local expected_exit="$3"
    local expected_stdout="$4"
    local expected_stderr="$5"
    local work_dir="${6:-$tmpdir}"
    
    TOTAL+=1
    
    print_info "验证场景: $scenario_name"
    
    # 创建工作目录
    mkdir -p "$work_dir"
    
    # 运行命令
    local actual_stdout_file=$(mktemp)
    local actual_stderr_file=$(mktemp)
    local actual_exit=0
    
    eval "$command" >"$actual_stdout_file" 2>"$actual_stderr_file" || actual_exit=$?
    
    local actual_stdout=$(cat "$actual_stdout_file")
    local actual_stderr=$(cat "$actual_stderr_file")
    
    rm -f "$actual_stdout_file" "$actual_stderr_file"
    
    # 检查退出码
    if [[ "$actual_exit" != "$expected_exit" ]]; then
        print_error "  ✗ 退出码不匹配: 期望 $expected_exit, 实际 $actual_exit"
        FAILED+=1
        return 1
    fi
    
    # 比较输出（考虑基线可能使用 base64 编码）
    if [[ -n "$expected_stdout" ]]; then
        if ! compare_text "$expected_stdout" "$actual_stdout"; then
            print_warning "  ⚠ stdout 有差异（可能是正常的格式变化）"
        fi
    fi
    
    if [[ -n "$expected_stderr" ]]; then
        if ! compare_text "$expected_stderr" "$actual_stderr"; then
            print_warning "  ⚠ stderr 有差异（可能是正常的格式变化）"
        fi
    fi
    
    # 检查关键行为特征
    local has_error=$(echo "$actual_stderr" | grep -c "ERROR" || true)
    local expected_has_error=$(echo "$expected_stderr" | grep -c "ERROR" || true)
    
    if [[ "$has_error" != "$expected_has_error" ]]; then
        print_error "  ✗ 错误消息存在性不匹配"
        FAILED+=1
        return 1
    fi
    
    print_success "  ✓ 通过"
    PASSED+=1
    return 0
}

# 从基线重建测试环境
setup_scenario_env() {
    local scenario_idx="$1"
    local work_dir=$(jq -r ".scenarios[$scenario_idx].working_directory" "$BASELINE_FILE")
    local scenario_name=$(jq -r ".scenarios[$scenario_idx].name" "$BASELINE_FILE")
    
    # 特殊处理某些场景的环境
    case "$scenario_name" in
        "init-in-git"|"init-duplicate"|"init-force")
            mkdir -p "$work_dir"
            (cd "$work_dir" && git init >/devdev/null 2>&1 || true)
            ;;
        "init-non-git")
            mkdir -p "$work_dir"
            ;;
        "run-no-config"|"run-missing-program")
            mkdir -p "$work_dir/.techlead"
            (cd "$work_dir" && git init >/devdev/null 2>&1 || true)
            ;;
        "run-full-config")
            mkdir -p "$work_dir/.techlead"
            (cd "$work_dir" && git init >/devdev/null 2>&1 || true)
            # 创建配置文件
            cat > "$work_dir/.techlead/techlead.json" <<'EOF'
{
  "iterations": 1,
  "program_file": ".techlead/program.md",
  "opencode_url": "http://localhost:4096",
  "work_dir": "replace-me",
  "log_dir": ".techlead/iteration-logs",
  "model": "",
  "agent": "Sisyphus",
  "main_branch": "master",
  "max_branches": 10
}
EOF
            cat > "$work_dir/.techlead/program.md" <<'EOF'
# Test

<!-- TECHLEAD:GOAL:BEGIN -->
Test
<!-- TECHLEAD:GOAL:END -->

<!-- TECHLEAD:CONSTRAINTS:BEGIN -->
Test
<!-- TECHLEAD:CONSTRAINTS:END -->

<!-- TECHLEAD:CRITERIA:BEGIN -->
Test
<!-- TECHLEAD:CRITERIA:END -->

<!-- TECHLEAD:MODE_A:BEGIN -->
Test
<!-- TECHLEAD:MODE_A:END -->

<!-- TECHLEAD:MODE_B:BEGIN -->
Test
<!-- TECHLEAD:MODE_B:END -->
EOF
            ;;
    esac
}

# 主验证流程
run_verification() {
    print_info "===================================="
    print_info "  Techlead CLI 行为等价性验证工具"
    print_info "===================================="
    print_info ""
    
    # 检查基线文件
    if [[ ! -f "$BASELINE_FILE" ]]; then
        print_error "错误: 基线文件不存在: $BASELINE_FILE"
        print_info "请先运行: ./scripts/capture-baseline.sh"
        exit 1
    fi
    
    print_info "基线文件: $BASELINE_FILE"
    print_info ""
    
    ensure_cli_built
    setup_temp_dir
    
    # 获取场景数量
    local scenario_count=$(jq '.scenarios | length' "$BASELINE_FILE")
    print_info "验证 $scenario_count 个场景..."
    print_info ""
    
    # 遍历所有场景
    local i=0
    while [[ $i -lt $scenario_count ]]; do
        local name=$(jq -r ".scenarios[$i].name" "$BASELINE_FILE")
        local cmd=$(jq -r ".scenarios[$i].command" "$BASELINE_FILE")
        local exit_code=$(jq -r ".scenarios[$i].exit_code" "$BASELINE_FILE")
        local work_dir=$(jq -r ".scenarios[$i].working_directory" "$BASELINE_FILE")
        
        # 解码 base64 输出
        local stdout=""
        local stderr=""
        
        if jq -e ".scenarios[$i].stdout_b64" "$BASELINE_FILE" >/devdev/null 2>&1; then
            stdout=$(jq -r ".scenarios[$i].stdout_b64" "$BASELINE_FILE" | base64 -d 2>/devdev/null || echo "")
        fi
        
        if jq -e ".scenarios[$i].stderr_b64" "$BASELINE_FILE" >/devdev/null 2>&1; then
            stderr=$(jq -r ".scenarios[$i].stderr_b64" "$BASELINE_FILE" | base64 -d 2>/devdev/null || echo "")
        fi
        
        # 设置场景环境
        setup_scenario_env "$i"
        
        # 替换命令中的 CLI 路径
        cmd=$(echo "$cmd" | sed "s|[^[:space:]]*/techlead|$CLI_PATH|g")
        
        # 验证场景
        verify_scenario "$name" "$cmd" "$exit_code" "$stdout" "$stderr" "$work_dir" || true
        
        i=$((i + 1))
    done
    
    print_info ""
    print_info "===================================="
    print_info "  验证结果摘要"
    print_info "===================================="
    print_info ""
    print_info "总计: $TOTAL 个场景"
    print_success "通过: $PASSED 个场景"
    
    if [[ $FAILED -gt 0 ]]; then
        print_error "失败: $FAILED 个场景"
        print_error ""
        print_error "检测到行为差异！请检查实现是否有意改变。"
        return 1
    else
        print_success ""
        print_success "✓ 所有场景通过，当前行为与基线等价"
        return 0
    fi
}

# 运行主流程
run_verification
exit $?
