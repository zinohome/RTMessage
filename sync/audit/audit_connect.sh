#!/usr/bin/env bash
# sync/audit/audit_connect.sh — RTconnect (Redpanda Connect Go) 品牌审计
#
# 扫描 Redpanda-data/connect/ 下的所有源文件，
# 对品牌字符串进行 SAFE / REVIEW / PROTECTED 三级分类。
#
# 用法:
#   bash sync/audit/audit_connect.sh [--repo-root <path>] [--output-dir <path>]

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

UPSTREAM_DIR="${REPO_ROOT}/Redpanda-data/connect"

if [[ ! -d "$UPSTREAM_DIR" ]]; then
    echo -e "${RED}[错误]${NC} 上游目录不存在: ${UPSTREAM_DIR}" >&2
    echo "  请确认 Redpanda-data/connect/ 目录已就位（只读参考）" >&2
    exit 1
fi

# ── 初始化报告 ────────────────────────────────────────────────────────────────
init_report "$OUTPUT_DIR" "rtconnect"

# ── 搜索模式 ──────────────────────────────────────────────────────────────────
# connect 的主要品牌字符串
BRAND_PATTERN='\bredpanda\b|\bRPCN\b|redpanda-data|redpanda\.com|redpanda-connect|Redpanda Connect|Redpanda Data|\bbenthos\b'

# Kafka 协议名称（PROTECTED）
KAFKA_API_PATTERN='ApiVersions|JoinGroup|SyncGroup|SaslHandshake|SaslAuthenticate|InitProducerId|__consumer_offsets|__transaction_state'

# ── Connect 仓库特化分类逻辑 ──────────────────────────────────────────────────
classify_connect_file() {
    local rel="$1"

    # ---- PROTECTED: Kafka 协议实现 ----
    case "$rel" in
        internal/impl/kafka/*)
            # Kafka 实现目录需要细分：配置定义 vs 协议码
            echo "REVIEW"; return ;;
    esac

    # ---- REVIEW: Go module 文件 ----
    case "$rel" in
        go.mod|go.sum)
            echo "REVIEW"; return ;;
    esac

    # ---- REVIEW: 对外公开的 Schema/API 定义 ----
    case "$rel" in
        public/schema/*|public/bundle/*)
            echo "REVIEW"; return ;;
    esac

    # ---- REVIEW: Protobuf 定义 ----
    case "$rel" in
        *.proto|proto/*)
            echo "REVIEW"; return ;;
    esac

    # ---- REVIEW: YAML 组件类型标识（用户配置中使用的 type 名称）----
    case "$rel" in
        internal/impl/*/*)
            # 组件 type 名称由 RegisterInput/RegisterOutput 时的参数决定
            # 需要确认是否有 "redpanda_*" 前缀的组件 type
            echo "REVIEW"; return ;;
    esac

    # ---- SAFE: 命令行入口（二进制名称） ----
    case "$rel" in
        cmd/*)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 文档 ----
    case "$rel" in
        docs/*|*.md|*.rst|*.adoc|*.txt)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 构建文件 ----
    case "$rel" in
        Makefile|Taskfile*|Taskfile.yml|taskfiles/*|*.yml)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 测试文件 ----
    case "$rel" in
        *_test.go)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: Go 源文件中的日志/注释（兜底评估后可能升级） ----
    case "$rel" in
        *.go)
            echo "REVIEW"; return ;;  # Go 文件先 REVIEW，内容扫描会调整
    esac

    # ---- 兜底 ----
    echo "REVIEW"
}

# ── 主扫描循环 ────────────────────────────────────────────────────────────────
echo -e "  ${CYAN}扫描目录: ${UPSTREAM_DIR}${NC}"
echo ""

file_count=0
match_count=0

while IFS= read -r -d '' abs_path; do
    rel="${abs_path#"${UPSTREAM_DIR}/"}"

    if should_skip_file "$rel"; then continue; fi
    if ! grep -qiP "${BRAND_PATTERN}" "$abs_path" 2>/dev/null; then continue; fi

    (( file_count += 1 ))
    base_cat="$(classify_connect_file "$rel")"

    while IFS=: read -r lineno excerpt; do
        (( match_count += 1 ))
        cat="$base_cat"
        reason=""

        # ---- 内容级二次判断 ----
        if echo "$excerpt" | grep -qiP "$KAFKA_API_PATTERN"; then
            cat="PROTECTED"
            reason="命中 Kafka 协议 API 名称"

        elif echo "$excerpt" | grep -qP 'github\.com/redpanda-data/(benthos|connect)'; then
            cat="REVIEW"
            reason="Go module 路径（benthos/connect），需 go mod 工具链操作，不可普通替换"

        elif echo "$excerpt" | grep -qP '"redpanda(_[a-z_]+)?"'; then
            # 组件 type 名称，如 "redpanda_output"、"redpanda_input"
            cat="REVIEW"
            reason="疑似组件 type 名称（用户 YAML 配置中可见），改名需同步更新文档和迁移说明"

        elif echo "$excerpt" | grep -qiP '(log\.|logger\.|fmt\.Print|fmt\.Errorf|errors\.New|t\.Log|t\.Error)'; then
            if [[ "$cat" != "PROTECTED" ]]; then
                cat="SAFE"
                reason="日志/测试输出字符串"
            fi

        elif echo "$excerpt" | grep -qiP '(//|#)\s'; then
            # 注释行
            if [[ "$cat" != "PROTECTED" ]]; then
                cat="SAFE"
                reason="代码注释，可安全改名"
            fi
        fi

        [[ -z "$reason" ]] && case "$cat" in
            SAFE)      reason="路径/内容分类: Go 源码中的品牌字符串，可安全改名" ;;
            REVIEW)    reason="路径分类: Go 文件，需确认是否为对外接口或组件 type" ;;
            PROTECTED) reason="Kafka 协议兼容字符串，禁止改名" ;;
        esac

        record "$cat" "$rel" "$lineno" "$reason" "$excerpt"
    done < <(grep -inP "${BRAND_PATTERN}" "$abs_path" 2>/dev/null || true)

done < <(find "$UPSTREAM_DIR" -type f -print0 | sort -z)

echo -e "  扫描文件: ${file_count} 个包含品牌字符串的文件"
echo -e "  总匹配行: ${match_count}"
echo ""

# ── 追加 connect 专项说明到 Markdown 摘要 ────────────────────────────────────
{
    printf "## Connect 专项说明\n\n"
    printf "### 组件 type 名称（重点 REVIEW）\n\n"
    printf "Connect 的核心扩展点是通过 \`input\`、\`output\`、\`processor\` 等组件的 \`type\` 字段来标识的。\n"
    printf "现有 \`redpanda_*\` 前缀的组件类型（如 \`redpanda_migrator\`）是用户 YAML 配置的一部分，\n"
    printf "**改名会破坏用户现有配置的向后兼容性**，需要：\n\n"
    printf "1. 同时保留旧 type 名称（使用 alias 机制）\n"
    printf "2. 提供配置迁移文档\n"
    printf "3. 在 CHANGELOG 中明确说明\n\n"
    printf "### Go module benthos 依赖\n\n"
    printf "\`github.com/redpanda-data/benthos/v4\` 是 connect 的核心依赖。\n"
    printf "若改名此模块路径，需 fork 并维护 benthos 上游，大幅增加维护成本。\n"
    printf "**建议第一阶段保留此依赖不改**，仅改名最终二进制和对外品牌字符串。\n"
} >> "${OUTPUT_DIR}/rtconnect_summary.md"

print_summary
