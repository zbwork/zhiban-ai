# ADR-0004：官方资源迁至 GitHub

状态：2026-11-13 用户完成源码推送，继续客户端接入；Pages 新版部署及在线验收分别记录。

## 决策与边界

两个独立公开仓库：zbwork/skills 保存技能、图标与源码；zbwork/agents 保存角色、人设与头像。GitHub 是唯一内容源，运行和构建均不访问原服务器。员工通过稳定 skill_uuid 引用技能。源码按分类 README / 独立 SKILL.md 组织；员工每个角色一个 AGENT.md，catalog 的 prompt_file 指向唯一人设源，构建输出展开 system_prompt 供现有客户端读取。

客户端分别匿名读取 https://zbwork.github.io/skills/ 与 https://zbwork.github.io/agents/ 下的 catalog/v1/skills.json、employees.json。图片在 assets/，技能包在 skills 站点 packages/，名称包含内容 SHA-256。技能包与目录作为同一 Pages artifact 部署，不创建 Release 或标签。原 UUID、code、版本、包内相对路径、manifest、SHA-256 和安装安全校验保持。缓存命名空间与旧服务器分离，不静默回退旧服务器。

公共请求不附带 Bus / GitHub token；旧官方头像按内容摘要迁往新站点，已保存员工与会话同步适用。自定义、组织和个人私有图片保留原权限。服务器模式只从公共目录浏览/添加模板，不把模板 UUID 当作服务器员工调用，不上传本地模型 Key。20 个原角色中 HR 原人设为空，明确记录 not_configured，禁止捏造提示词。

## 行业最佳实践与 EasyO 适配性

来源：[GitHub Pages 自定义工作流](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)、[Pages 限制](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)、[参考源码布局](https://github.com/mattpocock/skills/tree/main/skills/engineering)。行业做法是可编辑源码与构建产物分离，工作流上传静态 artifact 并部署；Pages 站点上限 1GB，软带宽限制每月 100GB。

当前资源规模远低于站点上限，且为公开开源内容分发。adopt 分类目录、最小权限 Pages 部署及内容摘要；adapt 保留现有目录字段和 ZIP 安装器，将双层技能包生成到站点；reject 自动 Release/标签、GitHub token、客户端枚举仓库 API、旧服务器兜底、发布时从内部库导出。日后接近带宽/容量限制再单独设计，不提前增加服务器依赖。

## 工作流与 Git 边界

PR 仅执行只读完整性校验；main 推送及手动运行可构建并部署 Pages。部署 job 只申请 pages:write / id-token:write，contents 始终只读。agents 校验从 skills GitHub 源目录读取引用。技能先部署，再部署员工。构建失败不得执行部署。

Codex 只能本地提交，不能 push 或写入远端提交/分支/标签。新增工作流需用户推送；本地静态验证不能等同远端上线。之前误创建的 Release 已撤为草稿、旧发布工作流已禁用，后续不启用。

## 验收

- 20 员工、81 技能引用完整；99 个真实图片摘要一致，81 个包可由现有安装器解析。
- 无后端本地工作区浏览、安装员工依赖技能、打开聊天；员工列表/详情/会话与技能图标显示真实图片，不能把默认头像算通过。
- 所有公共 URL 使用配置的静态站点，无 /api/、旧主机、Release 地址、Authorization。
- 断网保留现有缓存与已安装技能；失败可见可重试，损坏包/非安全跳转必须拒绝。
- 本地与真实远端验收独立记录；独立 bundle 隔离 UI 测试，不重启或登录用户窗口。
