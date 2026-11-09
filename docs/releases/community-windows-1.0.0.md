# 社区版 Windows 1.0.0 构建与验收

版本1.0.0+10001，Windows x64，沿用当前社区源码和线上匿名员工/技能目录。构建机使用独立短路径目录，不重置原工作区，不调用会上传商业安装包的Runner；源码以git archive传输，不向远端写Git对象或引用。

## 行业最佳实践与适配性

- 来源：[Flutter Windows分发](https://docs.flutter.dev/platform-integration/windows/building)、[Inno AppId](https://jrsoftware.org/ishelp/topic_setup_appid.htm)。
- 行业做法：完整分发exe、DLL、数据和VC++运行库；同一产品升级使用稳定AppId，不同产品使用不同AppId。
- 当前上下文：社区客户端已有Windows CMake、AppContainer、Codex兼容构建、WebView2离线依赖和Inno安装器，但安装标识/产品名仍是商业版。
- 采用：adopt既有完整安装包和严格自检；adapt社区产品名、版本资源和独立安装标识。固定社区AppId为`{B9176F5C-0428-51DC-8398-2B43190465AE}`，默认安装到“知办AI社区版”，CompanyName为cn.qkfintech.zhiban.community。
- 不采用：不复用商业AppId/数据目录、不禁用隔离/Codex检查、不要求终端用户安装开发工具、不把x64包标为Windows ARM64原生包。

## 验收矩阵

- 独立源码目录与原工作区隔离，源文件摘要可追溯。
- Flutter Release、原生组件构建、Node/engine/office/isolation/codex自检通过。
- exe版本1.0.0、x64 PE、社区产品名及独立安装器AppId；VC++、WebView2和预览资源齐全。
- 包内工具执行及历史工具续答定向验证；构建通过不能代替安装或GUI验收，未完成项逐项记录。
- 记录安装器体积、SHA-256及签名类型。若沿用Ed25519更新签名，不将其称为Authenticode发布者签名。

构建/安装/运行和最终产物结果完成后补录。

源码预检补齐遗漏的Windows Codex兼容构建脚本及其缓存校验测试；未降低隔离门禁。

跨平台运行夹具在Windows使用PowerShell命令，并按客户端白名单传入SystemRoot/用户目录等系统变量；不继承模型凭据或开发工具PATH，不跳过工具/续答断言。

## 实机发现与修复约束

首轮22项测试11通过、11失败。技能读取将OS计算的Windows相对路径直接送入POSIX接口参数校验，references/data.txt误报local.invalid_path。仅规范化OS计算结果的分隔符，外部参数继续拒绝反斜杠、绝对路径和..，并保留realpath边界检查。

完全访问命令在原生参数解析时拒绝不存在的deny目录。对照探针：同一network=true命令，存在deny目录时成功，不存在时失败；实际用户Documents/WindowsPowerShell和Documents/PowerShell不存在。采用在已授权可写根下创建缺失保护目录、持有不允许删除/替换的目录句柄、再应用原有唯一SID拒绝ACL；子进程终止和ACL撤销后，仅尝试删除本次创建且仍为空的目录。不能忽略不存在的deny规则，也不放宽ACL或提升客户端权限。

行业依据：[Microsoft SetNamedSecurityInfoW](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setnamedsecurityinfow)操作现有命名对象；[CreateDirectoryW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createdirectoryw)创建目录并继承父ACL。测试使用独立用户目录夹具，避免为验收改动构建账号真实主目录的ACL。
