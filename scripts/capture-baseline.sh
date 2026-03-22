#!/bin/bash
#
# capture-baseline.sh - 捕获当前 CLI 行为基线
#
# 这个脚本运行各种 CLI 命令，捕获它们的输出、退出码和行为，
# 并将结果保存为 JSON 格式的基线文件，用于后续的行为等价性验证。
#
# 使用方法:
#   ./scripts/capture-baseline.sh [output_file]
#
# 参数:
#   output_file - 可选，基线文件输出路径（默认: .sisyphus/baseline/behavior-baseline.json）
#
# 输出:
#   JSON 文件包含所有测试场景的命令、退出码、stdout/stderr 关键内容
#

set -euo pipefail

# 颜色定义（用于终端输出）
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# 默认输出路径
DEFAULT_OUTPUT=".sisyphus/baseline/behavior-baseline.json"
OUTPUT_FILE="${1:-$DEFAULT_OUTPUT}"

# 临时目录用于测试
tmpdir=""

# 获取项目根目录
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_PATH="${PROJECT_ROOT}/zig-out/bin/techlead"

# 清理函数
cleanup() {
    if [[ -n "$tmpdir" && -d "$tmpdir" ]]; then
        rm -rf "$tmpdir"
    fi
}
trap cleanup EXIT

# 创建临时目录
tmpdir=$(mktemp -d)
echo -e "${BLUE}使用临时目录: $tmpdir${NC}"

# 确保 CLI 已构建
ensure_cli_built() {
    if [[ ! -f "$CLI_PATH" ]]; then
        echo -e "${YELLOW}CLI 未找到，正在构建...${NC}"
        cd "$PROJECT_ROOT"
        zig build
    fi
    
    if [[ ! -f "$CLI_PATH" ]]; then
        echo -e "${RED}错误: 无法找到或构建 CLI${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}CLI 路径: $CLI_PATH${NC}"
}

# 运行命令并捕获结果
# 参数: $1=场景名称, $2=命令, $3=工作目录(可选)
run_scenario() {
    local scenario_name="$1"
    local cmd="$2"
    local work_dir="${3:-$tmpdir}"
    
    echo -e "${BLUE}执行场景: $scenario_name${NC}"
    
    # 创建临时文件存储输出
    local stdout_file=$(mktemp)
    local stderr_file=$(mktemp)
    
    # 执行命令并捕获结果
    local exit_code=0
    eval "$cmd" >"$stdout_file" 2>"$stderr_file" || exit_code=$?
    
    # 读取输出（限制长度以避免过大的 JSON）
    local stdout=$(cat "$stdout_file" | head -c 8192 | base64 -w0)
    local stderr=$(cat "$stderr_file" | head -c 8192 | base64 -w0)
    
    # 提取关键信息（解码后提取）
    local stdout_text=$(cat "$stdout_file")
    local stderr_text=$(cat "$stderr_file")
    
    # 清理临时文件
    rm -f "$stdout_file" "$stderr_file"
    
    # 构建场景结果
    cat <<EOF
    {
      "name": $(echo "$scenario_name" | jq -Rs .),
      "command": $(echo "$cmd" | jq -Rs .),
      "working_directory": $(echo "$work_dir" | jq -Rs .),
      "exit_code": $exit_code,
      "stdout_b64": "$stdout",
      "stderr_b64": "$stderr",
      "stdout_preview": $(echo "$stdout_text" | head -5 | jq -Rs .),
      "stderr_preview": $(echo "$stderr_text" | head -5 | jq -Rs .),
      "contains_error": $(echo "$stderr_text" | grep -q "ERROR" && echo "true" || echo "false"),
      "contains_success": $(echo "$stdout_text$stderr_text" | grep -qE "(SUCCESS|初始化完成|迭代完成|服务已启动|服务已停止)" && echo "true" || echo "false")
    }
EOF
}

# 生成基线 JSON
generate_baseline() {
    echo "{"
    echo '  "generated_at": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'",'
    echo '  "generator": "capture-baseline.sh",'
    echo '  "version": "1.0",'
    echo '  "cli_path": "'"$CLI_PATH"'",'
    echo '  "scenarios": ['
    
    local scenarios=()
    
    # 场景 1: 无参数运行（显示帮助）
    scenarios+=("$(run_scenario "no-args-help" "$CLI_PATH")")
    echo ","
    
    # 场景 2: --help 参数
    scenarios+=("$(run_scenario "help-flag" "$CLI_PATH --help")")
    echo ","
    
    # 场景 3: -h 参数
    scenarios+=("$(run_scenario "help-short" "$CLI_PATH -h")")
    echo ","
    
    # 场景 4: init 无参数（应该失败）
    scenarios+=("$(run_scenario "init-no-args" "$CLI_PATH init")")
    echo ","
    
    # 场景 5: init 在非 git 目录
    local nongit_dir="$tmpdir/nongit"
    mkdir -p "$nongit_dir"
    scenarios+=("$(run_scenario "init-non-git" "$CLI_PATH init \"test goal\"" "$nongit_dir")")
    echo ","
    
    # 场景 6: init 在 git 目录（应该成功）
    local git_dir="$tmpdir/gitrepo"
    mkdir -p "$git_dir"
    (cd "$git_dir" && git init)
    scenarios+=("$(run_scenario "init-in-git" "$CLI_PATH init \"test goal\"" "$git_dir")")
    echo ","
    
    # 场景 7: init 重复执行（应该失败，文件已存在）
    scenarios+=("$(run_scenario "init-duplicate" "$CLI_PATH init \"another goal\"" "$git_dir")")
    echo ","
    
    # 场景 8: init 强制覆盖
    scenarios+=("$(run_scenario "init-force" "$CLI_PATH init \"updated goal\" --force" "$git_dir")")
    echo ","
    
    # 场景 9: init 带 --dir 参数
    local target_dir="$tmpdir/target"
    mkdir -p "$target_dir"
    (cd "$target_dir" && git init)
    scenarios+=("$(run_scenario "init-with-dir" "$CLI_PATH init --dir $target_dir \"dir goal\"")")
    echo ","
    
    # 场景 10: run 无配置文件
    local empty_dir="$tmpdir/empty"
    mkdir -p "$empty_dir"
    (cd "$empty_dir" && git init)
    scenarios+=("$(run_scenario "run-no-config" "$CLI_PATH run" "$empty_dir")")
    echo ","
    
    # 场景 11: run 有配置文件但无 program.md
    local config_dir="$tmpdir/config-only"
    mkdir -p "$config_dir/.techlead"
    (cd "$config_dir" && git init)
    cat > "$config_dir/.techlead/techlead.json" <<'JSON'
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
JSON
    scenarios+=("$(run_scenario "run-missing-program" "$CLI_PATH run" "$config_dir")")
    echo ","
    
    # 场景 12: run 有配置文件和 program.md（缺少 opencode CLI 会失败）
    local full_dir="$tmpdir/full-config"
    mkdir -p "$full_dir/.techlead"
    (cd "$full_dir" && git init)
    cat > "$full_dir/.techlead/techlead.json" <<'JSON'
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
JSON
    cat > "$full_dir/.techlead/program.md" <<'MARKDOWN'
# Test Program

<!-- TECHLEAD:GOAL:BEGIN -->
Test goal
<!-- TECHLEAD:GOAL:END -->

<!-- TECHLEAD:CONSTRAINTS:BEGIN -->
- Test constraint
<!-- TECHLEAD:CONSTRAINTS:END -->

<!-- TECHLEAD:CRITERIA:BEGIN -->
- Test criteria
<!-- TECHLEAD:CRITERIA:END -->

<!-- TECHLEAD:MODE_A:BEGIN -->
Mode A instructions
<!-- TECHLEAD:MODE_A:END -->

<!-- TECHLEAD:MODE_B:BEGIN -->
Mode B instructions
<!-- TECHLEAD:MODE_B:END -->
MARKDOWN
    scenarios+=("$(run_scenario "run-full-config" "$CLI_PATH run" "$full_dir")")
    echo ","
    
    # 场景 13: server 无子命令
    scenarios+=("$(run_scenario "server-no-subcommand" "$CLI_PATH server")")
    echo ","
    
    # 场景 14: server start（缺少 opencode CLI 会失败）
    scenarios+=("$(run_scenario "server-start" "$CLI_PATH server start")")
    echo ","
    
    # 场景 15: server stop（无运行服务）
    scenarios+=("$(run_scenario "server-stop-no-server" "$CLI_PATH server stop")")
    echo ","
    
    # 场景 16: server 无效子命令
    scenarios+=("$(run_scenario "server-invalid-subcommand" "$CLI_PATH server invalid")")
    echo ","
    
    # 场景 17: run 无效参数
    scenarios+=("$(run_scenario "run-invalid-args" "$CLI_PATH run --invalid-flag")")
    echo ","
    
    # 场景 18: init 无效参数
    scenarios+=("$(run_scenario "init-invalid-args" "$CLI_PATH init --invalid-flag goal")")
    
    echo ""
    echo "  ]"
    echo "}"
}

# 主函数
main() {
    echo -e "${BLUE}====================================${NC}"
    echo -e "${BLUE}  Techlead CLI 行为基线捕获工具${NC}"
    echo -e "${BLUE}====================================${NC}"
    echo ""
    
    # 确保 jq 可用
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}错误: 需要 jq 工具但未找到${NC}"
        echo "请安装 jq: https://stedolan.github.io/jq/download/"
        exit 1
    fi
    
    ensure_cli_built
    
    # 创建输出目录
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    
    echo -e "${BLUE}开始捕获行为基线...${NC}"
    
    # 生成并保存基线
    generate_baseline > "$OUTPUT_FILE"
    
    echo -e "${GREEN}✓ 基线已保存到: $OUTPUT_FILE${NC}"
    
    # 显示摘要
    local scenario_count=$(jq '.scenarios | length' "$OUTPUT_FILE")
    echo -e "${GREEN}✓ 捕获了 $scenario_count 个场景${NC}"
    
    # 统计成功/失败
    local failed_count=$(jq '[.scenarios[] | select(.exit_code != 0)] | length' "$OUTPUT_FILE")
    local success_count=$((scenario_count - failed_count))
    echo -e "${GREEN}  - 预期失败: $failed_count${NC}"
    echo -e "${GREEN}  - 预期成功: $success_count${NC}"
    
    echo ""
    echo -e "${YELLOW}提示: 使用 ./scripts/verify-equivalence.sh 对比当前行为与此基线${NC}"
}

main "$@"
