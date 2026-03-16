#!/usr/bin/env bash
# sync/verify/check_upstream_drift.sh — 上游变更漂移检测
#
# 功能:
#   1. 读取 sync/config/upstream.yaml 中记录的 last_synced_commit
#   2. 检测上游仓库（Redpanda-data/ 子目录）自上次同步以来的新增提交
#   3. 列出变更文件清单
#   4. 标记含有 PROTECTED 模式的文件（需人工审查后再 cherry-pick）
#   5. 输出结构化 Markdown 报告供人工决策
#
# 前置条件:
#   - Redpanda-data/redpanda、connect、console 目录已是 git 仓库
#   - upstream.yaml 中的 last_synced_commit 已填写
#
# 用法:
#   bash sync/verify/check_upstream_drift.sh [--project <rtmessage|rtconnect|rtconsole|all>]
#                                             [--repo-root <path>]
#                                             [--output-dir <path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── 解析参数 ──────────────────────────────────────────────────────────────────
PROJECT="all"
REPO_ROOT=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)    PROJECT="$2";    shift 2 ;;
        --repo-root)  REPO_ROOT="$2";  shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -18 | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$REPO_ROOT" ]]  && REPO_ROOT="$(cd "${SYNC_ROOT}/.." && pwd)"
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="${SYNC_ROOT}/reports"

mkdir -p "$OUTPUT_DIR"

DRIFT_REPORT="${OUTPUT_DIR}/upstream_drift.md"

# ── YAML 简单读取函数（不依赖 yq/python，仅做基础解析）────────────────────────
# 警告：这是一个极简解析器，仅支持简单 key: value 格式，不支持嵌套和注释行
yaml_get() {
    local file="$1"
    local key="$2"
    grep -A1 "^  ${key}:" "$file" 2>/dev/null | \
        grep -v "^  ${key}:" | \
        grep -oP '(?<=:\s).*' | \
        head -1 | \
        tr -d '"' | \
        sed 's/^[[:space:]]*//' | \
        sed 's/[[:space:]]*$//'
}

# 读取 upstream.yaml 中特定 project 的字段
# 用法: get_upstream_field <project_key> <field>
get_upstream_field() {
    local proj_key="$1"
    local field="$2"
    local file="${SYNC_ROOT}/config/upstream.yaml"

    # 找到项目块后提取字段值
    awk "
        /^  ${proj_key}:/{found=1; next}
        found && /^  [a-z]/ && !/^  ${proj_key}:/{found=0}
        found && /^    ${field}:/{
            gsub(/^    ${field}: */, \"\")
            gsub(/\"/, \"\")
            gsub(/^[[:space:]]+|[[:space:]]+$/, \"\")
            print; exit
        }
    " "$file"
}

# ── PROTECTED 模式（与 protected.yaml 同步）──────────────────────────────────
PROTECTED_PATTERNS=(
    'ApiVersions'
    'JoinGroup'
    'SyncGroup'
    'SaslHandshake'
    'SaslAuthenticate'
    'InitProducerId'
    'TxnOffsetCommit'
    'OffsetForLeaderEpoch'
    '__consumer_offsets'
    '__transaction_state'
    'application/vnd\.kafka'
    'application/vnd\.schemaregistry'
)

# 构建 grep 用的 OR 组合模式
PROTECTED_GREP_PATTERN="$(IFS='|'; echo "${PROTECTED_PATTERNS[*]}")"

# ── 检查单个项目的漂移 ────────────────────────────────────────────────────────
check_project_drift() {
    local proj_key="$1"   # rtmessage | rtconnect | rtconsole
    local proj_label="$2"

    local ref_path
    ref_path="$(get_upstream_field "$proj_key" "local_ref_path")"
    local upstream_dir="${REPO_ROOT}/${ref_path}"

    local last_commit
    last_commit="$(get_upstream_field "$proj_key" "last_synced_commit")"

    echo ""
    echo -e "${BOLD}── ${proj_label} ────────────────────────────────────${NC}"

    # ---- 检查目录是否存在 ----
    if [[ ! -d "$upstream_dir" ]]; then
        echo -e "  ${RED}✗ 目录不存在: ${upstream_dir}${NC}"
        printf "\n### %s\n\n❌ 目录不存在: \`%s\`\n\n" "$proj_label" "$upstream_dir" >> "$DRIFT_REPORT"
        return 1
    fi

    # ---- 检查是否是 git 仓库 ----
    if ! git -C "$upstream_dir" rev-parse HEAD &>/dev/null; then
        echo -e "  ${YELLOW}⚠ 不是 git 仓库: ${upstream_dir}${NC}"
        echo -e "  ${CYAN}提示: 需在此目录下执行 git init 或 git clone${NC}"
        printf "\n### %s\n\n⚠️ 不是 git 仓库: \`%s\`\n不能进行 drift 检测，请先初始化 git 仓库。\n\n" \
            "$proj_label" "$upstream_dir" >> "$DRIFT_REPORT"
        return 0
    fi

    local current_head
    current_head="$(git -C "$upstream_dir" rev-parse HEAD)"
    local current_head_short="${current_head:0:12}"

    echo -e "  当前 HEAD:      ${CYAN}${current_head_short}${NC}"

    # ---- 检查是否已记录同步 commit ----
    if [[ -z "$last_commit" ]]; then
        echo -e "  ${YELLOW}⚠ upstream.yaml 中 last_synced_commit 未填写${NC}"
        echo -e "  ${CYAN}提示: 请在完成首次审计后填写当前 HEAD: ${current_head}${NC}"
        printf "\n### %s\n\n⚠️ \`last_synced_commit\` 未配置\n\n当前 HEAD: \`%s\`\n\n请在首次审计完成后将此 SHA 填入 \`sync/config/upstream.yaml\`。\n\n" \
            "$proj_label" "$current_head" >> "$DRIFT_REPORT"
        return 0
    fi

    echo -e "  上次同步 commit: ${CYAN}${last_commit:0:12}${NC}"

    # ---- 检查 last_commit 是否存在于仓库中 ----
    if ! git -C "$upstream_dir" cat-file -e "${last_commit}^{commit}" 2>/dev/null; then
        echo -e "  ${RED}✗ last_synced_commit 在本地仓库中不存在: ${last_commit:0:12}${NC}"
        printf "\n### %s\n\n❌ \`last_synced_commit\` 不在本地仓库中，请更新 \`Redpanda-data/\` 目录后重试。\n\n" \
            "$proj_label" >> "$DRIFT_REPORT"
        return 1
    fi

    # ---- 统计自上次同步以来的新提交 ----
    local new_commits
    new_commits="$(git -C "$upstream_dir" log --oneline "${last_commit}..HEAD" 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "$new_commits" -eq 0 ]]; then
        echo -e "  ${GREEN}✅ 无新提交，与上游同步${NC}"
        printf "\n### %s\n\n✅ 与上游同步，无新提交。\n\n" "$proj_label" >> "$DRIFT_REPORT"
        return 0
    fi

    echo -e "  ${YELLOW}⚠ 发现 ${new_commits} 个新提交${NC}"

    # ---- 列出变更文件 ----
    local changed_files
    changed_files="$(git -C "$upstream_dir" diff --name-only "${last_commit}..HEAD" 2>/dev/null)"

    local total_files
    total_files="$(echo "$changed_files" | grep -c . || true)"

    local protected_files=()
    local review_files=()
    local safe_files=()

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        abs_path="${upstream_dir}/${f}"

        # 检查文件是否含有 PROTECTED 模式
        if [[ -f "$abs_path" ]] && grep -qiP "$PROTECTED_GREP_PATTERN" "$abs_path" 2>/dev/null; then
            protected_files+=("$f")
        else
            # 简单路径分类
            case "$f" in
                src/v/kafka/protocol/*|src/v/kafka/server/handlers/*|\
                */kafka/protocol_gen/*)
                    review_files+=("$f") ;;
                *.proto|*/proto/*)
                    review_files+=("$f") ;;
                *)
                    safe_files+=("$f") ;;
            esac
        fi
    done <<< "$changed_files"

    # ---- 写入报告 ----
    {
        printf "\n### %s\n\n" "$proj_label"
        printf "| 项目 | 值 |\n|------|----|\n"
        printf "| 当前 HEAD | \`%s\` |\n" "$current_head_short"
        printf "| 上次同步 | \`%s\` |\n" "${last_commit:0:12}"
        printf "| 新增提交数 | %d |\n" "$new_commits"
        printf "| 变更文件总数 | %d |\n" "$total_files"
        printf "| 🚫 含 PROTECTED 模式 | %d |\n" "${#protected_files[@]}"
        printf "| ⚠️  需 REVIEW | %d |\n" "${#review_files[@]}"
        printf "| ✅ 可直接同步 | %d |\n\n" "${#safe_files[@]}"

        # 新提交列表
        printf "#### 新提交列表\n\n\`\`\`\n"
        git -C "$upstream_dir" log --oneline "${last_commit}..HEAD" 2>/dev/null | head -50
        printf "\`\`\`\n\n"

        if [[ ${#protected_files[@]} -gt 0 ]]; then
            printf "#### 🚫 含 PROTECTED 模式的变更文件（必须人工审查）\n\n"
            printf "以下文件修改了含有 Kafka 协议或外部 API 兼容字符串的代码，\n"
            printf "同步前必须人工确认对 RTMessage 的影响。\n\n"
            for f in "${protected_files[@]}"; do
                printf "%s\n" "- \`${f}\`"
            done
            printf "\n"
        fi

        if [[ ${#review_files[@]} -gt 0 ]]; then
            printf "#### ⚠️  需 REVIEW 的变更文件\n\n"
            for f in "${review_files[@]}"; do
                printf "%s\n" "- \`${f}\`"
            done
            printf "\n"
        fi

        if [[ ${#safe_files[@]} -gt 0 ]]; then
            printf "#### ✅ 可直接同步的变更文件\n\n"
            local show_limit=100
            local show_count=0
            for f in "${safe_files[@]}"; do
                (( show_count += 1 ))
                [[ $show_count -gt $show_limit ]] && break
                printf "%s\n" "- \`${f}\`"
            done
            if [[ ${#safe_files[@]} -gt $show_limit ]]; then
                printf "%s\n" "- ... 及其他 $(( ${#safe_files[@]} - show_limit )) 个文件（见完整 git diff）"
            fi
            printf "\n"
        fi

        printf "#### 同步完成后请执行\n\n\`\`\`bash\n"
        printf "# 更新 upstream.yaml 中的 last_synced_commit\n"
        printf "# 将以下 SHA 填入 sync/config/upstream.yaml -> %s -> last_synced_commit:\n" "$proj_key"
        printf "%s\n\`\`\`\n\n" "$current_head"
    } >> "$DRIFT_REPORT"

    # 终端摘要
    echo -e "  变更文件: ${total_files}"
    [[ ${#protected_files[@]} -gt 0 ]] && \
        echo -e "  ${RED}🚫 含 PROTECTED 模式的文件: ${#protected_files[@]} 个（需人工审查）${NC}"
    [[ ${#review_files[@]} -gt 0 ]] && \
        echo -e "  ${YELLOW}⚠  需 REVIEW 文件: ${#review_files[@]} 个${NC}"
    [[ ${#safe_files[@]} -gt 0 ]] && \
        echo -e "  ${GREEN}✅ 可直接同步文件: ${#safe_files[@]} 个${NC}"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         上游漂移检测 (Upstream Drift Check)      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  检测时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo -e "  工作区:   ${REPO_ROOT}"

# 初始化报告文件
{
    printf "# 上游漂移检测报告\n\n"
    printf "生成时间: %s\n\n" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf "工作区: \`%s\`\n\n" "$REPO_ROOT"
    printf "%s\n\n" "---"
    printf "## 各项目检测结果\n"
} > "$DRIFT_REPORT"

case "$PROJECT" in
    rtmessage)
        check_project_drift "rtmessage" "RTMessage (Redpanda C++ 核心)" ;;
    rtconnect)
        check_project_drift "rtconnect" "RTconnect (Redpanda Connect)" ;;
    rtconsole)
        check_project_drift "rtconsole" "RTconsole (Redpanda Console)" ;;
    all)
        check_project_drift "rtmessage" "RTMessage (Redpanda C++ 核心)"
        check_project_drift "rtconnect" "RTconnect (Redpanda Connect)"
        check_project_drift "rtconsole" "RTconsole (Redpanda Console)"
        ;;
    *)
        echo -e "${RED}[错误]${NC} 未知项目: ${PROJECT}" >&2
        echo "  有效值: rtmessage | rtconnect | rtconsole | all" >&2
        exit 1
        ;;
esac

# 追加下一步说明
{
    printf "\n---\n\n## 标准上游同步流程\n\n"
    printf "\`\`\`\n"
    printf "1. 运行本脚本检测 drift\n"
    printf "2. 人工审查含 PROTECTED 模式的变更文件\n"
    printf "3. 对无风险的变更，cherry-pick 到对应 RT* 项目分支\n"
    printf "4. 对有风险的变更，制定专项迁移方案\n"
    printf "5. 更新 sync/config/upstream.yaml 中的 last_synced_commit\n"
    printf "6. 重新运行审计脚本验证改名仍然完整\n"
    printf "\`\`\`\n"
} >> "$DRIFT_REPORT"

echo ""
echo -e "${BOLD}  漂移报告: ${DRIFT_REPORT}${NC}"
echo ""
