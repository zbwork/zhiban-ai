# zhiban_ui

知办通用 Flutter 控件、主题与平台尺寸工具，不包含页面路由、鉴权图片、支付、推送或 App 登录态。

App 通过相对 `path` 依赖使用此包，可导入 `package:zhiban_ui/zhiban_ui.dart` 或具体组件。调用方直接 import 本包，不经过 App 的兼容文件或聚合入口；仍依赖 App 服务的图片/移动导航控件从各自 App 文件单独导入。

`AppTheme` 保留现有字体选择与平台判断。使用方继续提供 `HarmonyOS Sans SC` 字体资源，使用 `UiToast` 时继续在应用入口安装 BotToast builder/observer；此包不携带字体二进制、不初始化全局服务。

在本目录验证（Flutter 3.35.6 / Dart 3.9.2 或兼容版本）：

```sh
flutter pub get
flutter analyze
flutter test
```

不要反向依赖 `apps/` 或通过相对路径引用包外源码。该包随 monorepo 交付，不单独发布到 pub.dev。
