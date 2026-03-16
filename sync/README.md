# sync/ — 中间同步层

本目录是 RTMessage 工程的核心治理层，所有品牌化改名、上游同步追踪、变更验证的脚本均在此处维护。

## 设计原则

1. **只读上游**：`Redpanda-data/` 目录下的三个项目仅作参考，绝不写入。
2. **改名与功能分离**：脚本只做改名，不修改任何功能逻辑。
3. **上游可追溯**：`config/upstream.yaml` 记录每次同步的 commit，可随时对比 drift。
4. **可回滚**：所有改名均由 patch 层维护，patch 层可独立回滚。

## 第一阶段硬规则

1. 只改 Redpanda 自有品牌可见层。
2. 协议层禁改（Kafka/Schema Registry/OpenAPI/Proto 契约）。
3. 第三方依赖层禁改（外部 module path、外部品牌与协议实现）。

## 目录结构

```
sync/
├── README.md                        # 本文档
├── config/
│   ├── upstream.yaml                # 上游仓库版本追踪（每次同步后更新）
│   ├── rename_rules.yaml            # 改名映射规则（品牌字符串 → RTx 字符串）
│   └── protected.yaml               # 禁止改名的受保护模式（Kafka 协议等）
├── audit/                           # 第一阶段：审计脚本
│   ├── audit_all.sh                 # 主入口，依次调用三个子审计
│   ├── audit_redpanda.sh            # RTMessage (C++ 核心) 审计
│   ├── audit_connect.sh             # RTconnect (Go) 审计
│   ├── audit_console.sh             # RTconsole (Go+TypeScript) 审计
│   └── lib/
│       └── common.sh                # 共享工具函数
├── verify/                          # 第二阶段：验证脚本（改名完成后使用）
│   └── check_upstream_drift.sh      # 检测上游新增提交，评估影响
└── reports/                         # 生成的报告（已加入 .gitignore）
    └── .gitkeep
```

## 快速上手

```bash
# 1. 运行全量审计（产出可改/禁改清单）
bash sync/audit/audit_all.sh

# 2. 按第一阶段硬规则生成执行清单
bash sync/audit/build_phase1_lists.sh

# 3. 查看汇总报告
cat sync/reports/audit_summary.md
cat sync/reports/phase1_lists_summary.md

# 4. 预览改名结果（dry-run，不写入任何文件）
bash sync/patch/apply_phase1_rename.sh --project rtconsole --dry-run

# 5. 确认后执行真实改名（需先初始化目标目录）
cp -r Redpanda-data/console rtconsole
bash sync/patch/apply_phase1_rename.sh --project rtconsole --execute

# 6. 检查上游是否有新提交
bash sync/verify/check_upstream_drift.sh
```

## apply_phase1_rename.sh 用法

```bash
# 只看统计数量，不输出 diff
bash sync/patch/apply_phase1_rename.sh --project rtconsole --dry-run --stats

# 查看完整 diff（默认 dry-run）
bash sync/patch/apply_phase1_rename.sh --project rtconsole

# 执行改名（写入 rtconsole/ 目录）
bash sync/patch/apply_phase1_rename.sh --project rtconsole --execute

# 所有项目（风险从低到高：rtconsole → rtconnect → rtmessage）
bash sync/patch/apply_phase1_rename.sh --project all --dry-run
```

**推荐工作流（以 rtconsole 为例）：**
```
1. 确认 dry-run diff 结果符合预期
2. 初始化目标目录: cp -r Redpanda-data/console rtconsole
3. 编译基线: cd rtconsole/backend && go build ./...
4. 执行改名: bash sync/patch/apply_phase1_rename.sh --project rtconsole --execute
5. 验证改名: cd rtconsole/backend && go build ./...
6. 提交变更: git add rtconsole/ && git commit -m "feat: RTconsole Phase 1 brand rename"
```


## 报告格式

审计脚本产出两类文件：

| 文件 | 内容 |
|------|------|
| `reports/<project>_audit.tsv` | 完整逐行清单（CATEGORY / FILE / LINE / REASON / EXCERPT） |
| `reports/<project>_summary.md` | 人类可读的分类汇总 |
| `reports/audit_summary.md`    | 三个项目合并总结 |

**CATEGORY 含义：**

| 值 | 含义 |
|----|------|
| `SAFE` | 可直接改名，无兼容性风险 |
| `REVIEW` | 需人工确认上下文后决定是否改名 |
| `PROTECTED` | **禁止改名**，改动会破坏 Kafka 协议兼容性或外部契约 |

## 上游同步工作流

```
1. 上游发布新版本
2. 更新 Redpanda-data/ 目录（pull 新代码）
3. 运行 bash sync/verify/check_upstream_drift.sh
4. 脚本输出：新增/修改文件列表 + 命中保护模式的文件（需人工审查）
5. 更新 config/upstream.yaml 中的 last_synced_commit
6. 将上游变更 cherry-pick 到对应的 RT* 项目目录
```
