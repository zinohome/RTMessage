#!/usr/bin/env bash
# sync/patch/apply_phase1_rename.sh — 第一阶段改名执行脚本
#
# 默认以 dry-run 模式运行，仅输出 diff，不修改任何文件。
#
# 用法:
#   bash sync/patch/apply_phase1_rename.sh [选项]
#
# 选项:
#   --project <name>    目标项目: rtconsole | rtconnect | rtmessage | all
#                       (默认: all；建议先从 rtconsole 开始验证)
#   --dry-run           只显示变更 diff，不写入文件 (默认)
#   --execute           真实写入。目标目录须预先存在（见下方前提条件）
#   --target-root <dir> 输出根目录（默认: 工作区根目录，即 $REPO_ROOT）
#                       rtconsole 输出: <target-root>/rtconsole/
#                       rtconnect 输出: <target-root>/rtconnect/
#                       rtmessage 输出: <target-root>/rtmessage/
#   --stats             仅统计受影响文件数，不显示 diff 内容
#   -h, --help          显示本帮助
#
# 目录映射（源 → 目标）:
#   rtmessage : Redpanda-data/redpanda/  →  <target-root>/rtmessage/
#   rtconnect : Redpanda-data/connect/   →  <target-root>/rtconnect/
#   rtconsole : Redpanda-data/console/   →  <target-root>/rtconsole/
#
# 前提条件（execute 模式）:
#   目标目录须已存在且包含完整项目文件。
#   初始化示例（以 rtconsole 为例）:
#     cp -r Redpanda-data/console rtconsole
#   或通过 git submodule/worktree 方式维护。
#
# 改名规则来源:
#   sync/config/rename_rules.yaml（跳过 go_module / org scope）
#
# 改名范围来源:
#   sync/reports/allow_rename.tsv（由 build_phase1_lists.sh 生成）
#
# 注意：仅处理文件内容替换。文件名/目录名的改名是单独的步骤。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── 颜色常量 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 路径配置 ──────────────────────────────────────────────────────────────────
RULES_FILE="${REPO_ROOT}/sync/config/rename_rules.yaml"
ALLOW_TSV="${REPO_ROOT}/sync/reports/allow_rename.tsv"
DENY_TSV="${REPO_ROOT}/sync/reports/deny_rename.tsv"
MANUAL_TSV="${REPO_ROOT}/sync/reports/manual_review.tsv"

# ── 项目映射（源目录 / 目标目录） ─────────────────────────────────────────────
declare -A SRC_DIR=(
    [rtmessage]="Redpanda-data/redpanda"
    [rtconnect]="Redpanda-data/connect"
    [rtconsole]="Redpanda-data/console"
)
declare -A TGT_DIR=(
    [rtmessage]="rtmessage"
    [rtconnect]="rtconnect"
    [rtconsole]="rtconsole"
)

# ── 默认参数 ──────────────────────────────────────────────────────────────────
MODE="dry-run"
PROJECT="all"
TARGET_ROOT="${REPO_ROOT}"
STATS_ONLY=false

# ── 参数解析 ──────────────────────────────────────────────────────────────────
usage() {
    sed -n '/^# 用法:/,/^[^#]/p' "$0" | sed 's/^# \{0,2\}//' | head -30
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     MODE="dry-run";  shift ;;
        --execute)     MODE="execute";  shift ;;
        --project)     PROJECT="$2";    shift 2 ;;
        --target-root) TARGET_ROOT="$2"; shift 2 ;;
        --stats)       STATS_ONLY=true; shift ;;
        -h|--help)     usage ;;
        *) echo -e "${RED}[ERROR]${NC} 未知参数: $1" >&2; exit 1 ;;
    esac
done

# ── 合法项目列表 ───────────────────────────────────────────────────────────────
if [[ "$PROJECT" == "all" ]]; then
    PROJECTS=(rtconsole rtconnect rtmessage)   # 风险从低到高
else
    if [[ -z "${SRC_DIR[$PROJECT]:-}" ]]; then
        echo -e "${RED}[ERROR]${NC} 未知项目: $PROJECT（可选: rtconsole | rtconnect | rtmessage | all）" >&2
        exit 1
    fi
    PROJECTS=("$PROJECT")
fi

# ── 预检 ──────────────────────────────────────────────────────────────────────
for f in "$RULES_FILE" "$ALLOW_TSV" "$DENY_TSV" "$MANUAL_TSV"; do
    if [[ ! -f "$f" ]]; then
        echo -e "${RED}[ERROR]${NC} 必需文件不存在: $f" >&2
        echo -e "        请先运行: bash sync/audit/audit_all.sh && bash sync/audit/build_phase1_lists.sh" >&2
        exit 1
    fi
done

if ! command -v python3 &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} 本脚本依赖 python3，请先安装。" >&2
    exit 1
fi

if ! command -v diff &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} 本脚本依赖 diff 命令，请先安装 diffutils。" >&2
    exit 1
fi

# ── Python helper：解析 rename_rules.yaml ─────────────────────────────────────
# 输出格式（TSV）: from<TAB>to<TAB>scope
# 按 from 字符串长度降序排列（确保长模式优先匹配，避免部分替换）
# 跳过 go_module / org scope（需要 go 工具链，应在 deny 列表中）
# 跳过 no-op 规则（from == to）
parse_rename_rules() {
    local project="$1"
    python3 - "$project" "$RULES_FILE" <<'PYEOF'
import re, sys

project, rules_file = sys.argv[1], sys.argv[2]

rules = []
current_section = None
current_from = None
current_to = None
current_scope = None

SKIP_SCOPES = {'go_module', 'org'}

def save_rule():
    if current_from and current_to and current_scope:
        if current_section in ('global', project):
            if current_scope not in SKIP_SCOPES:
                if current_from != current_to:   # 跳过 no-op 规则
                    rules.append((current_from, current_to, current_scope))

with open(rules_file, encoding='utf-8') as f:
    for line in f:
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue

        # 节头（如 global:  rtconsole:）
        m = re.match(r'^([\w][\w-]*):$', stripped)
        if m:
            save_rule()
            current_section = m.group(1)
            current_from = current_to = current_scope = None
            continue

        # 列表项起始：- from: "..."
        m = re.match(r'^-\s+from:\s+"?(.*?)"?\s*$', stripped)
        if m:
            save_rule()
            current_from = m.group(1)
            current_to = current_scope = None
            continue

        # to: "..."
        m = re.match(r'^to:\s+"?(.*?)"?\s*$', stripped)
        if m:
            current_to = m.group(1)
            continue

        # scope: word
        m = re.match(r'^scope:\s+(\w+)\s*$', stripped)
        if m:
            current_scope = m.group(1)
            continue

# 处理最后一条规则
save_rule()

# 按 from 长度降序（长模式优先，防止短模式误破坏长字符串）
rules.sort(key=lambda x: -len(x[0]))

for frm, to, scope in rules:
    # 安全地输出，避免 from/to 中含有制表符
    print('{}\t{}\t{}'.format(frm, to, scope))
PYEOF
}

# ── 统计辅助 ──────────────────────────────────────────────────────────────────
_total_files=0
_changed_files=0
_skipped_files=0

# ── 核心处理循环 ──────────────────────────────────────────────────────────────
process_project() {
    local project="$1"
    local src_root="${REPO_ROOT}/${SRC_DIR[$project]}"
    local tgt_root="${TARGET_ROOT}/${TGT_DIR[$project]}"

    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  项目: ${project}${NC}"
    echo -e "${BOLD}${BLUE}  源目录: ${src_root}${NC}"
    if [[ "$MODE" == "execute" ]]; then
        echo -e "${BOLD}${BLUE}  目标目录: ${tgt_root}${NC}"
    fi
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════${NC}"

    # execute 模式：验证目标目录存在
    if [[ "$MODE" == "execute" ]]; then
        if [[ ! -d "$tgt_root" ]]; then
            echo -e "${RED}[ERROR]${NC} 目标目录不存在: ${tgt_root}" >&2
            echo -e "        请先初始化目标目录，例如:" >&2
            echo -e "          cp -r ${SRC_DIR[$project]} ${TGT_DIR[$project]}" >&2
            return 1
        fi
    fi

    # 从 allow_rename.tsv 取本项目的唯一文件列表（第3列）
    mapfile -t allow_files < <(
        awk -F'\t' -v proj="$project" 'NR>1 && $1==proj {print $3}' "$ALLOW_TSV" | sort -u
    )
    echo -e "  可改名文件总数: ${#allow_files[@]}"

    if [[ ${#allow_files[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}[WARN]${NC} 无可处理文件，请确认 allow_rename.tsv 包含 ${project} 条目。"
        return 0
    fi

    # 构建 deny 文件集合（用于跳过混合文件）
    local deny_set
    deny_set=$(awk -F'\t' -v proj="$project" 'NR>1 && $1==proj {print $3}' "$DENY_TSV" 2>/dev/null | sort -u || true)

    # 构建 manual 文件集合（警告但仍处理）
    local manual_set
    manual_set=$(awk -F'\t' -v proj="$project" 'NR>1 && $1==proj {print $3}' "$MANUAL_TSV" 2>/dev/null | sort -u || true)

    # 生成本项目的改名规则 TSV（临时文件）
    local rules_tsv
    rules_tsv=$(mktemp /tmp/phase1_rules_XXXXXX.tsv)
    trap "rm -f '$rules_tsv'" EXIT
    parse_rename_rules "$project" > "$rules_tsv"

    local rule_count
    rule_count=$(wc -l < "$rules_tsv")
    echo -e "  改名规则数量: ${rule_count}"
    echo ""

    local proj_changed=0
    local proj_skipped=0
    local proj_total=0

    for rel_path in "${allow_files[@]}"; do
        local src_file="${src_root}/${rel_path}"

        # 源文件必须存在
        if [[ ! -f "$src_file" ]]; then
            echo -e "  ${YELLOW}[WARN]${NC} 源文件不存在，跳过: ${rel_path}"
            (( proj_skipped += 1 ))
            continue
        fi

        # 若文件也在 deny 列表中，跳过（混合文件，需手工处理）
        if echo "$deny_set" | grep -qxF "$rel_path" 2>/dev/null; then
            echo -e "  ${YELLOW}[SKIP-DENY]${NC} 文件含禁改模式（部分行在 deny 列表），跳过: ${rel_path}"
            (( proj_skipped += 1 ))
            continue
        fi

        # manual 文件：警告，但继续处理（allow 优先于 manual）
        if echo "$manual_set" | grep -qxF "$rel_path" 2>/dev/null; then
            echo -e "  ${YELLOW}[MANUAL]${NC} 文件含待人工审查条目，请确认改名结果: ${rel_path}"
        fi

        (( proj_total += 1 ))

        # 生成改名后内容到临时文件
        local renamed_tmp
        renamed_tmp=$(mktemp /tmp/phase1_renamed_XXXXXX)
        trap "rm -f '$renamed_tmp' '$rules_tsv'" EXIT

        local python_exit=0
        python3 - "$rules_tsv" "$src_file" > "$renamed_tmp" 2>/tmp/phase1_py_err.txt <<'PYEOF' || python_exit=$?
import sys

rules_tsv_file, src_file = sys.argv[1], sys.argv[2]

rules = []
with open(rules_tsv_file, encoding='utf-8') as f:
    for line in f:
        line = line.rstrip('\n')
        parts = line.split('\t')
        if len(parts) >= 2:
            rules.append((parts[0], parts[1]))

try:
    with open(src_file, 'rb') as f:
        raw = f.read()
    content = raw.decode('utf-8')
except (UnicodeDecodeError, IOError) as e:
    sys.stderr.write(f'[SKIP] {src_file}: {e}\n')
    sys.exit(2)

for frm, to in rules:
    content = content.replace(frm, to)

sys.stdout.write(content)
PYEOF

        if [[ $python_exit -eq 2 ]]; then
            # 二进制文件或编码问题，跳过
            echo -e "  ${CYAN}[SKIP-BIN]${NC} 非文本文件，跳过: ${rel_path}"
            rm -f "$renamed_tmp"
            (( proj_skipped += 1 ))
            continue
        elif [[ $python_exit -ne 0 ]]; then
            echo -e "  ${RED}[ERROR]${NC} 处理文件出错 (exit ${python_exit}): ${rel_path}"
            cat /tmp/phase1_py_err.txt >&2 2>/dev/null || true
            rm -f "$renamed_tmp"
            (( proj_skipped += 1 ))
            continue
        fi

        # 比较原文件和改名后内容
        local diff_out
        diff_out=$(diff --unified=3 "$src_file" "$renamed_tmp" 2>/dev/null || true)

        if [[ -z "$diff_out" ]]; then
            # 无变化（allow 列表中但实际无品牌字符串匹配）
            rm -f "$renamed_tmp"
            continue
        fi

        (( proj_changed += 1 ))

        if [[ "$STATS_ONLY" == "false" ]]; then
            echo -e "${BOLD}── ${rel_path} ──${NC}"
            # 彩色 diff 输出（加/减行）
            while IFS= read -r diff_line; do
                if [[ "$diff_line" == "---"* || "$diff_line" == "+++"* ]]; then
                    echo -e "${BOLD}${diff_line}${NC}"
                elif [[ "$diff_line" == "-"* ]]; then
                    echo -e "${RED}${diff_line}${NC}"
                elif [[ "$diff_line" == "+"* ]]; then
                    echo -e "${GREEN}${diff_line}${NC}"
                elif [[ "$diff_line" == "@@"* ]]; then
                    echo -e "${CYAN}${diff_line}${NC}"
                else
                    echo "$diff_line"
                fi
            done <<< "$diff_out"
            echo ""
        fi

        if [[ "$MODE" == "execute" ]]; then
            local tgt_file="${tgt_root}/${rel_path}"
            # 确保目标文件所在目录存在
            mkdir -p "$(dirname "$tgt_file")"
            # 保留原文件权限
            local perms
            perms=$(stat -c '%a' "$src_file" 2>/dev/null || echo "644")
            cp "$renamed_tmp" "$tgt_file"
            chmod "$perms" "$tgt_file"
        fi

        rm -f "$renamed_tmp"
    done

    # 汇总
    echo -e "  ${BOLD}项目汇总 [${project}]${NC}"
    echo -e "    处理文件 : ${proj_total}"
    echo -e "    有变更   : ${GREEN}${proj_changed}${NC}"
    echo -e "    跳过     : ${YELLOW}${proj_skipped}${NC}"
    if [[ "$MODE" == "execute" ]]; then
        echo -e "    已写入   : ${GREEN}${proj_changed}${NC} 个文件到 ${tgt_root}"
    fi

    (( _total_files   += proj_total   )) || true
    (( _changed_files += proj_changed )) || true
    (( _skipped_files += proj_skipped )) || true
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│     Phase 1 改名脚本 — ${MODE^^}            │${NC}"
echo -e "${BOLD}${CYAN}└─────────────────────────────────────────┘${NC}"
echo -e "  模式        : ${BOLD}${MODE}${NC}"
echo -e "  项目        : ${BOLD}${PROJECT}${NC}"
if [[ "$MODE" == "execute" ]]; then
    echo -e "  输出根目录  : ${BOLD}${TARGET_ROOT}${NC}"
fi
echo -e "  规则文件    : ${RULES_FILE}"
echo -e "  允许清单    : ${ALLOW_TSV}"
echo ""

for proj in "${PROJECTS[@]}"; do
    process_project "$proj"
done

# ── 最终汇总 ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}════════════════════════ 总计 ════════════════${NC}"
echo -e "  处理文件 : ${_total_files}"
echo -e "  有变更   : ${GREEN}${BOLD}${_changed_files}${NC}"
echo -e "  跳过     : ${YELLOW}${_skipped_files}${NC}"
if [[ "$MODE" == "dry-run" ]]; then
    echo ""
    echo -e "  ${YELLOW}[dry-run]${NC} 未写入任何文件。"
    echo -e "  执行真实改名请添加 ${BOLD}--execute${NC} 参数。"
elif [[ "$MODE" == "execute" ]]; then
    echo ""
    echo -e "  ${GREEN}[execute]${NC} 已写入 ${_changed_files} 个文件。"
    echo -e "  建议下一步: 编译目标目录并对比测试。"
fi
echo ""
