# zhiban-client

共享 Flutter 业务、Provider、会话启动及平台接口；依赖 core/UI，不依赖任何 App。移动原生实现由私有入口注入。

`flutter pub get`、`flutter analyze`、`flutter test` 在本目录运行。资源通过包名 zhiban_client 加载，根包测试由 flutter_test_config 使用本目录资源；字体归 zhiban-ui。
