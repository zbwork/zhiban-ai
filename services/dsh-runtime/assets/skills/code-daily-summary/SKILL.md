---
{
  "name": "code_daily_summary",
  "displayName": "代码日报",
  "description": "Generate a daily code contribution report from GitLab, GitHub, or a git SSH/HTTPS remote on a target branch. 中文：代码日报 / 研发日报 / 统计 main 分支提交 / 今日谁提交了什么 / 统计新增删除行 / 未提交人员 / 写入数据库。Use this skill when a digital employee is asked to summarize repository commits for a time window, especially from a scheduled task. Supports optional PostgreSQL persistence; without DB config it returns Markdown and JSON only.",
  "homepage": "https://www.zbwork.cn/skills/code-daily-summary",
  "license": "MIT",
  "metadata": {
    "openclaw": {
      "emoji": "🧾",
      "requires": {
        "bins": ["python3"]
      }
    }
  },
  "agent_compat": {
    "required_runtimes": ["openclaw"]
  },
  "input_chips_schema": [
    {
      "key": "provider",
      "kind": "enum-dropdown",
      "label": "代码来源",
      "required": true,
      "default": "git",
      "description": "选择 Git SSH/HTTPS 远端、GitLab API 或 GitHub API。",
      "options": [
        {"value": "git", "label": "Git SSH/HTTPS"},
        {"value": "gitlab", "label": "GitLab API"},
        {"value": "github", "label": "GitHub API"}
      ]
    },
    {
      "key": "repo",
      "kind": "text-inline",
      "label": "仓库地址",
      "required": true,
      "default": "http://gitlab.example.com/example/project.git",
      "placeholder": "http://gitlab.example.com/example/project.git",
      "description": "Git SSH/HTTPS 地址，或 GitLab/GitHub 的 group/project、owner/repo。"
    },
    {
      "key": "branch",
      "kind": "text-inline",
      "label": "分支",
      "required": true,
      "default": "main",
      "placeholder": "main"
    },
    {
      "key": "gitlab_base_url",
      "kind": "text-inline",
      "label": "GitLab 地址",
      "required": false,
      "default": "http://gitlab.example.com",
      "placeholder": "http://gitlab.example.com",
      "description": "provider=gitlab 时使用。"
    },
    {
      "key": "token_env",
      "kind": "text-inline",
      "label": "代码平台 Token 环境变量",
      "required": false,
      "default": "GITLAB_TOKEN",
      "placeholder": "GITLAB_TOKEN",
      "description": "provider=gitlab/github 时使用，变量值必须从运行时 secret/env 读取。"
    },
    {
      "key": "since",
      "kind": "text-inline",
      "label": "开始时间",
      "required": false,
      "placeholder": "2026-06-25T00:00:00+08:00",
      "description": "不填时按 cutoff_hour 自动取上一统计周期。"
    },
    {
      "key": "until",
      "kind": "text-inline",
      "label": "结束时间",
      "required": false,
      "placeholder": "2026-06-25T23:59:59+08:00",
      "description": "不填时默认统计到当前 cutoff_hour。"
    },
    {
      "key": "timezone",
      "kind": "text-inline",
      "label": "时区",
      "required": true,
      "default": "Asia/Shanghai",
      "placeholder": "Asia/Shanghai"
    },
    {
      "key": "cutoff_hour",
      "kind": "number",
      "label": "默认截止小时",
      "required": false,
      "default": "22",
      "min": 0,
      "max": 23,
      "step": 1,
      "description": "未显式指定 since/until 时使用，例如 22 表示每天 22 点截断。"
    },
    {
      "key": "tracked_authors",
      "kind": "text-inline",
      "label": "人员映射",
      "required": true,
      "default": "刘明=Lemonliu|mingliu63;武明明=mingmingwu6;李强=qiangli139;王少坤=shaokunwang2",
      "placeholder": "真实姓名=账号1|账号2;真实姓名=账号3",
      "description": "支持一个真实人员对应多个 GitLab/GitHub 账号，用于合并统计并列出未提交人员。"
    },
    {
      "key": "git_ssh_key_env",
      "kind": "text-inline",
      "label": "Git SSH 私钥环境变量",
      "required": false,
      "default": "CODE_SUMMARY_GIT_SSH_KEY",
      "placeholder": "CODE_SUMMARY_GIT_SSH_KEY",
      "description": "SSH 仓库使用。变量值应为只读 Deploy Key 私钥内容。"
    },
    {
      "key": "git_http_username",
      "kind": "text-inline",
      "label": "Git HTTPS 用户名",
      "required": false,
      "default": "code-summary-readonly",
      "placeholder": "code-summary-readonly",
      "description": "HTTPS Deploy Token 使用。"
    },
    {
      "key": "git_http_password_env",
      "kind": "text-inline",
      "label": "Git HTTPS 密码环境变量",
      "required": false,
      "default": "CODE_SUMMARY_GIT_HTTP_PASSWORD",
      "placeholder": "CODE_SUMMARY_GIT_HTTP_PASSWORD",
      "description": "HTTPS Deploy Token 的 token/password 所在环境变量。不要直接填写 token。"
    },
    {
      "key": "db_host",
      "kind": "text-inline",
      "label": "数据库地址",
      "required": false,
      "default": "39.96.62.19",
      "placeholder": "39.96.62.19"
    },
    {
      "key": "db_port",
      "kind": "number",
      "label": "数据库端口",
      "required": false,
      "default": "5432",
      "min": 1,
      "max": 65535,
      "step": 1
    },
    {
      "key": "db_name",
      "kind": "text-inline",
      "label": "数据库名",
      "required": false,
      "default": "code_summary",
      "placeholder": "code_summary"
    },
    {
      "key": "db_user",
      "kind": "text-inline",
      "label": "数据库用户",
      "required": false,
      "default": "code_summary",
      "placeholder": "code_summary"
    },
    {
      "key": "db_password_env",
      "kind": "text-inline",
      "label": "数据库密码环境变量",
      "required": false,
      "default": "CODE_SUMMARY_DB_PASSWORD",
      "placeholder": "CODE_SUMMARY_DB_PASSWORD",
      "description": "不要直接填写数据库密码，填写运行时 secret/env 名称。"
    }
  ]
}
---

# 代码日报

这个 skill 给“代码日报员”数字员工使用：从 GitLab / GitHub API 或 git SSH/HTTPS 远端拉取某个分支在指定时间窗口内的提交，按指定人员统计 commits / additions / deletions，列出未提交人员，生成 Markdown + JSON；如果提供 PostgreSQL 配置，则把结果写入数据库。

定时任务只负责每天唤起数字员工。真正的数据采集、统计、入库由本 skill 的脚本完成。

## 何时使用

使用本 skill：

- 用户要求“生成代码日报 / 研发日报 / 今日提交汇总”。
- 用户指定 GitLab / GitHub 仓库、分支、时间窗口、人员名单。
- F08 定时任务每天 22:00 或 00:05 唤起数字员工做日报。

不要使用本 skill：

- 用户要做代码审查、bug 定位、MR 审核。那是代码分析/审查任务，不是日报统计。
- 用户没有给仓库来源，且当前数字员工配置里也没有默认 repo。

## 凭证与参数

优先从环境变量读凭证，不要把 token / DB 密码写进回复、日志或仓库文件。托管数字员工默认推荐 `provider=gitlab` + `GITLAB_TOKEN`；SSH Deploy key 适合没有 API token 或必须按 git 协议拉仓库的场景。

| 项 | 环境变量 | CLI 参数 | 说明 |
|---|---|---|---|
| GitLab token | `GITLAB_TOKEN` | `--token-env GITLAB_TOKEN` | `--provider gitlab` 时需要 |
| GitHub token | `GITHUB_TOKEN` | `--token-env GITHUB_TOKEN` | 私有 GitHub 仓库需要 |
| Git SSH 私钥 | 自定义，例如 `CODE_SUMMARY_GIT_SSH_KEY` | `--git-ssh-key-env CODE_SUMMARY_GIT_SSH_KEY` | `--provider git` 且使用 SSH 仓库时需要 |
| Git HTTPS 用户名 | `CODE_SUMMARY_GIT_HTTP_USERNAME` | `--git-http-username` | `--provider git` 且使用 HTTPS Deploy Token 时需要 |
| Git HTTPS 密码 | `CODE_SUMMARY_GIT_HTTP_PASSWORD` | `--git-http-password-env CODE_SUMMARY_GIT_HTTP_PASSWORD` | Deploy Token 的 token/password |
| Git SSH 命令 | `CODE_SUMMARY_GIT_SSH_COMMAND` | `--git-ssh-command` | 可覆盖默认 SSH 选项 |
| DB DSN | `CODE_SUMMARY_DB_DSN` | `--db-dsn` | 可选；不提供则只输出日报 |
| DB 密码 | `CODE_SUMMARY_DB_PASSWORD` | `--db-password-env CODE_SUMMARY_DB_PASSWORD` | 用 host/port/db/user 组合 DSN 时使用 |
| DB 代理 | `CODE_SUMMARY_DB_HTTP_PROXY` | `--db-http-proxy` | 运行时网络参数，默认内置 `http://proxy.paas.test:7890`，普通用户无需填写 |
| 跟踪人员 | `CODE_SUMMARY_TRACKED_AUTHORS` | `--tracked-authors` | JSON 或简写格式 |

`tracked_authors` 推荐 JSON：

```json
[
  {"name": "张三", "aliases": ["zhangsan", "zhangsan@example.com"]},
  {"name": "李四", "aliases": ["lisi", "lisi@example.com"]}
]
```

简写也支持：

```text
张三=zhangsan|zhangsan@example.com;李四=lisi|lisi@example.com
```

人员映射会写入输出 JSON 的 `summary.tracked_authors`，并同步写入数据库 `daily_code_reports.tracked_authors`。`daily_code_author_stats.author_name` 使用真实姓名，commit 明细保留 Git 提交里的原始作者名和邮箱。一个人可以配置多个 `aliases`，用于合并多个 GitLab/GitHub 账号、历史改名或邮箱。

## Git 凭证怎么获取

推荐优先使用 GitLab Deploy Token 或 GitLab API token；如果必须走 SSH，再使用 Deploy key，不要使用个人主 SSH key。

GitLab Deploy Token（推荐给当前 `example/project` 仓库）：

1. 打开 GitLab 项目：`Settings` -> `Repository` -> `Deploy tokens`。
2. `Name` 填 `code-summary-readonly`。
3. `Username` 可填 `code-summary-readonly`。
4. `Scopes` 只勾选 `read_repository`。
5. 创建后把 token/password 配到平台 secret/env，名称建议 `CODE_SUMMARY_GIT_HTTP_PASSWORD`。
6. 调用时使用 `provider=git`、`repo=http://gitlab.example.com/example/project.git`、`git_http_username=code-summary-readonly`、`git_http_password_env=CODE_SUMMARY_GIT_HTTP_PASSWORD`。

GitLab API token：

1. 打开 GitLab 用户头像菜单：`Preferences` -> `Access Tokens`。
2. 创建只读 token，名称建议 `code-summary-readonly`。
3. 权限选择能读取仓库和提交的最小权限，通常为 `read_api` 或 `read_repository`（按企业 GitLab 配置为准）。
4. 把 token 配到平台 secret/env，名称建议 `GITLAB_TOKEN`。
5. 调用时使用 `provider=gitlab`、`gitlab_base_url=http://gitlab.example.com`、`repo=example/project`、`token_env=GITLAB_TOKEN`。

托管 OpenClaw / Pod 场景下，如果使用 SSH，不建议每次 Pod 重建都生成新 key。可以在首次初始化时由运行时生成一把只读专用 key，把公钥展示给用户添加到 GitLab Deploy keys；私钥必须持久化到平台 secret/env（例如 `CODE_SUMMARY_GIT_SSH_KEY`），后续 Pod 重建继续注入同一把私钥。

GitLab SSH 仓库：

1. 本地生成一把只读专用 key：

   ```bash
   ssh-keygen -t ed25519 -N '' -C 'code-summary-deploy-key' -f ~/.ssh/code_summary_deploy_key
   ```

2. 打开 GitLab 项目：`Settings` -> `Repository` -> `Deploy keys`。
3. `Title` 填 `code-summary-openclaw-readonly`。
4. `Key` 粘贴 `~/.ssh/code_summary_deploy_key.pub` 的内容。
5. 不要勾选 `Grant write permissions to this key`。
6. 把私钥 `~/.ssh/code_summary_deploy_key` 的内容作为平台 secret/env，名称建议 `CODE_SUMMARY_GIT_SSH_KEY`。

GitHub SSH 仓库同理：打开仓库 `Settings` -> `Deploy keys` -> `Add deploy key`，只勾读权限，不勾写权限。

如果使用 GitLab/GitHub API 模式，token 至少需要读取仓库提交信息的权限。token 同样必须走 secret/env，不要出现在聊天回复里。

## 用户配置示例

用户可以把默认配置发给数字员工保存：

```text
请为代码日报技能保存以下默认配置：

仓库：
- provider: git
- repo: http://gitlab.example.com/example/project.git
- branch: main

默认时间：
- timezone: Asia/Shanghai
- cutoff_hour: 22

人员映射：
- shaokunwang2 对应 王少坤
- qiangli139 对应 李强
- Lemonliu、mingliu63 对应 刘明
- mingmingwu6 对应 武明明

Git 凭证：
- git_http_username: code-summary-readonly
- git_http_password_env: CODE_SUMMARY_GIT_HTTP_PASSWORD

数据库：
- db_host: 39.96.62.19
- db_port: 5432
- db_name: code_summary
- db_user: code_summary
- db_password_env: CODE_SUMMARY_DB_PASSWORD
```

结构化配置可表达为：

```json
{
  "provider": "git",
  "repo": "http://gitlab.example.com/example/project.git",
  "branch": "main",
  "timezone": "Asia/Shanghai",
  "cutoff_hour": 22,
  "tracked_authors": [
    {"name": "王少坤", "aliases": ["shaokunwang2"]},
    {"name": "李强", "aliases": ["qiangli139"]},
    {"name": "刘明", "aliases": ["Lemonliu", "mingliu63"]},
    {"name": "武明明", "aliases": ["mingmingwu6"]}
  ],
  "git_http_username": "code-summary-readonly",
  "git_http_password_env": "CODE_SUMMARY_GIT_HTTP_PASSWORD",
  "db_host": "39.96.62.19",
  "db_port": 5432,
  "db_name": "code_summary",
  "db_user": "code_summary",
  "db_password_env": "CODE_SUMMARY_DB_PASSWORD"
}
```

## 调用示例

GitLab：

```bash
python3 /opt/openclaw-builtin/skills/code-daily-summary/scripts/summarize.py \
  --provider gitlab \
  --gitlab-base-url https://gitlab.example.com \
  --repo group/project \
  --branch main \
  --timezone Asia/Shanghai \
  --cutoff-hour 22 \
  --tracked-authors '[{"name":"张三","aliases":["zhangsan@example.com"]}]'
```

GitHub：

```bash
python3 /opt/openclaw-builtin/skills/code-daily-summary/scripts/summarize.py \
  --provider github \
  --repo owner/repo \
  --branch main \
  --since 2026-06-24T22:00:00+08:00 \
  --until 2026-06-25T22:00:00+08:00 \
  --tracked-authors "$CODE_SUMMARY_TRACKED_AUTHORS"
```

Git SSH 仓库：

```bash
python3 /opt/openclaw-builtin/skills/code-daily-summary/scripts/summarize.py \
  --provider git \
  --repo git@gitlab.example.com:example/project.git \
  --branch main \
  --since 2026-06-24T22:00:00+08:00 \
  --until 2026-06-25T22:00:00+08:00 \
  --git-ssh-key-env CODE_SUMMARY_GIT_SSH_KEY \
  --tracked-authors "$CODE_SUMMARY_TRACKED_AUTHORS"
```

Git HTTPS Deploy Token：

```bash
python3 /opt/openclaw-builtin/skills/code-daily-summary/scripts/summarize.py \
  --provider git \
  --repo http://gitlab.example.com/example/project.git \
  --branch main \
  --since 2026-06-24T22:00:00+08:00 \
  --until 2026-06-25T22:00:00+08:00 \
  --git-http-username code-summary-readonly \
  --git-http-password-env CODE_SUMMARY_GIT_HTTP_PASSWORD \
  --tracked-authors "$CODE_SUMMARY_TRACKED_AUTHORS"
```

指定自然日窗口：

```bash
python3 /opt/openclaw-builtin/skills/code-daily-summary/scripts/summarize.py \
  --provider git \
  --repo git@gitlab.example.com:example/project.git \
  --branch main \
  --since 2026-06-25T00:00:00+08:00 \
  --until 2026-06-25T23:59:59+08:00 \
  --git-ssh-key-env CODE_SUMMARY_GIT_SSH_KEY \
  --tracked-authors "$CODE_SUMMARY_TRACKED_AUTHORS"
```

写入 PostgreSQL：

```bash
python3 /opt/openclaw-builtin/skills/code-daily-summary/scripts/summarize.py \
  --provider gitlab \
  --repo group/project \
  --branch main \
  --tracked-authors "$CODE_SUMMARY_TRACKED_AUTHORS" \
  --db-host "$CODE_SUMMARY_DB_HOST" \
  --db-port "${CODE_SUMMARY_DB_PORT:-5432}" \
  --db-name "$CODE_SUMMARY_DB_NAME" \
  --db-user "$CODE_SUMMARY_DB_USER" \
  --db-password-env CODE_SUMMARY_DB_PASSWORD
```

## 默认时间窗口

如果不传 `--since/--until`，脚本按 `--timezone` 和 `--cutoff-hour` 计算上一个完整日报窗口。

例如当前是 `2026-06-25 22:05 Asia/Shanghai`，`--cutoff-hour 22`，窗口就是：

```text
2026-06-24T22:00:00+08:00 ~ 2026-06-25T22:00:00+08:00
```

用户也可以显式指定自然日，例如：

```text
统计 2026-06-25 00:00:00 到 2026-06-25 23:59:59 的 main 分支提交，并写入数据库。
```

## 输出

stdout 输出 JSON，其中包含：

- `markdown`：可直接回复给用户或发到群里的日报。
- `summary`：结构化统计数据。
- `summary.tracked_authors`：用户配置的真实姓名和 GitLab/GitHub/git 作者名映射。
- `db_write`：是否写库、写入状态、错误信息。
- `latest_result`：写库成功时返回 `daily_code_latest_result` 的最新多行数组，每行包含 `author_name`、`period_text` 和按该人员拆分的 `report_markdown`；未写库或写库失败时为 `null`。
- `latest_result_markdown`：写库成功时返回把 `latest_result[].report_markdown` 逐段拼接后的 Markdown；未写库或写库失败时为 `null`。

Markdown 日报按真实人员聚合。每个人下方按“一、功能开发（新增能力）/ 二、问题修复（体验/稳定性）/ 三、代码优化（用户无感，为后续提速）”分类，忽略纯 Merge 提交的事项展示，并把同一功能主题下的多个非 Merge 改动点合并成一条产品化说明；合并后的细分点用中文短语和逗号列出，不展示原始英文提交标题，也不展示单条代码行数。纯 Merge 提交仍计入提交数和行数。

如果 DB 未配置，`db_write.enabled=false`，这不是失败。

## 数据库表

脚本会在目标 schema 下自动创建四张轻量表：

- `daily_code_reports`
- `daily_code_author_stats`
- `daily_code_commits`
- `daily_code_latest_result`

同一 `provider + repo + branch + window_start + window_end` 重跑会 upsert 同一份 report，避免定时任务重试产生重复报告。

OpenClaw Pod 访问外部 PostgreSQL 时默认通过运行时内置 HTTP CONNECT 代理 `http://proxy.paas.test:7890`，这是运行环境细节，不需要用户填写。

`daily_code_latest_result` 只保留最近一次成功写库的对话统计结果，按人员多行存储：

- `id`：自增主键
- `author_name`：人员名称，例如 `李强`
- `period_text`：时间周期，例如 `2026-05-13 19:00 - 2026-06-12 19:00`
- `report_markdown`：该人员本次统计周期内的 Markdown 报告；标题统一为 `# 代码地址：<repo> (<branch>)`

写库成功后，脚本会把这些行同时放到输出 JSON 的 `latest_result`、`latest_result_markdown` 和 `db_write.latest_result`。调用方默认不要展开 `latest_result` 的字段，避免把总日报和分人员日报重复输出。

## 口径

- 统计目标是目标分支上的 commit，GitLab 使用 `ref_name`，GitHub 使用 `sha`。
- 时间按 commit 的 committed date / GitHub commit date 过滤。
- additions / deletions 以 provider API 返回的 commit stats 为准。
- “未提交人员”只针对 `tracked_authors` 里的人员；未列入人员的提交会放在未跟踪提交里。
- 分类是启发式：根据 commit message 判断 feature / fix / docs / tests / ops / maintenance / other，不能替代代码审查。
- 产品主题归纳必须由提交标题决定，改动文件路径只用于补充细分点和影响范围；不能让一个大提交中偶然出现的次要模块路径覆盖标题表达的主目标。
- A2A 跨 Agent 协作与 Agent 运行全链路可观测性是独立主题。命中 `a2a`、`agent run`、`observability`、`tracing` 或 `usage attribution` 时，日报必须显式展示对应主题，不能合并成泛化的“计费”“运行时”或“补齐能力”。

## 回复模板

调用脚本后，默认只把 `markdown` 原样贴给用户；若 `db_write.enabled=true` 且 `ok=true`，补一句“已写入数据库”即可，不要再展开 `daily_code_latest_result`，也不要输出 `author_name / period_text / report_markdown` 字段标签。

如果用户明确要求“按人员输出”“只输出 latest_result”“只输出每个人 report_markdown”，则只输出 `latest_result_markdown`，不要同时输出总 `markdown`。

若 `db_write.enabled=false`，补一句“本次未配置数据库，仅生成日报”。
