# CLAUDE.md

遵守根 AGENTS.md。先读根 docs 与 ADR-0055；保持唯一业务实现，不复制 Provider/凭据状态。共享包不得 import 桌面或移动 App；不声明 fluwx、gal、image_picker、mobile_scanner。

共用业务页面沿用 apps/zhiban-app/CLAUDE.md 的既有 Flutter 控件/交互约定；这是开发规范引用，不能形成 Dart App 依赖。
