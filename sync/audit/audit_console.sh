#!/usr/bin/env bash
# sync/audit/audit_console.sh — RTconsole (Redpanda Console Go+TypeScript) 品牌审计
#
# 扫描 Redpanda-data/console/ 下的所有源文件，
# 对品牌字符串进行 SAFE / REVIEW / PROTECTED 三级分类。
# Console 是三个组件中改名风险最低的，建议优先实施。
#
# 用法:
#   bash sync/audit/audit_console.sh [--repo-root <path>] [--output-dir <path>]

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
        -h|--help) grep '^#' "$0" | head -10 | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$REPO_ROOT" ]]  && REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="${REPO_ROOT}/sync/reports"

UPSTREAM_DIR="${REPO_ROOT}/Redpanda-data/console"

if [[ ! -d "$UPSTREAM_DIR" ]]; then
    echo -e "${RED}[错误]${NC} 上游目录不存在: ${UPSTREAM_DIR}" >&2
    echo "  请确认 Redpanda-data/console/ 目录已就位（只读参考）" >&2
    exit 1
fi

# ── 初始化报告 ────────────────────────────────────────────────────────────────
init_report "$OUTPUT_DIR" "rtconsole"

# ── 搜索模式 ──────────────────────────────────────────────────────────────────
BRAND_PATTERN='\bredpanda\b|redpanda-data|redpanda\.com|redpanda-console|Redpanda Console|Redpanda Data'

# Kafka / Schema Registry 协议标识符（PROTECTED）
KAFKA_COMPAT_PATTERN='__consumer_offsets|__transaction_state|application/vnd\.kafka|application/vnd\.schemaregistry|/subjects/|/schemas/ids/'

# ── Console 仓库特化分类逻辑 ──────────────────────────────────────────────────
classify_console_file() {
    local rel="$1"

    # ---- SAFE: 前端 UI 源码（几乎全部品牌字符串）----
    case "$rel" in
        frontend/src/*)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 前端公共文件 ----
    case "$rel" in
        frontend/public/*|frontend/*.json|frontend/*.ts|frontend/*.mts|\
        frontend/*.config.*|frontend/package.json)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 文档 ----
    case "$rel" in
        docs/*|*.md|*.rst|*.adoc|*.txt)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 命令行入口 ----
    case "$rel" in
        backend/cmd/*|cmd/*)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 构建文件 ----
    case "$rel" in
        Makefile|Taskfile*|taskfiles/*|*.yml|*.yaml|lefthook.yml|\
        Dockerfile|docker-compose*)
            echo "SAFE"; return ;;
    esac

    # ---- REVIEW: Go module 文件 ----
    case "$rel" in
        backend/go.mod|go.mod)
            echo "REVIEW"; return ;;
    esac

    # ---- REVIEW: 后端 API 路由定义（路径可能是客户端依赖的契约）----
    case "$rel" in
        backend/pkg/api/*|backend/pkg/handler*|backend/pkg/router*)
            echo "REVIEW"; return ;;
    esac

    # ---- REVIEW: Protobuf 定义 ----
    case "$rel" in
        *.proto|proto/*)
            echo "REVIEW"; return ;;
    esac

    # ---- REVIEW: 后端 Go 源码（默认审查）----
    case "$rel" in
        backend/pkg/*|backend/*)
            echo "REVIEW"; return ;;
    esac

    # ---- SAFE: 测试文件 ----
    case "$rel" in
        *_test.go|frontend/tests/*)
            echo "SAFE"; return ;;
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
    base_cat="$(classify_console_file "$rel")"

    while IFS=: read -r lineno excerpt; do
        (( match_count += 1 ))
        cat="$base_cat"
        reason=""

        # ---- 内容级二次判断 ----
        if echo "$excerpt" | grep -qiP "$KAFKA_COMPAT_PATTERN"; then
            cat="PROTECTED"
            reason="命中 Kafka/Schema Registry 协议标识符，禁止改名"

        elif echo "$excerpt" | grep -qP 'github\.com/redpanda-data/console'; then
            cat="REVIEW"
            reason="Go module 路径，需 go mod 工具链操作"

        elif echo "$excerpt" | grep -qiP '^\s*(//|/\*|\*|#)\s'; then
            # 注释行
            if [[ "$cat" != "PROTECTED" ]]; then
                cat="SAFE"
                reason="代码注释或文档说明"
            fi

        elif echo "$excerpt" | grep -qiP '(console\.redpanda\.com|cloud\.redpanda\.com)'; then
            cat="SAFE"
            reason="产品域名，可改为对应的 retone.tech 域名"

        elif echo "$excerpt" | grep -qiP '(log\.|logger\.|zap\.|slog\.|fmt\.Print|fmt\.Errorf)'; then
            if [[ "$cat" != "PROTECTED" ]]; then
                cat="SAFE"
                reason="日志输出字符串"
            fi

        # TypeScript/React 中的 JSX 文本或字符串字面量
        elif echo "$excerpt" | grep -qiP "(>Redpanda|'Redpanda|\"Redpanda|title.*Redpanda|label.*Redpanda)"; then
            cat="SAFE"
            reason="前端 UI 显示文本，可安全改名"
        fi

        [[ -z "$reason" ]] && case "$cat" in
            SAFE)      reason="前端/文档/CLI 区域，品牌字符串可安全改名" ;;
            REVIEW)    reason="后端 Go 代码，需确认是否为对外 API 路径或协议字段" ;;
            PROTECTED) reason="Kafka/Schema Registry 协议兼容字符串，禁止改名" ;;
        esac

        record "$cat" "$rel" "$lineno" "$reason" "$excerpt"
    done < <(grep -inP "${BRAND_PATTERN}" "$abs_path" 2>/dev/null || true)

done < <(find "$UPSTREAM_DIR" -type f -print0 | sort -z)

echo -e "  扫描文件: ${file_count} 个包含品牌字符串的文件"
echo -e "  总匹配行: ${match_count}"
echo ""

# ── 追加 console 专项说明 ─────────────────────────────────────────────────────
{
    printf "## Console 专项说明\n\n"
    printf "### 改名优先级\n\n"
    printf "Console 是三个组件中 **改名风险最低** 的，建议第一个实施，以验证整体改名→构建→测试流程。\n\n"
    printf "### 前端改名重点\n\n"
    printf "| 位置 | 改名内容 | 风险 |\n"
    printf "|------|----------|------|\n"
    printf "| \`frontend/src/\` | 所有品牌文字、logo alt text | ✅ SAFE |\n"
    printf "| \`frontend/package.json\` | \`name\` 字段 | ✅ SAFE |\n"
    printf "| \`frontend/public/\` | HTML title、favicon | ✅ SAFE |\n\n"
    printf "### 后端改名重点\n\n"
    printf "| 位置 | 改名内容 | 风险 |\n"
    printf "|------|----------|------|\n"
    printf "| \`backend/cmd/\` | 二进制入口名称 | ✅ SAFE |\n"
    printf "| \`backend/go.mod\` | Go module 路径 | ⚠️ REVIEW（需 go mod 工具） |\n"
    printf "| \`backend/pkg/api/\` | HTTP 路由路径 | ⚠️ REVIEW（前端调用这些路径） |\n\n"
    printf "### API 路径注意事项\n\n"
    printf "Console 后端的 HTTP API 被前端直接调用。\n"
    printf "若修改 API 路径中的 \`redpanda\` 前缀，必须同步修改前端调用代码，否则会产生 404。\n"
    printf "建议用 API 版本前缀（如 \`/api/v1/\`）替代品牌前缀，一次性解决问题。\n"
} >> "${OUTPUT_DIR}/rtconsole_summary.md"

print_summary
