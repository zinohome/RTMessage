# 参考仓库初始化说明

## 问题陈述

需要在项目根目录提供一个统一初始化入口，用于自动准备 `Redpanda-data/` 参考区，并克隆三个官方上游仓库：

- `redpanda-data/redpanda`
- `redpanda-data/connect`
- `redpanda-data/console`

## 范围

范围内：

- 在项目根目录新增初始化脚本
- 复用 `sync/config/upstream.yaml` 中已有的上游仓库配置
- 自动创建 `Redpanda-data/` 目录（不存在时）
- 自动克隆三个官方仓库到约定路径

范围外：

- 不修改 `Redpanda-data/` 中已有仓库内容
- 不执行品牌改名或补丁逻辑
- 不更新 `last_synced_commit` / `last_synced_date`

## 设计说明

### 方案选择

采用根目录脚本 `init_references.sh` 作为统一入口，而不是把仓库地址硬编码到多个脚本中。

理由：

1. `sync/config/upstream.yaml` 已经是上游仓库的单一事实来源。
2. 初始化逻辑只负责“拉取参考仓库”，不与后续 rename / verify 流程耦合。
3. 当上游分支或仓库地址变更时，只需调整一处配置。

### 关键行为

1. 启动时校验 `git` 和 `sync/config/upstream.yaml`。
2. `Redpanda-data/` 不存在时自动创建。
3. 对三个项目按配置读取：
   - `upstream_repo`
   - `upstream_branch`
   - `local_ref_path`
4. 目标目录已是 git 仓库时跳过，避免覆盖。
5. 目标目录存在但不是 git 仓库时直接报错，避免误覆盖本地文件。
6. 支持 `--dry-run` 预览执行命令。

## 任务拆解

1. 读取现有治理约束与上游配置。
2. 在根目录实现初始化脚本。
3. 补充根目录说明文档，记录范围、行为、风险与回滚方式。
4. 使用 `--dry-run` 验证脚本行为。

## 使用方式

```bash
# 初始化全部参考仓库
bash init_references.sh

# 仅预览，不执行写入
bash init_references.sh --dry-run

# 仅初始化部分仓库
bash init_references.sh rtconsole rtconnect
```

## 验证清单

- 根目录存在 `init_references.sh`
- 脚本能从 `sync/config/upstream.yaml` 读取仓库配置
- `--dry-run` 能正确输出 mkdir / git clone 命令
- 已存在仓库会被安全跳过

## 风险与回滚

风险：

- 首次执行会向 `Redpanda-data/` 写入参考仓库内容，需确保该操作符合当前工作流预期。
- 网络或 GitHub 访问异常会导致克隆失败。

回滚：

- 若需要撤销初始化结果，可删除对应参考目录：

```bash
rm -rf Redpanda-data/redpanda Redpanda-data/connect Redpanda-data/console
```

- 若只需撤销脚本与文档，删除根目录新增文件即可。