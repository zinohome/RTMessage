#!/usr/bin/env bash
# sync/audit/audit_redpanda.sh — RTMessage (Redpanda C++ 核心) 品牌审计
#
# 扫描 Redpanda-data/redpanda/ 下的所有源文件，
# 对品牌字符串进行 SAFE / REVIEW / PROTECTED 三级分类。
#
# 用法:
#   bash sync/audit/audit_redpanda.sh [--repo-root <path>] [--output-dir <path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── 解析参数 ──────────────────────────────────────────────────────────────────
REPO_ROOT=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)  REPO_ROOT="$2";  shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | head -8 | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$REPO_ROOT" ]]  && REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="${REPO_ROOT}/sync/reports"

UPSTREAM_DIR="${REPO_ROOT}/Redpanda-data/redpanda"

if [[ ! -d "$UPSTREAM_DIR" ]]; then
    echo -e "${RED}[错误]${NC} 上游目录不存在: ${UPSTREAM_DIR}" >&2
    echo "  请确认 Redpanda-data/redpanda/ 目录已就位（只读参考）" >&2
    exit 1
fi

# ── 初始化报告 ────────────────────────────────────────────────────────────────
init_report "$OUTPUT_DIR" "rtmessage"

# ── 搜索模式定义 ──────────────────────────────────────────────────────────────
# 主要品牌关键词的 Perl 正则（大小写不敏感由 grep -i 控制）
BRAND_PATTERN='\bredpanda\b|\brpk\b|redpanda-data|redpanda\.com|Redpanda Data'

# Kafka 协议 API 名称（出现在任何文件中都标记 PROTECTED）
KAFKA_API_PATTERN='ApiVersions|JoinGroup|SyncGroup|LeaveGroup|Heartbeat|SaslHandshake|SaslAuthenticate|InitProducerId|TxnOffsetCommit|OffsetForLeaderEpoch|AddPartitionsToTxn|DescribeConfigs|AlterConfigs|IncrementalAlterConfigs|CreatePartitions'

# Kafka 内部 topic（PROTECTED）
KAFKA_TOPIC_PATTERN='__consumer_offsets|__transaction_state'

# ── 文件扫描逻辑（针对 C++ / Bazel 仓库特化）─────────────────────────────────
classify_redpanda_file() {
    local rel="$1"    # 相对于 UPSTREAM_DIR 的路径

    # ---- 特化：PROTECTED 路径 ----
    case "$rel" in
        src/v/kafka/protocol/*|src/v/kafka/server/handlers/*)
            echo "PROTECTED"; return ;;
        src/v/kafka/protocol_gen/*)
            echo "PROTECTED"; return ;;
    esac

    # ---- 特化：rpk CLI 全部 SAFE ----
    case "$rel" in
        src/go/rpk/*)
            echo "SAFE"; return ;;
    esac

    # ---- 特化：C++ 核心层（非 Kafka 协议路径） ----
    case "$rel" in
        src/v/kafka/*)
            echo "REVIEW"; return ;;
        src/v/*)
            # 非 kafka 路径的 C++ 源码 —— 命名空间、日志、内部符号，SAFE
            echo "SAFE"; return ;;
    esac

    # ---- Protobuf 定义文件 ----
    case "$rel" in
        *.proto|proto/*)
            echo "REVIEW"; return ;;
    esac

    # ---- 构建文件 ----
    case "$rel" in
        BUILD|BUILD.bazel|*BUILD|*BUILD.bazel|\
        MODULE.bazel|WORKSPACE|*.bzl|Makefile|Taskfile*)
            echo "SAFE"; return ;;
    esac

    # ---- 配置模板 ----
    case "$rel" in
        conf/*|config/*)
            echo "SAFE"; return ;;
    esac

    # ---- 文档 ----
    case "$rel" in
        docs/*|*.md|*.rst|*.adoc|*.txt)
            echo "SAFE"; return ;;
    esac

    # ---- 测试文件（需改名，但无兼容性风险） ----
    case "$rel" in
        tests/*|*_test.go|*test*.cc|*test*.h)
            echo "SAFE"; return ;;
    esac

    # ---- 兜底：REVIEW ----
    echo "REVIEW"
}

# ── 主扫描循环 ────────────────────────────────────────────────────────────────
echo -e "  ${CYAN}扫描目录: ${UPSTREAM_DIR}${NC}"
echo ""

file_count=0
match_count=0

while IFS= read -r -d '' abs_path; do
    rel="${abs_path#"${UPSTREAM_DIR}/"}"

    # 统一跳过逻辑
    if should_skip_file "$rel"; then continue; fi

    # 检查文件是否包含任何品牌字符串（快速预过滤）
    if ! grep -qiP "${BRAND_PATTERN}" "$abs_path" 2>/dev/null; then continue; fi

    (( file_count += 1 ))

    base_cat="$(classify_redpanda_file "$rel")"

    # 逐行扫描，二次判断内容上下文
    while IFS=: read -r lineno excerpt; do
        (( match_count += 1 ))
        cat="$base_cat"
        reason=""

        # 内容级二次判断（优先级高于路径分类）
        if echo "$excerpt" | grep -qiP "$KAFKA_API_PATTERN"; then
            cat="PROTECTED"
            reason="命中 Kafka 协议 API 名称（wire 格式）"
        elif echo "$excerpt" | grep -qP "$KAFKA_TOPIC_PATTERN"; then
            cat="PROTECTED"
            reason="Kafka 内部 Topic 名称"
        elif echo "$excerpt" | grep -qP 'github\.com/redpanda-data'; then
            cat="REVIEW"
            reason="Go module 路径，需使用专用工具改名"
        elif echo "$excerpt" | grep -qiP 'namespace\s+redpanda'; then
            if [[ "$cat" != "PROTECTED" ]]; then
                cat="SAFE"
                reason="C++ namespace 声明，纯内部符号"
            fi
        elif echo "$excerpt" | grep -qiP '(vlog|dlog|log\.|logger\.|fmt\.Print|errors\.New|fmt\.Errorf)'; then
            if [[ "$cat" != "PROTECTED" ]]; then
                cat="SAFE"
                reason="日志/错误消息字符串"
            fi
        fi

        [[ -z "$reason" ]] && case "$cat" in
            SAFE)      reason="路径分类: C++/rpk/docs/build 区域，可安全改名" ;;
            REVIEW)    reason="路径分类: Kafka 或 proto 区域，需人工确认" ;;
            PROTECTED) reason="路径分类: Kafka 协议核心路径" ;;
        esac

        record "$cat" "$rel" "$lineno" "$reason" "$excerpt"
    done < <(grep -inP "${BRAND_PATTERN}" "$abs_path" 2>/dev/null || true)

done < <(find "$UPSTREAM_DIR" -type f -print0 | sort -z)

echo -e "  扫描文件: ${file_count} 个包含品牌字符串的文件"
echo -e "  总匹配行: ${match_count}"
echo ""

print_summary
