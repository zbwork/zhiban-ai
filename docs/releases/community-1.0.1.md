# 社区版 1.0.1 打包记录

版本 `1.0.1+10101`，业务源码基线 `e6643f8`，生产入口 `lib/main.dart`、`APP_ENV=prod`。源码归档只覆盖桌面版本元数据；没有更改交付的业务运行时。Windows 验收另带测试夹具的 60 秒等待预算修正，Mac 仍为 10 秒。官方员工和技能资源沿当前 GitHub 配置。

## 产物

| 平台 | 安装包 | 大小（十进制） |
| --- | --- | --- |
| macos arm64 | `ZhiBanAI_Community_1.0.1_macos_arm64.dmg` | 216.95 MB |
| macos x64 | `ZhiBanAI_Community_1.0.1_macos_x64.dmg` | 241.61 MB |
| windows x64 | `ZhiBanAI_Community_1.0.1_windows_x64.exe` | 393.76 MB |

安装包位于本机 `apps/zhiban-app/build/community-release-1.0.1/artifacts/`，同目录有 `SHA256SUMS`。[资产、摘要和验证记录](community-1.0.1-assets.json)保留各包 SHA256。已上传 [v1.0.1 Release 草稿](https://github.com/zbwork/zhiban-ai/releases/tag/untagged-0d9ce88dc89030129fe2)，包含三个安装包及 SHA256SUMS；GitHub 服务端的四个文件摘要和体积均与本机一致。远端尚无 v1.0.1 标签，未正式发布；没有推送 Git 或代建远端标签。

两个 Mac 包均使用社区独立 bundle ID `cn.qkfintech.zhiban.community`，最低 macOS 13.5；Developer ID 签名、Apple 公证 Accepted、票据装订和 Gatekeeper 检查全部通过。Windows 为 x64 EXE，社区稳定 AppId 保持不变；未做 Authenticode 发布者签名。保留完整 WebView2 离线安装器（212745424 字节，Microsoft 签名 Valid）。

## 行业最佳实践与适配性

沿用 [macOS 1.0.0](community-macos-1.0.0.md) 和 [Windows 1.0.0](community-windows-1.0.0.md) 的分发依据：按 CPU 架构分包、完整分发依赖、同一产品保留稳定安装标识、公证与装订、发布前验证包内组件。采用既有 HFS+ ULMO 和 Inno lzma2 压缩；继续裁剪已经证明未使用的重复 Codex vendor、非目标 node-pty 和 PDB，不新增功能裁剪，不放宽隔离。Windows 使用独立短目录和交互账号任务，不覆盖原构建工作区或已安装客户端。

## 已执行验证

- 本机 Xcode 27 / Flutter 3.35.6、Windows Flutter 3.35.6 / Dart 3.9.2 Release 构建；版本、入口、产品标识与 CPU 架构核对。每个 Mac 包 44 个 Mach-O 均为目标架构，深度严格验签、DMG 只读挂载内的签名和版本核对通过。
- 三平台包内 Node、engine、office、browser、isolation、codex 六项自检全部通过。Mac 原生 Bridge initialize 通过；实际 Node 运行脚本模型夹具，Mac arm64/x64 各 28 项通过，Windows 最终 30 项通过，均无跳过。Windows 使用普通交互令牌，`node --test --test-concurrency=1`，未禁用 AppContainer/Job 或审批。
- Windows `flutter pub get --enforce-lockfile` 后 `flutter build windows --release --no-pub`；与 Mac 的 225 个依赖版本、来源类型和 SHA256 一致，只将 registry URL 适配为构建机现有镜像。
- Windows 删除的 18 个重复/非目标文件实际不存在，合计 273170472 字节，实际兼容版 Codex 保留；应用文件树 874987602 字节。包内未发现 `.env`、`auth.json` 或社区数据库文件；不把有限文件名检查视为通用敏感数据扫描。
- 三个产物在本机重新计算 SHA256、Windows 与构建机摘要一致；`node --check` 检查改动的夹具，`git diff --check` 和本次文档本地链接检查通过。社区仓库不存在 `scripts/check-repo-hygiene.sh`，未运行该脚本。

## 构建中的异常与处置

1. Apple 起初返回协议缺失/过期 403；用户本人完成签署后两个包公证 Accepted。收尾脚本曾将 Accepted 判断写反，已纠正并直接给已通过的提交装订、验签，没有重复提交或改变产物签名策略。
2. Windows 普通 pub get 因镜像来源不同重新解析 17 个依赖版本；该候选不交付。最终候选固定当前 Mac lock 的版本与 SHA256，镜像 URL 适配后强制校验并重建。
3. 初始 Windows 30 项中 9 个 Shell 场景失败。独立诊断抓到 `local.command_timeout`（10000 ms）；相同真实引擎用例只改为生产默认 60000 ms 后通过。仅修正 Windows 测试等待预算，保留全部隔离、文件落盘和审批断言，未做业务实现的性能修复。
4. 超时修正后的完整回归曾 29/30 通过，`codex-missing-response-id` 在 2.45 秒返回 `zap.upstream_failure`。同包独立复测 3 次、最终完整 30 项复测均通过；原失败根因仍未确认，不宣称已修复、不自动重放用户失败轮次。原始失败、对照与最终日志保留在本机构建目录，踩坑记录见 [Windows 构建](../pitfalls/community-windows-build.md)。

Windows 安装器编译另有两条简体中文消息缺失警告（`ErrorFileHash2`、`ExtractionLabel`），Inno 使用默认英文文本；本轮未改动语言文件。本次创建的 6 个临时构建/诊断任务均已删除，原工作区和原构建 Runner 保留。

## 验证边界

本轮未做新安装/升级 UI、全部业务页面回归、真实付费模型请求、Windows 10 实机或 Windows ARM64 原生包；包内运行测试不能替代这些验收。里程碑二此前的未验收项仍以原记录为准。未重跑全部 Flutter/后台测试：本轮只改版本、文档及 Windows 集成夹具预算，没有改变生产业务代码。
