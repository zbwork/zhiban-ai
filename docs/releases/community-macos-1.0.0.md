# 社区版 macOS 1.0.0 发布记录

用户指定版本1.0.0，包含源码提交3d1d3f9及本轮社区发布配置。从正式Release归档分别交付Apple Silicon与Intel单架构包，版本号1.0.0、build 10001；匿名员工与技能目录使用https://zb.qkfintech.cn。构建不加载商业dart-defines或用户工作区数据。

社区分发使用独立应用标识cn.qkfintech.zhiban.community和应用名“知办AI社区版”，保留签名要求；Bridge使用现有授权Developer ID profile，运行组件从当前社区源码打包。主App、嵌套代码、DMG均需验证签名，Apple公证通过并staple后上传。社区原生配置不携带商业更新feed；应用名和标识只在主App配置设置，不能用Xcode全局PRODUCT_NAME覆盖所有Pod目标。

交付GitHub仓库zbwork/zhiban-ai；当前没有远端标签或Release。只创建并上传Release草稿，不创建远端Git引用、不推送提交。用户需自行同步源码和创建正确标签后发布草稿。

构建、签名、公证、安装包检查均已通过，上传目标为GitHub Release草稿。Windows安装包不在本机macOS构建范围。

## 构建工具链适配

本机Xcode 27的lipo多架构校验差异已通过原生单架构命令复现；构建专用适配器逐一检查arm64、x86_64，缺失ppc负测仍失败。Xcode会在PATH前插入自身工具链，因此适配器须只在Flutter构建phase内置于PATH首位；归档脚本finally恢复原工程文件，适配器不进入App。没有修改系统lipo或Flutter SDK。

最低系统为macOS 13.5，与内嵌Node 24官方最低版本一致（[Node官方迁移说明](https://github.com/nodejs/nodejs.org/blob/main/apps/site/pages/en/blog/migrations/v22-to-v24.mdx)）；主App的LSMinimumSystemVersion相应设为13.5，避免旧系统误装后才发现执行器不能启动。两种架构均在本机构建自检；Intel执行经Rosetta，不冒充独立Intel机器验收。

## 归档与运行验证

- 最终归档版本1.0.0+10001；Info.plist验证独立社区应用标识、社区名和最低系统13.5，未携带商业更新feed。
- 主App、Bridge、两套运行时均包含预期架构；主App deep strict签名和Bridge Developer ID requirement校验通过，Bridge initialize RPC通过。
- 最终包内arm64与x64各22项Node测试全部通过（共44项），包含真实Codex工具往返、缺response ID续答兼容、取消、审批与附件边界；两架构node/engine/office/isolation/codex自检全部通过。
- 测试后再次deep strict验签通过；包内无社区数据库、凭据目录、附件目录等用户工作区数据。
- 实际启动Release成功，免登录空态和线上官方员工人物头像显示正确。Release技能页切换未计通过：本轮桌面自动化AX点击无状态变化、坐标报noWindowsAvailable；不推断为产品导航故障。此前相同业务代码预览中的技能页和线上99张图片全量结果见部署后验证记录。
- DMG镜像创建及hdiutil verify通过，Developer ID签名完成。后续单架构镜像的最终结果见下方交付表；首次universal镜像不是交付资产。

本轮未重跑服务端测试、Windows构建或独立Intel硬件测试；未修改服务端，Windows不在本机范围，Intel运行验证使用Rosetta。既有Flutter53项回归已在头像提交前通过，本轮仅调整原生发布身份/版本，另以最终归档和双架构真实运行测试验证。

## 安装包体积纠正

首次universal镜像923538864字节，未上传GitHub。用户指出完整版约200多MB后实测：本机完整版仅arm64、展开764776064字节；本轮universal展开1526133136字节，双架构运行组件占主要差异。hdiutil imageinfo另显示编码在用609397891字节、浪费313978675字节。原正式打包脚本使用HFS+及ULMO(LZMA)，本轮首次使用默认文件系统和UDZO(zlib)，未沿用原压缩参数。纠正为同一已验证归档按架构导出、仅保留相应运行组件，原功能不裁剪；分别deep strict验签/工具回归，沿用HFS+ ULMO生成镜像，再重新签名公证。原900MB镜像不作为交付资产。

## 原DMG逐文件对照结论

已通过公开更新feed下载原1.5.6(15601) DMG，217465745字节，SHA256 `3e508c65b647e9b2e0b6aeb931625d3101548174f42a0d688bb427b4d2a57e41`。只读挂载确认ULMO(LZMA)、HFS+、仅arm64；原DMG App与本机已安装App逐文件SHA256完全一致（新增/删除/改变均0），因此此前安装目录比对有效。

相同arm64下：Node文件2个、120758710字节完全等量；node_modules两边均28262文件、499439621字节，无新增/删除依赖。11个Mach-O二进制比较LC_CODE_SIGNATURE之外的字节完全一致，差异仅签名区。runtime/dist新增2个社区入口文件，净增24704字节；assets净增840字节。universal包新增的x64运行目录为660002326字节，原生DingRTC/Flutter/Bridge等也增加Intel切片；没有发现大体积新增依赖或工作区文件。

按原版HFS+ ULMO参数、同arm64架构生成的DMG为216738667字节，比原版少727078字节，原组件能力保留；发布按安装机器CPU分别提供arm64和x64。逐项证据见[内容对照数据](community-macos-1.0.0-content-comparison.json)。原通用镜像及未完成的试验镜像不上传GitHub。

## 最终交付

GitHub仓库 `zbwork/zhiban-ai`，Release标题“知办AI社区版 1.0.0”，草稿ID `438890376`。发布源代码包含业务提交`3d1d3f9`及原生发布配置`a482e5e`。维护者须自行同步本地发布分支、创建正确的`v1.0.0`标签后发布；本次没有写入任何远端Git引用。草稿在[Releases](https://github.com/zbwork/zhiban-ai/releases)中由有权限维护者查看，尚未公开发布。

| 适用机器 | 文件 | 最终字节数 | SHA-256 |
|---|---|---:|---|
| Apple Silicon（M系列） | `ZhiBanAI_Community_1.0.0_macos_arm64.dmg` | 216741806 | `10d3b90b763274ce7662d09bc549e68f9efc7a576f49e261f235cf0c2e58d6c9` |
| Intel Mac（x86_64） | `ZhiBanAI_Community_1.0.0_macos_x64.dmg` | 240353048 | `5ded84c09a290fe8682bccf05e6403955e82fca5d563d40637b39df8323571ed` |

两个包均为HFS+ ULMO，已通过Apple公证（Accepted）、staple/validate和Gatekeeper（Notarized Developer ID）。每个架构的独立导出产物重新完成Bridge initialize、组件自检、22项工具/附件/transport测试，测试后deep strict签名继续通过；Intel测试在Apple Silicon主机Rosetta下执行，未冒充独立Intel硬件验收。随资产提供SHA256SUMS；上传完成后按GitHub返回的digest与本地文件SHA256核对。

最终上传验证：GitHub草稿包含且仅包含arm64、x64两个DMG和SHA256SUMS，三个资产均state=uploaded，服务器digest与本地SHA256一致。两个DMG最终字节数已包含staple票据；体积对比段的生成字节数为票据附加前，差异约3KB。远端Git标签引用仍为0，未执行Git推送或创建远端标签。
