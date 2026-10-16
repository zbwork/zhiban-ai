# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Rules
1. 技术栈：路由 go_router，状态管理 Riverpod，网络请求 Dio，消息提示 BotToast，本地存储 SharedPreferences，loading 使用 Cupertino 风格（`CupertinoActivityIndicator`）
2. Plan mode 生成的计划文件统一放到 `docs/plans/`，命名格式 `序号-主题.md`（如 `01-feature-name.md`），Plan mode 结束后立即复制
3. 新增 UI 组件时，优先复用 `packages/zhiban-ui` 下的共享组件（通过 `package:zhiban_ui/zhiban_ui.dart` 或具体模块直接导入），确认无合适组件后再自行实现
   - 文本输入：`UiInputField`（单行/多行/字数统计）
   - 下拉选择：`UiSelect`（单选，支持 icon、placeholder）
   - 搜索框：`UiSearchField`
   - 颜色 token：`UiFieldStyle`（`focusBorderColor`、`hoverBorderColor`、`hoverFillColor`、`disabledFillColor`）
   - **禁止**在业务组件里写死边框颜色、填充色、placeholder 色——一律取 `Theme.of(context).colorScheme` + `UiFieldStyle`，保证暗色模式安全
   - 输入类组件不使用 focus 光晕（`UiFieldWrapper` 已移除）；focus 态仅通过 `InputDecoration.focusedBorder` 变色表达
   - 圆角：输入框/选择框默认 `10`，弹出菜单跟随 `widget.borderRadius`
4. 代码改动较大时，运行 `dart analyze` 检查是否有报错，有则立即修复后再继续
5. 新增组件时参考 shadcn ui 的 UI 和交互，不要自己臆想
6. hover 背景色切换使用普通 `Container`，不要用 `AnimatedContainer`——鼠标快速移动时动画残留会导致两个 item 同时高亮
7. 业务层网络图片加载统一使用 `UiNetworkImage`（`packages/zhiban-client/lib/widgets/ui/ui_network_image.dart`），不要直接使用 `CachedNetworkImage`
8. 图片大图预览：桌面聊天中的图片/文件统一进入 `AttachmentPreviewScope` 右侧预览（F06 §5.4）；移动端与没有聊天侧栏的头像等场景仍使用现有 `UiImagePreviewDialog` / `showChatImagePreview`，不得给桌面聊天图片另开弹层。
9. Dialog 头部统一使用 `UiSheetHeader`，并保持垂直方向 `start` 对齐布局（避免标题与右侧操作按钮出现垂直居中错位）
10. 移动端子流程用全屏页面（`context.push(RoutePaths.xxx)`），桌面端用 Dialog——settings 页已建立此分支模式，新功能遵循同样约定
11. 新增路由时，必须同时在 `route_paths.dart`（常量）和 `app_router.dart`（GoRoute 注册）中添加，两处缺一不可
12. 移动端列表的下拉刷新 / 上拉加载统一使用 `SmartRefresher` + `RefreshConfiguration`，参考 `packages/zhiban-client/lib/pages/digital_employee/widgets/digital_employee_gallery.dart` 中的 `SpringDescription`、`ClassicHeader`、`ClassicFooter` 配置
13. 全屏子页面的 AppBar 统一使用 `UiPageBar`（`packages/zhiban-client/lib/widgets/ui/ui_page_bar.dart`），自带 `CupertinoIcons.chevron_left` 返回按钮；需要自定义返回行为用 `onBack`，需要完全替换 leading 用 `leading` 参数，不要手写 `AppBar` + `IconButton`
14. Material 水波纹在 `AppTheme._buildTheme` 全局禁用（`NoSplash.splashFactory`）；业务组件不得新增局部 `splashColor` / Ink splash factory。保留 hover、键盘 focus、选中态和必要的静态按压反馈，详见 `../../docs/standards/zhiban-app-interaction-feedback-standard.md`。
15. 移动端开发、预览与验收复用用户通过 VS Code 已启动的 iOS 模拟器及调试应用，沿用设备 ID、入口和 `--dart-define` 等启动参数。未经用户另外要求，不新建或启动额外模拟器，不以默认环境覆盖现有配置，不结束用户的调试进程。设备集成测试与现有调试会话的边界见 `../../docs/standards/zhiban-app-platform-page-separation-standard.md` 第 5 节。

### Entry & Bootstrap

`lib/main.dart` starts `main_desktop.dart`. The private mobile entry and native projects live in `apps/zhiban-mobile`. Shared `packages/zhiban-client/lib/app_bootstrap.dart` requires an explicit platform router and bootstraps in this order:
1. Checks `SessionService` for a stored token
2. Initializes `WindowController` (desktop only) with login vs. home window sizing
3. Passes `initialLocation` (`/chat` or `/login`) to `createAppRouter`

`ProviderScope` is wrapped in a `ValueListenableBuilder` keyed on `sessionScopeKey` (`packages/zhiban-client/lib/services/session_service.dart`). Incrementing `sessionScopeKey` (via `resetSessionScope()`) tears down and re-creates all Riverpod providers — this is the logout mechanism.

### Routing

`lib/routes/app_router.dart` assembles desktop pages in `MainLayout`; `apps/zhiban-mobile/lib/routes/mobile_app_router.dart` assembles mobile pages in `MobileMainLayout`. Both reuse `packages/zhiban-client/lib/routes/session_router.dart` for authenticated guards and common routes; `SessionLayout` owns shared session initialization, unread totals and app-resume handling. All page transitions use `NoTransitionPage`. Route constants live in `packages/zhiban-client/lib/routes/route_paths.dart`.

Current routes: `/login`, `/chat`, `/chat/history`, `/chat/conversation`, `/digital-employee`, `/inspire`, `/task`, `/workbench`, `/settings`, `/settings/edit-profile`, `/settings/about`, `/settings/profile-details`, `/settings/login-status`, `/settings/recharge`, `/settings/wallet-transactions`, `/drive`, `/drive/detail`, `/browser`.

### Layout

`lib/layout/main_layout.dart` renders the left navigation sidebar (`_NavItem`) and the content area. The sidebar uses `GoRouterState.of(context).matchedLocation` to determine the active route.

### State Management (Riverpod)

Pattern throughout: `AsyncNotifierProvider` for async server state, `StateProvider` for simple UI state.

Key providers in `packages/zhiban-client/lib/pages/chat/providers/chat_providers.dart`:
- `openClawInstanceProvider` — polls OpenClaw backend until `isReady`; other providers depend on it
- `agentsProvider` / `selectedAgentProvider` — agent list and selection; `selectedAgentProvider` is intentionally not reset by `conversationsProvider` refreshes
- `conversationsProvider` — conversation list; refreshed on demand (WuKong realtime bridge: reconnect/gap, conversation events, app-resume — see `conversation_realtime_bridge.dart`), no periodic polling; exposes `clearUnreadLocally`, `patchConversation`, `prepend`
- `chatProvider` (`ChatNotifier`) — active conversation state, message history, SSE streaming, file uploads

**Riverpod + lifecycle rule**: Never call `ref.read/watch` inside `dispose()`. Cache needed provider values in a State field, keep it updated via `ref.listen` in `build()`, then read the field in `dispose()`.

### Chat / SSE Streaming

`ChatNotifier.send()` → `ChatService.sendMessage()` (REST) → `ChatService.streamMessage()` (SSE). Stream events (`phase`, `reasoning`, `message`, `tool_call`, `tool_result`, `usage`, `done`, `stopped`, `error`) are processed in `_handleStreamEvent` and applied to the last assistant message's `timelineEntries` list.

`_mergeRuntimeContext` preserves timeline / usage / stream timestamps when a `conversationsProvider` refresh triggers a `build()` rebuild that would otherwise overwrite live streaming state with a clean REST history response.

### Window Management

`WindowController` (singleton at `packages/zhiban-client/lib/window/window_controller.dart`) manages macOS/Windows window sizing:
- Login window: fixed 480×640, not resizable
- Home window: initial 1200×820, min 900×620, resizable; clamped to screen visible area
- `setOverlayWidth(width)` expands/contracts the window right-edge when the chat history panel opens/closes; uses `_appliedOverlay` delta to avoid cumulative drift across multiple toggles

### Networking

Request/refresh protocol implementations live in `packages/zhiban-core/lib/{network,session}/`. Import them directly; do not recreate App forwarding files. `packages/zhiban-client/lib/services/session_runtime.dart` injects `AppConfig`, SharedPreferences and one shared `TokenRefresher` into the regular/sensitive clients. Keep Flutter session/window composition in zhiban-client and platform route/cleanup adapters in each App; never add Flutter, mobile push or App dependencies to core. See `../../docs/standards/shared-dart-session-boundary.md`.

Mobile push start/revoke is supplied by the entry point through `SessionPushLifecycle` before session validation; Auth/Session must not import the mobile push coordinator directly. Desktop keeps the default no-op hooks.

`packages/zhiban-client/lib/network/network.dart` — singleton `Dio` instance with:
- `connectTimeout` / `sendTimeout`: 180s
- `receiveTimeout`: 900s (long AI streaming responses)
- `validateStatus`: accepts all `< 500` responses (4xx handled in app layer)

`RequestInterceptor` injects `Authorization: Bearer <token>` and sets `baseUrl` from `AppConfig.apiUrl()` per request.

### Environment / Config

`packages/zhiban-client/lib/config/app_config.dart` reads `APP_ENV` dart-define. Defaults to `AppEnv.dev` in debug mode, `AppEnv.prod` in release. API and admin web endpoints use separate DEV/TEST/PROD dart-defines. The settings page can override the environment at runtime, so commercial builds retain both TEST and PROD endpoint sets. Policy/OAuth/WeChat/push fields are shared compile-time settings.

Token stored in `SharedPreferences` under key `"token"`. `RequestInterceptor` caches it in a static field; call `RequestInterceptor.clearTokenCache()` when the token changes.

### UI Components

Shared controls and themes live in `packages/zhiban-ui`: import `package:zhiban_ui/zhiban_ui.dart` or a specific module directly. Shared data models live in `packages/zhiban-core`. Do not add App forwarding files for these packages. Business `UiImagePreview`, `UiNetworkImage`, `UiPageBar` and `UiPullToRefresh` live under `packages/zhiban-client/lib/widgets/ui/`; mobile image gestures remain private. Import their files directly.

#### 输入类组件统一规范

所有输入/选择控件共用一套视觉语言，核心文件：

| 文件 | 职责 |
|---|---|
| `ui_input.dart` | 文本输入（含字数统计） |
| `ui_search_field.dart` | 搜索框 |
| `ui_select.dart` | 下拉选择 |
| `ui_field_style.dart` | 颜色 token 静态方法（border / fill） |

**颜色规则：**
- 默认边框：`scheme.outlineVariant.withValues(alpha: 0.5)`
- disabled 边框：`scheme.outlineVariant.withValues(alpha: 0.4)`
- focus 边框：`UiFieldStyle.focusBorderColor(scheme)`（primary × 0.45，宽 1.5）
- hover 边框：`UiFieldStyle.hoverBorderColor(scheme)`（primary × 0.4）
- placeholder：`scheme.onSurfaceVariant.withValues(alpha: 0.45)`（由 `InputDecorationTheme.hintStyle` 全局注入）

**自定义字段 checklist（新增输入类控件时逐项确认）：**
- [ ] 边框/填充色取 `ColorScheme` token，不写死 hex
- [ ] disabled 态走 `UiFieldStyle.disabledFillColor`
- [ ] hover 态走 `UiFieldStyle.hoverFillColor`
- [ ] focus 态只用 `focusedBorder` 变色，不加光晕/阴影
- [ ] 字数统计正常渲染（Column 尾行）

### Theming

`package:zhiban_ui/themes/app_theme.dart` — Material 3 + Cupertino blend. Brand color: `#2563EB`. Both `ThemeData` and `CupertinoThemeData` are derived from the same `ColorScheme` so Cupertino widgets stay visually consistent. `AppTheme.cupertinoThemeBuilder` is applied in the `MaterialApp.router` builder above `ProviderScope`.

### Platform Utils

`PlatformUtils` (`package:zhiban_ui/utils/platform_utils.dart`) — static helpers: `isDesktop`, `isMacOS`, `isWindows`, `isMobile`. Gate desktop-only code (window management, title bar, etc.) behind `PlatformUtils.isDesktop`.

## Key Conventions

- All pages are `ConsumerStatefulWidget` / `ConsumerWidget` (Riverpod).
- Icons: prefer `CupertinoIcons` first, `Icons` (Material) second, `LucideIcons` as fallback.
- Toast notifications use `BotToast.showText(...)`.
- Page-level files follow `lib/pages/<feature>/<feature>_page.dart`; providers under `lib/pages/<feature>/providers/`; services under `lib/pages/<feature>/services/` or `lib/services/`.
- `unawaited(...)` is used intentionally for fire-and-forget async calls (mark-read, refresh timers) — do not convert to `await` without understanding the side-effect timing.

### Package resources

Shared business assets use `ClientAssets` and the zhiban_client package namespace. HarmonyOS font belongs to zhiban-ui; use `packages/zhiban_ui/HarmonyOS Sans SC`. Shared packages must not import either App. Desktop has no fluwx/Gal/image_picker/mobile_scanner dependency.
