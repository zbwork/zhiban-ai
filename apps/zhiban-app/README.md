> M1 平台入口：本目录只构建 macOS/Windows，默认 `lib/main.dart` 为桌面。共享业务与资源在 `packages/zhiban-client`，Android/iOS 与移动 UI 在私有 `apps/zhiban-mobile`。移动调试使用根 start-client.sh 的原设备 ID 或 VS Code zhiban-mobile 配置。

# 知办AI
基于Flutter的跨平台AI办公助手应用，支持移动端和桌面端。

## 技术栈
- **框架**: Flutter 3.35.6
- **主题**: 自定义，cupertino与material融合
- **UI**: 使用material 3规范， shadcn ui的目录组织组件。先手动封装通用按钮，后续考虑解耦为package
- **图标** 优先使用cupertino icons 结合 material icons 辅之 lucide_icons 
- **状态管理**: Riverpod
- **路由管理**: go_router
- **窗口管理**: window_manager

## 环境要求
- Flutter 3.35.6（建议使用 fvm 锁定版本）
- Dart SDK 随 Flutter 自带
- 桌面端：macOS 需 Xcode，Windows 需 Visual Studio（Desktop C++ workload）
- 移动端：Android Studio / Xcode

## 启动方式

```bash
# 1. 拉取依赖
flutter pub get

# 2. 运行（默认设备，调试模式 = dev 环境）
flutter run

# 3. 指定设备
flutter devices              # 查看可用设备
flutter run -d macos         # macOS 桌面
flutter run -d windows       # Windows 桌面
flutter run -d chrome        # Web
flutter run -d <device-id>   # iOS/Android
```


### 切换环境 / 覆盖 API 地址

`APP_ENV` 只选择环境，TEST/PROD 的 API 与管理后台地址已迁入同级私有配置仓库，源码默认为空。商业开发入口会同时加载两套端点（见 `lib/config/app_config.dart`）：

```bash
# 从 apps/zhiban-app 执行，选择环境（dev | test | prod）
bash ../../start-client.sh --environment test -d macos

# dev 默认指向本地 Agent Bus:
# http://localhost:8080/api/agent-bus/v1

# 覆盖某个环境的 API 地址
flutter run \
  --dart-define=APP_ENV=dev \
  --dart-define=API_BASE_URL_DEV=http://localhost:8080/api/agent-bus/v1
```

不传 `APP_ENV` 时默认 debug = `dev`、release = `prod`；该默认规则不注入服务器地址。商业入口缺少私有文件时会直接失败。

如果曾在关于页隐藏入口切过环境，客户端会持久化 `app_env_override`，优先于编译时 `APP_ENV`；需要在该入口切回期望环境并重启。退出登录不会清除该项。

### 本地开发时让「本地开发工具」正常接入蜂桥（Codex / Claude）

**2026-09-29 更新：可以直接在 Flutter Debug 中使用正式签名 Bridge。** 在仓库根目录运行：

```bash
ZHIBAN_FORCE_ENV=test sh start-client.sh --environment test --signed-bridge "/Applications/知办AI.app/Contents/Helpers/ZhibanLocalBridge.app/Contents/MacOS/zhiban-local-bridge"
```

此入口保留 Debug / 热重载和原来的私有配置加载，只把 Bridge 路径指向已安装正式版；不会关闭验签，也不要求把后端切到生产。必须停止旧调试进程再重启，热重载不能改变此编译参数。正式版 helper 较旧时先更新正式版；此方式不包含本地未签名的 Bridge 源码改动。`--signed-bridge` 与 `--allow-unsigned-bridge`、Release/Profile 互斥。

注意三个概念独立：Debug/Release 是构建方式；dev/test/prod 是后端环境；Bridge 签名决定能否启动/使用钥匙串。2026-09-29 起 Bridge 已补 dev Profile，**需要使用包含此修改的签名 helper**（旧正式版仍只有 test/prod）。本地端到端调试：本机 Bus 设置 `AGBUS_LOCAL_CODING_ENABLED=true`、`AGBUS_LOCAL_CODING_CODEX_PROFILE_VERSION=2026.09.07.1`、`AGBUS_LOCAL_CODING_CLAUDE_PROFILE_VERSION=2026.09.07.1`、`AGBUS_EXTERNAL_URL=http://localhost:8080` 并重启；客户端将上述命令中的两处 `test` 改为 `dev`；也可以使用从新签名包完整提取的 `ZhibanLocalBridge.app`，无需安装整个正式版。设备注册和换票走 localhost，模型推理走当前账号获授权的蜂桥；使用既有测试身份，不借用生产授权。下面“必须去正式版点击”的描述仅适用于未传 `--signed-bridge` 的旧流程。


#### 旧流程参考：未指定外部签名 Bridge

以下记录仅适用于未传 `--signed-bridge`、仍使用 Debug 内嵌 ad-hoc helper 的情况。

> 2026-09-18 / 09-20 在干净检出和真机上按本节逐条实测过（macOS）。**两步：① 用 `start-client.sh` 启动，App 才带得上 Bus 地址；② 一键接入这一下，用已安装的正式版（签名包）切到测试环境去点。都不用改代码、不用手改 Codex / Claude 的配置。**
>
> 一句话版：**写代码用 `sh start-client.sh` 起调试版；接蜂桥就打开装好的正式版、切到测试环境点一次一键接入。** 两个 App 共用登录，互不耽误。已安装的正式版在测试环境和生产环境下一键接入都正常（地址打包时就编进去了，直接打开即可，不需要这个脚本）；`start-client.sh` 只解决调试版「连得上 Bus」，调试版自己的「一键接入知办」按钮在哪个环境都走不通。

**第一步：让本地跑的 App 连得上 Bus**

本地跑起来「访问不了」，几乎都是因为**地址没编进去**：源码里测试 / 生产环境的 Bus 地址（`API_BASE_URL_TEST` / `API_BASE_URL_PROD`）以及管理后台、OAuth、协议链接等默认全是空的，真实值只在私有配置仓库 `zhiban-ai-config` 里，打包时由 CLI 注入——所以正式包里有，裸 `flutter run` 出来的没有（dev 环境则指向 `http://localhost:8080`，没有共享的「开发环境 Bus」）。

1. 把私有配置仓库 `zhiban-ai-config` 检出到**与本仓库同级**的目录（`start-client.sh` 按 `../zhiban-ai-config` 找）。
2. 首次在这台 Mac 上构建前：`flutter` 和 CocoaPods 的 `pod` 要在 `PATH` 里；在 `apps/zhiban-app` 下执行一次 `bash scripts/install_dingrtc_macos_sdk.sh`（DingRTC 框架不在 git 里，缺了编译不过；脚本会下载 SDK 并跑 `pod install`）。干净检出首次调试编译约 4 分钟。
3. 在仓库根目录启动：

   ```bash
   sh start-client.sh          # 默认 test 环境 + macOS，自动注入测试 / 生产两套地址
   ```

4. 启动后先看终端里的 `[BOOT] env=… api=…` 这一行，确认环境和地址是你要的（为什么必须看，见下面「两个坑」）。

**第二步：接入蜂桥——用已安装的正式版切到测试环境去点**

本地调试版自己走不通「一键接入知办」：接入的第一步是设备授权，Bridge 要把设备身份存进 macOS 的数据保护钥匙串（契约 [local-coding-tools-contract §3.2–3.4](../../docs/contracts/local-coding-tools-contract.md)），只有正式证书签名的程序才有这个权限；调试构建内嵌的 Bridge 是 ad-hoc 签名，且有意不提供开发用的替代存储。已安装的正式版是签名包、里面同时编进了测试和生产两套地址，所以让它来做这一下：

1. 打开已安装的「知办AI」→ 左上角头像 → 设置 → 关于我们，**连点 5 次「应用信息」**，下面出现「切换环境」，选测试环境。
2. **Cmd+Q 完全退出再重新打开**（只退出登录不会切换环境），用测试环境的账号登录。
3. 进「本地开发工具」，在要用的卡片上点「一键接入知办」（显示「需要处理」就点「修复并重试」），走到「运行正常」即可。之后这台机器上的 Codex / Claude 用的就是你这个测试账号的蜂桥 Key（与生产是同一个中转站；测试租户的 Key 可能在 `default` 分组，模型列表以实际为准）。

2026-09-18 用 1.3.0 签名包实测通过：测试环境 Bus 留下了设备授权签发和换 Key 成功的审计记录。

**之后照常用调试版开发**

- 调试版与已安装的正式版是同一个应用标识（`cn.qkfintech.zhiban`），**共用登录状态和环境选择**：正式版切到测试环境并登录后，`sh start-client.sh` 起来的调试版就是「测试环境 + 已登录」。接入完成后可以把正式版退掉，只开调试版。
- Codex / Claude 取 Key 用的是 `/Applications/知办AI.app` 里那个签名的 Bridge，App 关着也能刷新，和调试版无关。**平时跑调试版不用加 `--allow-unsigned-bridge`**：不加时调试版根本启动不了自己那个未签名的 Bridge，完全碰不到这份授权。加了也不会弄坏它（2026-09-20 实测：带选项运行、后台的自动重新接入和维护都跑过、甚至在调试版里点了「一键接入知办」，正式版做好的接入依然有效——授权还在、`~/.codex/config.toml` 没被改写、服务端没有发生授权轮转），只是调试版的页面状态不代表这台机器真实的接入状态。
- 行为与线上一致：接入绑定「设备 + 账号 + 企业 + 环境」，同一时间只接入一个身份。**退出登录会清掉本机授权**，重新登录后回到正式版里再点一次接入；换账号 / 企业、或切回生产环境后同样要再点一次；已打开的终端和桌面端要重开才会用上新身份。

**两个坑（都源于调试版与正式版共用一份设置）**

- **会悄悄连到别的环境。** 持久化的环境选择优先于启动参数，`start-client.sh` 默认的 test 会被它盖掉（两种都实测过）：正式版停在生产环境时，调试版实际连的是生产；正式版停在开发环境时，调试版连的是 `http://localhost:8080`，本机没起 Bus 就报「无法连接到服务器」。以终端的 `[BOOT] env=… api=…` 为准；要改就在正式版的关于页里切，或带 `ZHIBAN_FORCE_ENV=test sh start-client.sh` 启动一次（只有调试版认，会持久化；之后要回生产记得用 `ZHIBAN_FORCE_ENV=prod` 或关于页改回去）。
- **登录状态互相覆盖。** 在调试版里登录 / 退出，正式版的登录也跟着变，反之亦然。

**只在改「本地开发工具」页面本身时**

```bash
sh start-client.sh --allow-unsigned-bridge
```

不加这个选项，调试版会用正式证书的标准校验内嵌 Bridge，页面报「本地连接组件签名校验失败，请更新或重新安装知办」。这个选项只在非 Release 构建生效，只跳过这道校验，不涉及任何凭据存储；`start-client.sh` 仍然拒绝其他 `--dart-define`。加上后能调页面、卡片状态和本机检测，但授权与换 Key 仍然走不通（原因同上）：在调试版里点「一键接入知办」，进度弹框会停在「检测服务连接」/「校验配置与凭证」，报「本地连接组件未能完成操作，请重试 · 错误码 rpc_-32603」——这是调试包的限制，不是测试环境坏了；同样的操作在正式版里是通的。旧版 Bridge 没有 dev 网关配置档，本机 Bus 也默认关闭 F31；最新签名 Bridge 的本地 dev 联调方式见本节开头。Windows 的凭据存储走 DPAPI、不依赖代码签名，理论上不受这条限制（未实测）。

**改了接入 / 授权逻辑，要端到端验证自己的代码**

代码推到分支，在打包机上用打包 CLI（`apps/zhiban-cli/bin` 下 `dart run zhiban.dart`，见下文「CLI 交互式打包」）出一个签名包，交互菜单里环境选 **test**，装到**测试机**上验证——一键接入会改写那台机器真实的 `~/.codex/config.toml`、`~/.claude/settings.json` 和 Claude 桌面端配置，不要拿自己日常开发的机器验未经验证的接入代码。

### 本地开发时的其他模型能力（对话、数字员工）与本机 Bus

App 不直连蜂桥：成员的模型 Key、分组、额度都由**所连环境的 Agent Bus** 向蜂桥开通并下发（见[成员 Key 获取指南](../../docs/contracts/beebridge-member-api-key-guide.md)）。只要 App 连到一个接好蜂桥的 Bus，这些能力就能用，不需要为此连生产。

**只改 App：用测试环境**

`sh start-client.sh`（默认 test 环境）。共享测试环境的 Bus 已接好蜂桥（2026-09-18 核对：租户与成员 Key 正常开通，模型调用成功）；测试账号与生产互相独立，新租户首次使用模型时自动开通，不用手工建 Key。测试环境对接的是真实中转站、消耗真实额度，不要用它跑大批量压测；成员 Key 的分组可能与生产不同（实测测试租户的 Key 在 `default` 分组，26 个模型，Claude / GPT / Gemini / DeepSeek 都有）。

连不上时先对这两条：裸 `flutter run` 默认是 dev 环境，连的是 `http://localhost:8080`——**没有共享的「开发环境 Bus」**；不经 `start-client.sh`（没带私有配置）构建出来的包，TEST / PROD 地址是空的，在关于页切到测试环境同样连不上。

**同时要改 Bus：本机起 Bus + dev 环境（蜂桥配置是现成的，不用手工配环境变量）**

```bash
# 仓库根目录执行；需要同级的私有配置仓库 zhiban-ai-config
bash ../zhiban-ai-config/environments/development/commercial-up.sh "$PWD" bus --check   # 预检：配置文件齐全 + Redis 可达，不起进程
./start.sh bus                          # 本机 Bus → :8080，日志出现 "bus http listening" 且 /healthz 返回 200 即起来了
sh start-client.sh --environment dev    # App 连本机 Bus（localhost:8080）
./stop.sh bus                           # 用完停掉
```

- `./start.sh bus` 经私有启动器加载 `zhiban-ai-config/environments/development/config/agent-bus/.env` 加 test 环境的 YAML。蜂桥需要的变量都在这份 `.env` 里：管理地址 `AGBUS_BEEBRIDGE_MANAGEMENT_BASE_URL`、模型地址 `AGBUS_LLM_BASE_URL`、平台 PAT `AGBUS_BEEBRIDGE_PLATFORM_PAT`、数据密钥 `AGBUS_BEEBRIDGE_KMS_DATA_KEY`、额度换算 `AGBUS_BEEBRIDGE_QUOTA_PER_CNY_CENT_NUMERATOR/DENOMINATOR`。2026-09-18 在干净检出上按上面的命令实测：预检通过；`./start.sh bus` 自动编译、约 3 秒就绪、`/healthz` 200；用测试环境账号登录本机 Bus 后取到了蜂桥成员 Key，用这把 Key 直连中转站拉模型、真实调用均成功；调试版 App 以 dev 环境连上本机 Bus 后登录、蜂桥初始化、可选模型列表均正常；`./stop.sh bus` 正常停止。字段含义见 [agent-bus-configuration · BeeBridge](../../docs/architecture/agent-bus-configuration.md)。
- 这份配置连的是**共享测试库和测试 Redis**，账号、租户、成员 Key 和测试环境是同一份：用测试环境的账号登录即可。由此带来三条约束：要能访问测试内网（公司网 / VPN）；**不要改数据密钥**，改了就解不开库里已存的成员 Key 密文；本机 Bus 的后台任务作用在共享数据上，调试完及时 `./stop.sh bus`。
- 启动日志里这两类是预期的，不影响成员走蜂桥：`LLM base_url or api_key empty, llm adapter disabled…`（开发配置刻意不带平台级模型 Key，只影响内置 llm 运行时、向量发现这类平台级能力）；`wukong connection snapshot failed` 以及 App 侧 `im/credentials` 返回 502（没起本地 WuKongIM；需要 IM 实时能力时先 `./wukongim_start.sh`，要 Docker）。
- 不用这份现成配置、自己另起一套时最容易踩的坑：管理地址与模型地址是两个不同的入口，不能互相代替——管理地址填成模型入口，租户开通会永久卡在 `user_creating`；缺模型地址表现为「模型列表看得到、发消息被拒」；数据库迁移要执行到 000136 之后，否则取 Key 报 `member_key_unavailable`。

**本机网络**：蜂桥的模型入口需要直连。开着代理软件的 TUN / 虚拟网卡模式会连不上，关掉即可；系统代理模式下用 App 里的代理例外。


### CLI 交互式打包

继续使用 `dart run zhiban.dart`（`apps/zhiban-cli/bin` 目录），平台、版本和环境选择不变。Android/macOS 打包已在内部调用私有仓库的共享构建脚本，自动加载所选环境及签名配置，不需要手工换用 shell 打包命令。预检发现缺少私有配置会在修改版本前停止。

### 常用命令

```bash
flutter analyze              # 静态检查（代码改动较大时务必执行）
flutter test                 # 单元测试
flutter clean                # 清理构建产物
```

## macOS 打包

### 本地编程工具 Bridge

Debug Xcode 构建会执行 `macos/LocalCodingBridge/build_and_embed.sh`，把 Go Bridge 作为 ad-hoc app-like nested helper 放入：

```text
知办AI.app/Contents/Helpers/ZhibanLocalBridge.app/Contents/MacOS/zhiban-local-bridge
```

可先独立验证构建与包结构：

```bash
bash macos/LocalCodingBridge/test_build_and_embed.sh
```

Debug ad-hoc helper 只用于双架构、Hardened Runtime、stdio 与 L0 检测验证，不携带 data-protection Keychain 所需的受限 entitlement。Profile/Release 默认 `LOCAL_CODING_BRIDGE_EMBED=NO`，避免未配置 helper 独立签名时把不可发布的 nested code 带进安装包。

F31 入口（头像弹框「本地开发工具」）2026-09-11 起在桌面端默认显示，`--dart-define=LOCAL_CODING_TOOLS_ENABLED=false` 才隐藏；两个 profile version 默认 `2026.09.07.1`（与 Bus 同值）。要让 Release 包里真的带上可用的 Bridge，`zhiban package / upload`（`apps/zhiban-cli`）会自动完成：profile 用仓库里的 `macos/LocalCodingBridge/ZhibanLocalBridge-DeveloperID.provisionprofile`（只含公开信息，2044 年到期），构建前选择本 Team 钥匙串内有效且获该 profile 授权的 Developer ID Application 身份，导出后校验 helper 签名、embedded.provisionprofile 与 keychain-access-groups；发版机需安装 **Go**（`brew install go`）及获 profile 授权的证书和私钥。只有相同 Team/证书名称仍可能不匹配，详见 [证书与 profile 不匹配排查](../../docs/pitfalls/macos-data-protection-keychain-requires-bundled-helper.md)。手工跑 `xcodebuild archive` 时要自己传：

```text
LOCAL_CODING_BRIDGE_EMBED=YES
LOCAL_CODING_BRIDGE_SIGNING_MODE=distribution
LOCAL_CODING_BRIDGE_PROVISIONING_PROFILE=/absolute/path/to/helper.provisionprofile
LOCAL_CODING_BRIDGE_APP_IDENTIFIER_PREFIX=<App-ID-Prefix-with-trailing-dot>
LOCAL_CODING_BRIDGE_SIGN_IDENTITY=<Developer ID Application identity; required explicitly>
```

helper profile 必须先通过 macOS `profiles validate -type provisioning` 的 Apple 授权校验，再检查未过期、精确授权 `cn.qkfintech.zhiban.local-bridge` App ID，并以精确同名 Keychain group 或当前 App Identifier Prefix 的 `*` allowlist 授权该 group；其他 Team/prefix 的通配不接受。派生到 helper 代码签名的 Keychain entitlement 始终是精确 group，不写入通配符。profile 还必须包含实际签名 leaf certificate，Team ID 必须是 `NUHSLZ4RU4`。helper identity 不继承外层 App，且必须满足 Developer ID Application requirement。任一输入缺失或不匹配时构建直接失败，不会降级 ad-hoc。随后还必须验证最终 App 的 nested signature、helper built entitlements、真实 Keychain add/read/delete、公证与 staple，完成前不得把 `LOCAL_CODING_TOOLS_ENABLED` 打开。

Release archive 会在 CocoaPods 嵌入 framework 之后执行 `macos/SparkleSigning/sign_nested_code.sh`，按 Sparkle 官方要求从 XPC/helper 到 framework 重签 nested code。该阶段只在 Xcode `ACTION=install` 的 archive 流程生效，必须得到 Developer ID Application、当前 Team ID、Hardened Runtime 和 secure timestamp，否则 fail closed。不得改成 `codesign --deep`；可用 `bash macos/SparkleSigning/test_sign_nested_code.sh` 验证签名顺序与 Xcode phase 位置。

### 前置准备

| 依赖 | 安装方式 | 说明 |
|---|---|---|
| Xcode | Mac App Store | 含 macOS SDK、签名工具链 |
| Flutter | `fvm install 3.35.6` | 锁定版本 |
| Go | https://go.dev/dl/ | 版本满足 `apps/zhiban-local-bridge/go.mod`（当前 1.26.1），加入 PATH；仅构建机需要 |
| create-dmg | `brew install create-dmg` | 生成 DMG 安装镜像 |
| Sparkle 签名工具 | Pods 自带 | 路径 `macos/Pods/Sparkle/bin/sign_update` |
| EdDSA 私钥 | macOS Keychain | 名为 "Private key for signing Sparkle updates"，见下方迁移说明 |

### EdDSA 签名密钥迁移（新 Mac 首次配置）

Sparkle 的 EdDSA 私钥存在 macOS Keychain 的「通用密码」项中，用 Sparkle 自带工具迁移：

```bash
# === 在已有签名机上导出 ===
./macos/Pods/Sparkle/bin/generate_keys -x sparkle-private-key.txt
# 通过 AirDrop / U盘 传输到新 Mac

# === 在新 Mac 上导入 ===
./macos/Pods/Sparkle/bin/generate_keys -f sparkle-private-key.txt

# 验证：能输出签名即成功
./macos/Pods/Sparkle/bin/sign_update 任意文件.dmg

# 传输完成后立即删除私钥文件
rm sparkle-private-key.txt
```

macOS 和 Windows 共用同一密钥对，公钥已固化在 `Info.plist`（`SUPublicEDKey`）和 `winsparkle_bridge.cpp`（`kEdDsaPublicKey`）。

### 打包流程

使用 CLI 完成 `pubspec.yaml` 版本更新、Flutter 构建、Xcode archive、Developer ID 签名、DMG 生成、公证和 staple。`package` 只打包，不上传或发布：

```bash
cd apps/zhiban-cli
dart run bin/zhiban.dart package
```

版本号、build 号和环境在交互菜单选择；App 名、Team ID 等由 CLI 维护。输出位于 `apps/zhiban-app/build/macos-release/`，包括 `.xcarchive`、导出 App、DMG 和 Sparkle 签名。源码及同级 `zhiban-ai-config` 必须配套更新；若预检报 Flutter 不识别 `--check`，见[预检参数排查](../../docs/pitfalls/macos-package-preflight-flag.md)。发布证书及私钥缺失时在编译前停止，不将未签名编译产物当作正式安装包。

```bash
# 1. 用 Xcode 打包
#    打开 macos/Runner.xcworkspace → Product → Archive
#    Archive 完成后在 Organizer 中选择 → Distribute App
#    选「Copy App」导出 .app 到本地目录

# 2. 生成 DMG
create-dmg \
  --volname "ZhiBan" \
  --background "bg.png" \
  --window-pos 200 200 \
  --window-size 500 462 \
  --icon-size 80 \
  --icon "知办AI.app" 100 185 \
  --hide-extension "知办AI.app" \
  --app-drop-link 375 185 \
  "ZhiBanAI_release_1.0.0_10012_macos.dmg" \
  "知办AI.app/"

# 5. 生成 EdDSA 签名（用于 Sparkle 自动更新验签）
./macos/Pods/Sparkle/bin/sign_update ZhiBanAI_release_1.0.0_10012_macos.dmg
# 输出: sparkle:edSignature="xxxx" length="12345678"

# 6. 在 Admin 后台「客户端版本」创建版本记录
#    - 粘贴签名 → 上传 DMG → 发布
```

---

## Windows 打包

### 前置准备

| 依赖 | 下载地址 | 安装说明 |
|---|---|---|
| Visual Studio | https://visualstudio.microsoft.com/ | 安装时勾选「使用 C++ 的桌面开发」工作负载 |
| NuGet | https://www.nuget.org/downloads | 下载 `nuget.exe`，放到 PATH 中；Flutter Windows 插件编译依赖 |
| Flutter | `fvm install 3.35.6` | 锁定版本 |
| WinSparkle SDK | https://github.com/vslavik/winsparkle/releases | 解压到 `windows/runner/third_party/WinSparkle/`（已 .gitignore），目录需含 `include/winsparkle.h` + `x64/WinSparkle.lib` + `x64/WinSparkle.dll` |
| Inno Setup 6 | https://jrsoftware.org/isdl.php | 安装后 `iscc` 可用；需下载 `ChineseSimplified.isl` 放到 `{app}/Languages/` |

### 打包流程

```bash
# 1. 构建 Release
flutter build windows --release
# 产物在 build\windows\x64\runner\Release\ZhiBanAI.exe
# CMake 自动编译并校验 zhiban-local-bridge.exe，放在主程序旁；无需手工复制。
# Bridge 构建或 Windows x64 stdio initialize 校验失败时，整个构建中止。
# Release VC++ 运行库也由 CMake 从 VS 再分发目录复制到主程序旁。

# 2. 准备 Microsoft 签名的 WebView2 x64 离线安装器（PowerShell）
pwsh -File scripts/prepare_webview2_windows.ps1
# 安装器会检查现有 Runtime，仅缺失时安装；终端用户无需联网补装。

# 3. 打安装包（在 windows/packaging/ 目录下）
iscc /DMyAppVersion=1.0.0 installer.iss
# 产出：Output\zhiban-setup-1.0.0.exe
# 也可不传 /D，自动从 ZhiBanAI.exe 读取版本号
# 缺少 Bridge、Local Agent、VC++ 或预览组件时 Inno Setup 直接失败。

# 4. 生成 EdDSA 签名（在 macOS 签名机上，复用同一密钥对）
./macos/Pods/Sparkle/bin/sign_update zhiban-setup-1.0.0.exe
# 输出: sparkle:edSignature="xxxx" length="12345678"

# 5. 在 Admin 后台「客户端版本」创建版本记录
#    - 平台选 Windows → 粘贴签名 → 上传 exe → 发布
```

### 注意事项

- **WinSparkle 未配置时**：Windows 不编入更新 bridge，`cn.qkfintech.zhiban/update` 运行期为 MissingPlugin，不影响其余功能
- **未做 Authenticode 代码签名**：安装/更新首启会有 SmartScreen「未知发布者」提示，用户点「仍要运行」即可
- **签名密钥**：macOS 和 Windows 共用同一 EdDSA 密钥对，私钥在 macOS Keychain，公钥在 `winsparkle_bridge.cpp` 的 `kEdDsaPublicKey` 和 `Info.plist` 的 `SUPublicEDKey`

### 独立桌面入口

默认 main.dart 只装配桌面路由。共享业务在 packages/zhiban-client，Android/iOS 与移动 UI 在 apps/zhiban-mobile；两端使用同一 core/UI/client 实现。移动启动与 Archive 说明见 [私有移动 App](../zhiban-mobile/README.md)。

Xcode 27 搭配 Flutter 3.35.6 时需将上游逐架构 lipo 校验修复应用于隔离 SDK 副本：`git apply --unidiff-zero "$ZHIBAN_SOURCE_ROOT/apps/zhiban-app/tool/flutter-3.35.6-xcode27-lipo.patch"`（ZHIBAN_SOURCE_ROOT 为仓库绝对路径，在 SDK 副本根目录执行）。删除副本 bin/cache/flutter_tools.snapshot 和 flutter_tools.stamp，再运行副本 bin/flutter --version 重新构建工具，随后使用副本的 flutter；不跳过架构校验，不修改用户 SDK。详见[工具链问题](../../docs/pitfalls/macos-build-lockfile-and-cold-go-cache.md)。
