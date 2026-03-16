#!/usr/bin/env bash
# sync/audit/lib/common.sh — 审计脚本共享工具库
#
# 所有 audit_*.sh 脚本通过 source 引入本文件。
# 不可直接执行。

set -euo pipefail

# ── 颜色常量 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 全局报告状态（由 init_report 初始化）──────────────────────────────────────
REPORT_TSV=""
REPORT_MD=""
_COUNT_SAFE=0
_COUNT_REVIEW=0
_COUNT_PROTECTED=0
_PROJECT_NAME=""

# ── 初始化报告 ────────────────────────────────────────────────────────────────
# 用法: init_report <output_dir> <project_name>
init_report() {
    local dir="$1"
    local proj="$2"
    _PROJECT_NAME="$proj"
    mkdir -p "$dir"
    REPORT_TSV="${dir}/${proj}_audit.tsv"
    REPORT_MD="${dir}/${proj}_summary.md"
    _COUNT_SAFE=0
    _COUNT_REVIEW=0
    _COUNT_PROTECTED=0

    # TSV 头部
    printf "CATEGORY\tFILE\tLINE\tREASON\tEXCERPT\n" > "$REPORT_TSV"

    # Markdown 头部
    {
        printf "# 审计报告: %s\n\n" "$proj"
        printf "生成时间: %s\n\n" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        printf "## 说明\n\n"
        printf "| 分类 | 含义 |\n|------|------|\n"
        printf "| SAFE | 可直接改名，无兼容性风险 |\n"
        printf "| REVIEW | 需人工确认上下文后决定 |\n"
        printf "| PROTECTED | **禁止改名**，破坏 Kafka 协议或外部契约 |\n\n"
        printf "## 逐行详情\n\n请查阅对应 TSV 文件: \`%s\`\n\n" "$REPORT_TSV"
    } > "$REPORT_MD"

    echo -e "${BLUE}${BOLD}[Audit]${NC} 开始审计项目: ${BOLD}${proj}${NC}"
    echo -e "        TSV  → ${REPORT_TSV}"
    echo -e "        摘要 → ${REPORT_MD}"
    echo ""
}

# ── 记录一条审计结果 ───────────────────────────────────────────────────────────
# 用法: record <CATEGORY> <file> <lineno> <reason> <excerpt>
record() {
    local cat="$1"
    local file="$2"
    local lineno="$3"
    local reason="$4"
    local excerpt="${5:-}"

    # 截断 excerpt，避免 TSV 换行问题
    excerpt="${excerpt:0:150}"
    # 去掉 tab 和换行
    excerpt="${excerpt//	/ }"
    excerpt="${excerpt//$'\n'/ }"

    printf "%s\t%s\t%s\t%s\t%s\n" \
        "$cat" "$file" "$lineno" "$reason" "$excerpt" \
        >> "$REPORT_TSV"

    case "$cat" in
        SAFE)      (( _COUNT_SAFE += 1 )) ;;
        REVIEW)    (( _COUNT_REVIEW += 1 )) ;;
        PROTECTED) (( _COUNT_PROTECTED += 1 )) ;;
    esac
}

# ── 打印并写入最终摘要 ─────────────────────────────────────────────────────────
# 用法: print_summary
print_summary() {
    local total=$(( _COUNT_SAFE + _COUNT_REVIEW + _COUNT_PROTECTED ))

    # 写入 Markdown 摘要表
    {
        printf "## 汇总统计\n\n"
        printf "| 分类 | 数量 | 含义 |\n"
        printf "|------|------|------|\n"
        printf "| ✅ SAFE | %d | 可直接改名 |\n" "$_COUNT_SAFE"
        printf "| ⚠️  REVIEW | %d | 需人工审核 |\n" "$_COUNT_REVIEW"
        printf "| 🚫 PROTECTED | %d | 禁止改名 |\n" "$_COUNT_PROTECTED"
        printf "| **合计** | **%d** | |\n\n" "$total"
        printf "## 下一步\n\n"
        printf "1. 查阅 \`%s\` 中所有 PROTECTED 条目，确认不可改名原因\n" "$REPORT_TSV"
        printf "2. 逐一处理 REVIEW 条目，按上下文归类为 SAFE 或 PROTECTED\n"
        printf "3. SAFE 条目可加入自动改名脚本批量处理\n"
    } >> "$REPORT_MD"

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  审计完成: ${_PROJECT_NAME}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}✅ SAFE      (可直接改名): ${BOLD}${_COUNT_SAFE}${NC}"
    echo -e "  ${YELLOW}⚠️  REVIEW    (需人工审核): ${BOLD}${_COUNT_REVIEW}${NC}"
    echo -e "  ${RED}🚫 PROTECTED (禁止改名):   ${BOLD}${_COUNT_PROTECTED}${NC}"
    echo -e "${BOLD}───────────────────────────────────────────────${NC}"
    echo -e "  合计: ${total} 条匹配"
    echo -e "  TSV:  ${REPORT_TSV}"
    echo -e "  摘要: ${REPORT_MD}"
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo ""
}

# ── 文件级过滤 ────────────────────────────────────────────────────────────────
# 用法: should_skip_file <filepath>  → 返回 0 表示跳过
should_skip_file() {
    local f="$1"
    case "$f" in
        # 生成的 Protobuf 代码
        *.pb.go|*.pb.cc|*.pb.h|*_pb2.py|*_pb2_grpc.py) return 0 ;;
        # Go vendor / Node modules / Git 目录
        */vendor/*|*/node_modules/*|*/.git/*) return 0 ;;
        # Lock 文件
        */go.sum|*/package-lock.json|*/bun.lockb|*/yarn.lock|*/pnpm-lock.yaml) return 0 ;;
        # 二进制 / 媒体文件
        *.png|*.jpg|*.jpeg|*.ico|*.gif|*.svg) return 0 ;;
        *.woff|*.woff2|*.ttf|*.eot|*.otf) return 0 ;;
        *.zip|*.tar|*.gz|*.tgz|*.bin|*.exe|*.so|*.dylib|*.a) return 0 ;;
        # 版本日志 / 许可证（保持原始）
        */CHANGELOG.md|*/CHANGELOG.rst) return 0 ;;
        */licenses/*|*/NOTICE|*/NOTICE.txt) return 0 ;;
        # Bazel 输出目录
        */bazel-*) return 0 ;;
        # 生成的代码目录
        */protogen/*|*/gen/*.go) return 0 ;;
    esac
    return 1
}

# ── 基于文件路径的分类判断 ────────────────────────────────────────────────────
# 用法: classify_by_path <filepath>  → 输出 PROTECTED | REVIEW | SAFE | ""
# 返回空字符串表示无路径级别结论，由调用方继续判断内容

classify_by_path() {
    local f="$1"

    # ---- PROTECTED: Kafka 协议实现核心路径 ----
    case "$f" in
        */kafka/protocol/*|*/kafka/server/handlers/*)
            echo "PROTECTED"; return ;;
        */kafka/protocol_gen/*)
            echo "PROTECTED"; return ;;
        */pandaproxy/*)
            echo "REVIEW"; return ;;   # Kafka REST proxy, 需人工判断
    esac

    # ---- REVIEW: Protobuf 定义 ----
    case "$f" in
        *.proto)
            echo "REVIEW"; return ;;
    esac

    # ---- REVIEW: 较宽泛的 kafka 路径 ----
    case "$f" in
        */kafka/*)
            echo "REVIEW"; return ;;
    esac

    # ---- REVIEW: Go module 文件（需专用工具改名）----
    case "$f" in
        */go.mod)
            echo "REVIEW"; return ;;
    esac

    # ---- REVIEW: 公共 API schema 定义 ----
    case "$f" in
        */public/schema/*|*/api/v1/*|*/openapi/*)
            echo "REVIEW"; return ;;
    esac

    # ---- SAFE: rpk CLI（全部品牌字符串，可安全改名）----
    case "$f" in
        */src/go/rpk/*)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 文档 ----
    case "$f" in
        */docs/*|*/doc/*|*/documentation/*)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 前端 UI 源码 ----
    case "$f" in
        */frontend/src/*)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 命令行入口 ----
    case "$f" in
        */cmd/*)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 构建系统文件 ----
    case "$f" in
        */BUILD|*/BUILD.bazel|*/Makefile|*/Taskfile*)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: Markdown / 纯文本文档 ----
    case "$f" in
        *.md|*.rst|*.txt|*.adoc)
            echo "SAFE"; return ;;
    esac

    # ---- SAFE: 配置模板 ----
    case "$f" in
        */conf/*|*/config/*)
            echo "SAFE"; return ;;
    esac

    # 无路径级别结论，返回空
    echo ""
}

# ── grep 一个文件，对每个匹配行调用 record ────────────────────────────────────
# 用法: grep_and_record <file> <rel_path> <pattern> <category> <reason>
grep_and_record() {
    local file="$1"
    local rel="$2"
    local pattern="$3"
    local cat="$4"
    local reason="$5"

    # -i 大小写不敏感，-n 显示行号，-P Perl 正则
    while IFS=: read -r lineno excerpt; do
        record "$cat" "$rel" "$lineno" "$reason" "$excerpt"
    done < <(grep -inP "$pattern" "$file" 2>/dev/null || true)
}

# ── 对单文件执行完整分类扫描 ─────────────────────────────────────────────────
# 用法: scan_file <abs_path> <rel_path> <brand_pattern>
# brand_pattern: 用于 grep 的 Perl 正则
scan_file() {
    local abs="$1"
    local rel="$2"
    local brand_pat="${3:-\\bredpanda\\b|\\brpk\\b|redpanda-data|redpanda\\.com}"

    # 跳过不需要审计的文件
    if should_skip_file "$rel"; then return; fi

    # 先判断文件中是否有任何品牌字符串
    if ! grep -qiP "$brand_pat" "$abs" 2>/dev/null; then return; fi

    # 基于路径获取初始分类
    local path_cat
    path_cat="$(classify_by_path "$rel")"

    # 对每一个命中行，使用路径分类（若无，则用 REVIEW 作兜底）
    while IFS=: read -r lineno excerpt; do
        local cat="${path_cat:-REVIEW}"
        local reason

        # 针对特定内容模式进行二次判断（提升准确率）
        case "$excerpt" in
            # Kafka 协议 API 名称出现在任何文件中 → PROTECTED
            *ApiVersions*|*JoinGroup*|*SyncGroup*|*SaslHandshake*|\
            *InitProducerId*|*TxnOffsetCommit*|*OffsetForLeaderEpoch*)
                cat="PROTECTED"
                reason="命中 Kafka 协议 API 名称，禁止改名"
                ;;
            # Kafka 内部 topic → PROTECTED
            *__consumer_offsets*|*__transaction_state*)
                cat="PROTECTED"
                reason="Kafka 内部 Topic 名称，禁止改名"
                ;;
            # Go module 路径（import 语句） → REVIEW
            *"github.com/redpanda-data"*)
                cat="REVIEW"
                reason="Go module 路径，需使用专用工具改名（go mod + import rewrite）"
                ;;
            # 日志/错误字符串 → SAFE（若路径分类未提升）
            *log.*|*logger.*|*fmt.Print*|*fmt.Sprintf*|*errors.New*)
                if [[ "$cat" != "PROTECTED" ]]; then
                    cat="SAFE"
                    reason="日志/错误消息字符串，可安全改名"
                fi
                ;;
        esac

        # 若路径分类已提供且内容未触发 PROTECTED 降级，沿用路径分类
        if [[ -z "$reason" ]]; then
            case "$cat" in
                SAFE)      reason="路径分类 SAFE: 品牌字符串无兼容性风险" ;;
                REVIEW)    reason="路径分类 REVIEW: 需人工确认改名影响" ;;
                PROTECTED) reason="路径分类 PROTECTED: Kafka 协议核心路径" ;;
            esac
        fi

        record "$cat" "$rel" "$lineno" "$reason" "$excerpt"
    done < <(grep -inP "$brand_pat" "$abs" 2>/dev/null || true)
}
