#!/usr/bin/env bash
# sync/audit/build_phase1_lists.sh — 生成第一阶段改名执行清单
#
# 目标策略（第一阶段硬规则）：
# 1) 只改 Redpanda 自有品牌可见层
# 2) 协议层禁改
# 3) 第三方依赖层禁改
#
# 输入：sync/reports/*_audit.tsv
# 输出：
#   sync/reports/allow_rename.tsv      # 可直接改名
#   sync/reports/deny_rename.tsv       # 禁止改名
#   sync/reports/manual_review.tsv     # 仍需人工确认
#   sync/reports/phase1_lists_summary.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPORT_DIR="${REPO_ROOT}/sync/reports"

ALLOW_FILE="${REPORT_DIR}/allow_rename.tsv"
DENY_FILE="${REPORT_DIR}/deny_rename.tsv"
MANUAL_FILE="${REPORT_DIR}/manual_review.tsv"
SUMMARY_FILE="${REPORT_DIR}/phase1_lists_summary.md"

mkdir -p "$REPORT_DIR"

# 头部
printf "PROJECT\tCATEGORY\tFILE\tLINE\tREASON\tEXCERPT\n" > "$ALLOW_FILE"
printf "PROJECT\tCATEGORY\tFILE\tLINE\tREASON\tEXCERPT\n" > "$DENY_FILE"
printf "PROJECT\tCATEGORY\tFILE\tLINE\tREASON\tEXCERPT\n" > "$MANUAL_FILE"

classify_review_to_phase1() {
    local file="$1"
    local reason="$2"
    local excerpt="$3"

    # ---- 第一阶段禁改：协议层 ----
    if [[ "$reason" =~ Kafka|协议|proto|Schema\ Registry|wire ]]; then
        echo "DENY"
        return
    fi
    if [[ "$file" == *"/kafka/"* || "$file" == *".proto" || "$file" == *"/proto/"* || "$file" == *"schema_registry"* || "$file" == *"schemaregistry"* || "$file" == *"openapi"* ]]; then
        echo "DENY"
        return
    fi
    if [[ "$excerpt" =~ __consumer_offsets|__transaction_state|application/vnd\.kafka|application/vnd\.schemaregistry|/subjects/|/schemas/ids/ ]]; then
        echo "DENY"
        return
    fi

    # ---- 第一阶段禁改：第三方依赖层 ----
    if [[ "$reason" == *"Go module 路径"* ]]; then
        echo "DENY"
        return
    fi
    if [[ "$excerpt" == *"github.com/redpanda-data/"* || "$excerpt" == *"github.com/confluent"* || "$excerpt" == *"github.com/apache"* ]]; then
        echo "DENY"
        return
    fi

    # ---- 其余 REVIEW 暂保留人工确认 ----
    echo "MANUAL"
}

# 处理每个项目 audit 文件
for project in rtmessage rtconnect rtconsole; do
    src="${REPORT_DIR}/${project}_audit.tsv"
    if [[ ! -f "$src" ]]; then
        echo "[WARN] 缺少审计文件: $src" >&2
        continue
    fi

    # 跳过 header，逐行处理
    tail -n +2 "$src" | while IFS=$'\t' read -r category file line reason excerpt; do
        case "$category" in
            SAFE)
                # 第一阶段 SAFE = 允许改名
                printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$project" "$category" "$file" "$line" "$reason" "$excerpt" >> "$ALLOW_FILE"
                ;;
            PROTECTED)
                # PROTECTED 直接禁改
                printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$project" "$category" "$file" "$line" "$reason" "$excerpt" >> "$DENY_FILE"
                ;;
            REVIEW)
                phase1_decision="$(classify_review_to_phase1 "$file" "$reason" "$excerpt")"
                if [[ "$phase1_decision" == "DENY" ]]; then
                    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$project" "$category" "$file" "$line" "$reason" "$excerpt" >> "$DENY_FILE"
                else
                    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$project" "$category" "$file" "$line" "$reason" "$excerpt" >> "$MANUAL_FILE"
                fi
                ;;
        esac
    done
done

# 统计
allow_n=$(tail -n +2 "$ALLOW_FILE" | wc -l | tr -d ' ')
deny_n=$(tail -n +2 "$DENY_FILE" | wc -l | tr -d ' ')
manual_n=$(tail -n +2 "$MANUAL_FILE" | wc -l | tr -d ' ')
all_n=$(( allow_n + deny_n + manual_n ))

# 生成摘要
{
    printf "# 第一阶段改名执行清单（自动生成）\n\n"
    printf "生成时间: %s\n\n" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    printf "执行策略：\n"
    printf "1. 只改 Redpanda 自有品牌可见层\n"
    printf "2. 协议层禁改\n"
    printf "3. 第三方依赖层禁改\n\n"
    printf "## 统计\n\n"
    printf "| 清单 | 数量 | 含义 |\n"
    printf "|------|------|------|\n"
    printf "| allow_rename.tsv | %d | 可直接进入批量改名 |\n" "$allow_n"
    printf "| deny_rename.tsv | %d | 第一阶段禁止修改 |\n" "$deny_n"
    printf "| manual_review.tsv | %d | 仍需人工判断 |\n" "$manual_n"
    printf "| **合计** | **%d** | |\n\n" "$all_n"

    printf "## 输出文件\n\n"
    printf "- \`sync/reports/allow_rename.tsv\`\n"
    printf "- \`sync/reports/deny_rename.tsv\`\n"
    printf "- \`sync/reports/manual_review.tsv\`\n"
    printf "- \`sync/reports/phase1_lists_summary.md\`\n"
} > "$SUMMARY_FILE"

echo "[OK] 生成完成:"
echo "  $ALLOW_FILE"
echo "  $DENY_FILE"
echo "  $MANUAL_FILE"
echo "  $SUMMARY_FILE"
echo "[OK] 统计: allow=$allow_n deny=$deny_n manual=$manual_n total=$all_n"
