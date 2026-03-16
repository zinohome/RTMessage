#!/usr/bin/env bash
# sync/audit/audit_all.sh — 主审计入口
#
# 依次运行三个子审计脚本，最后合并输出总体汇总报告。
#
# 用法:
#   bash sync/audit/audit_all.sh [--repo-root <path>] [--output-dir <path>]
#
# 参数:
#   --repo-root   工作区根目录，默认自动检测
#   --output-dir  报告输出目录，默认 sync/reports/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 解析参数 ──────────────────────────────────────────────────────────────────
REPO_ROOT=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)  REPO_ROOT="$2";  shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

# 自动推导路径
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="${REPO_ROOT}/sync/reports"
fi

mkdir -p "$OUTPUT_DIR"

BOLD='\033[1m'; BLUE='\033[0;34m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║        RTMessage 品牌审计 — 全量扫描             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  工作区根目录: ${REPO_ROOT}"
echo -e "  报告输出目录: ${OUTPUT_DIR}"
echo -e "  开始时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# ── 运行子审计脚本 ────────────────────────────────────────────────────────────
run_audit() {
    local script="$1"
    local label="$2"
    echo -e "${BLUE}${BOLD}▶ 阶段: ${label}${NC}"
    if bash "$script" --repo-root "$REPO_ROOT" --output-dir "$OUTPUT_DIR"; then
        echo -e "${GREEN}  完成: ${label}${NC}"
    else
        echo -e "${YELLOW}  警告: ${label} 脚本退出码非零，请检查输出${NC}" >&2
    fi
    echo ""
}

run_audit "${SCRIPT_DIR}/audit_redpanda.sh"  "RTMessage (Redpanda C++ 核心)"
run_audit "${SCRIPT_DIR}/audit_connect.sh"   "RTconnect (Redpanda Connect Go)"
run_audit "${SCRIPT_DIR}/audit_console.sh"   "RTconsole (Redpanda Console Go+TS)"

# ── 合并生成总体汇总 ──────────────────────────────────────────────────────────
SUMMARY_FILE="${OUTPUT_DIR}/audit_summary.md"

{
    printf "# RTMessage 全量品牌审计报告\n\n"
    printf "生成时间: %s\n\n" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf "工作区根目录: \`%s\`\n\n" "$REPO_ROOT"
    printf "%s\n\n" "---"
    printf "## 分项汇总\n\n"

    total_safe=0; total_review=0; total_protected=0

    for proj in rtmessage rtconnect rtconsole; do
        tsv="${OUTPUT_DIR}/${proj}_audit.tsv"
        if [[ -f "$tsv" ]]; then
            # 统计各分类数量（跳过 header 行）
            safe=$(tail -n +2 "$tsv" | awk -F'\t' '$1=="SAFE"' | wc -l)
            review=$(tail -n +2 "$tsv" | awk -F'\t' '$1=="REVIEW"' | wc -l)
            protected=$(tail -n +2 "$tsv" | awk -F'\t' '$1=="PROTECTED"' | wc -l)
            total=$(( safe + review + protected ))
            total_safe=$(( total_safe + safe ))
            total_review=$(( total_review + review ))
            total_protected=$(( total_protected + protected ))
            printf "### %s\n\n" "$proj"
            printf "| 分类 | 数量 |\n|------|------|\n"
            printf "| ✅ SAFE | %d |\n" "$safe"
            printf "| ⚠️  REVIEW | %d |\n" "$review"
            printf "| 🚫 PROTECTED | %d |\n" "$protected"
            printf "| 合计 | %d |\n\n" "$total"
        else
            printf "### %s\n\n未生成报告，跳过。\n\n" "$proj"
        fi
    done

    printf "%s\n\n" "---"
    printf "## 合计\n\n"
    printf "| 分类 | 数量 | 处置方式 |\n"
    printf "|------|------|----------|\n"
    printf "| ✅ SAFE | %d | 可加入自动改名脚本批量处理 |\n" "$total_safe"
    printf "| ⚠️  REVIEW | %d | 需人工逐一审核，归类为 SAFE 或 PROTECTED |\n" "$total_review"
    printf "| 🚫 PROTECTED | %d | 禁止改名，需在代码中特殊标注 |\n" "$total_protected"
    printf "| **合计** | **%d** | |\n\n" "$(( total_safe + total_review + total_protected ))"

    printf "## 详细报告文件\n\n"
    for proj in rtmessage rtconnect rtconsole; do
        printf "%s\n" "- \`sync/reports/${proj}_audit.tsv\` — 完整逐行清单"
        printf "%s\n" "- \`sync/reports/${proj}_summary.md\` — 分类摘要"
    done
    printf "\n"
    printf "## 下一步\n\n"
    printf "1. 检查所有 PROTECTED 条目，建立禁改名清单\n"
    printf "2. 人工处理 REVIEW 条目，明确每条处置意见\n"
    printf "3. SAFE 条目确认无误后，加入 \`sync/patch/\` 自动改名脚本\n"
    printf "4. 改名完成后运行回归测试，验证功能与性能一致性\n"
} > "$SUMMARY_FILE"

echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              全量审计完成                         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  总体报告: ${SUMMARY_FILE}"
echo ""
