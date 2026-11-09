# 社区版 macOS 1.0.0 发布记录

用户指定版本1.0.0，包含源码提交3d1d3f9及本轮社区发布配置。构建正式Release、双架构（Apple Silicon / Intel），版本号1.0.0、build 10001；匿名员工与技能目录使用https://zb.qkfintech.cn。构建不加载商业dart-defines或用户工作区数据。

社区分发使用独立应用标识cn.qkfintech.zhiban.community和应用名“知办AI社区版”，保留签名要求；Bridge使用现有授权Developer ID profile，运行组件从当前社区源码打包。主App、嵌套代码、DMG均需验证签名，Apple公证通过并staple后上传。社区原生配置不携带商业更新feed；应用名和标识只在主App配置设置，不能用Xcode全局PRODUCT_NAME覆盖所有Pod目标。

交付GitHub仓库zbwork/zhiban-ai；当前没有远端标签或Release。只创建并上传Release草稿，不创建远端Git引用、不推送提交。用户需自行同步源码和创建正确标签后发布草稿。

构建、签名、公证、安装包检查与上传结果完成后补录。Windows安装包不在本机macOS构建范围。

## 构建工具链适配

本机Xcode 27的lipo多架构校验差异已通过原生单架构命令复现；构建专用适配器逐一检查arm64、x86_64，缺失ppc负测仍失败。Xcode会在PATH前插入自身工具链，因此适配器须只在Flutter构建phase内置于PATH首位；归档脚本finally恢复原工程文件，适配器不进入App。没有修改系统lipo或Flutter SDK。

最低系统为macOS 13.5，与内嵌Node 24官方最低版本一致（[Node官方迁移说明](https://github.com/nodejs/nodejs.org/blob/main/apps/site/pages/en/blog/migrations/v22-to-v24.mdx)）；主App的LSMinimumSystemVersion相应设为13.5，避免旧系统误装后才发现执行器不能启动。两种架构均在本机构建自检；Intel执行经Rosetta，不冒充独立Intel机器验收。

## 归档与运行验证

- 最终归档版本1.0.0+10001；Info.plist验证独立社区应用标识、社区名和最低系统13.5，未携带商业更新feed。
- 主App、Bridge、两套运行时均包含预期架构；主App deep strict签名和Bridge Developer ID requirement校验通过，Bridge initialize RPC通过。
- 最终包内arm64与x64各22项Node测试全部通过（共44项），包含真实Codex工具往返、缺response ID续答兼容、取消、审批与附件边界；两架构node/engine/office/isolation/codex自检全部通过。
- 测试后再次deep strict验签通过；包内无社区数据库、凭据目录、附件目录等用户工作区数据。
- 实际启动Release成功，免登录空态和线上官方员工人物头像显示正确。Release技能页切换未计通过：本轮桌面自动化AX点击无状态变化、坐标报noWindowsAvailable；不推断为产品导航故障。此前相同业务代码预览中的技能页和线上99张图片全量结果见部署后验证记录。
- DMG镜像创建及hdiutil verify通过，Developer ID签名完成。Apple公证结果及GitHub草稿资产信息待补录。

本轮未重跑服务端测试、Windows构建或独立Intel硬件测试；未修改服务端，Windows不在本机范围，Intel运行验证使用Rosetta。既有Flutter53项回归已在头像提交前通过，本轮仅调整原生发布身份/版本，另以最终归档和双架构真实运行测试验证。
