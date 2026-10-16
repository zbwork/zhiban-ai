# zhiban_core

知办共享数据模型、IM 接口、EMP 解析、错误转换及请求鉴权/会话协议。纯 Dart 包，不包含 Flutter 页面、平台存储、路由、移动推送或商业配置。

请求鉴权与单飞 token 续期通过回调读取当前 API URL、凭据及持久化 token 对；App 提供这些依赖与登出副作用。普通与敏感业务 Dio 复用同一个续期器。`LocalTokenClaims` 仅解码未验证的本地 JWT 声明，用于缓存分区及续期时机，不能用于授权。core 不预设公司域名或凭据。

App 通过相对 `path` 依赖使用此包，可导入 `package:zhiban_core/zhiban_core.dart` 或具体模块。调用方直接 import 本包，原 App 中已迁出的文件删除，类型与状态只有一份实现。

在本目录验证（Dart 3.9.2 或兼容版本）：

```sh
dart pub get
dart analyze
dart test
```

不要反向依赖 `apps/` 或通过相对路径引用包外源码。该包随 monorepo 交付，不单独发布到 pub.dev。
