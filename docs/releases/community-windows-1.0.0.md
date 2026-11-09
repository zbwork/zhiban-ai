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

最终安装后的普通权限和启动结果见下方验收记录。

源码预检补齐遗漏的Windows Codex兼容构建脚本及其缓存校验测试；未降低隔离门禁。

跨平台运行夹具在Windows使用PowerShell命令，并按客户端白名单传入SystemRoot/用户目录等系统变量；不继承模型凭据或开发工具PATH，不跳过工具/续答断言。

## 实机发现与修复约束

首轮22项测试11通过、11失败。技能读取将OS计算的Windows相对路径直接送入POSIX接口参数校验，references/data.txt误报local.invalid_path。仅规范化OS计算结果的分隔符，外部参数继续拒绝反斜杠、绝对路径和..，并保留realpath边界检查。

完全访问命令在原生参数解析时拒绝不存在的deny目录。对照探针：同一network=true命令，存在deny目录时成功，不存在时失败；实际用户Documents/WindowsPowerShell和Documents/PowerShell不存在。采用在已授权可写根下创建缺失保护目录、持有不允许删除/替换的目录句柄、再应用原有唯一SID拒绝ACL；子进程终止和ACL撤销后，仅尝试删除本次创建且仍为空的目录。不能忽略不存在的deny规则，也不放宽ACL或提升客户端权限。

行业依据：[Microsoft SetNamedSecurityInfoW](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setnamedsecurityinfow)操作现有命名对象；[CreateDirectoryW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createdirectoryw)创建目录并继承父ACL。测试使用独立用户目录夹具，避免为验收改动构建账号真实主目录的ACL。

## 产物与已完成验证

- 产品源码：`607f23a`；独立目录D:\zbc100，未重置原构建工作区，未推送Git。初始归档SHA256为`ee5a77d04377b01430056c39bbfc64db86c09ba320da9a1e5ab26d06bd39d659`，修复增量归档为`d6168f1c8594f97c642cccd0712c5b18f15e055830585357b0160134ccf232c1`。
- 构建环境：Windows 11 x64，Flutter3.35.6/Dart3.9.2、Go1.26.3、Python3.12.10、Rust1.93.0。Go代理连接超时后，仅构建进程使用goproxy.cn并保留go.sum校验；未关闭TLS或更改全局网络。
- `ZhiBanAI_Community_1.0.0_windows_x64.exe`：454248482字节，SHA256 `93ef68bdee96ec6cd0a87d977e1155879aed1b7d2d05e2b7a7eebe2cd3bcab5a`。未做Authenticode发布者签名；不能将包内Node/Microsoft WebView2的有效签名归到社区主程序或安装器。
- 正式包主程序1.0.0+10001，CompanyName为cn.qkfintech.zhiban.community。主程序、Bridge、Node、Codex、sandbox和path addon的PE machine均为0x8664。
- 包内Node/engine/office/browser/isolation/codex自检全部true。脚本模型驱动真实DSH/Codex的25项测试全部通过、无跳过；包含工具失败后恢复、缺失Responses终态ID、审批/拒绝/取消、附件原字节、技能参考文件及目录链接越界拒绝、缺失deny目录的写入/替换阻断和清理。
- Windows网络校验99个实际图片URL全部成功，PNG签名与原摘要相符。代码日报和合同起草没有图标URL，属于无自定义图标数据；未冒充GUI回退渲染验收。首次网络夹具误将空URL请求成网站根地址，原始报告保留，最终报告明确排除这两个非图片请求。
- Windows打包Python测试9项中8通过、1因Windows无独立CMake PATH而跳过；实际Flutter CMake/MSVC Release已成功。Codex缓存Python测试5项全部通过。Mac侧同一打包测试及CMake配置夹具通过（Windows专属项按平台跳过）。
- 原完整版1.4.0安装器为394706326字节。现存内部Release文件树为1147980718字节，本包为1144152497字节，少3828221字节；旧安装器与现存Release文件树未证明逐字节一致，不能据此解释安装器压缩体积差。没有把另一个CPU架构重复装入新包。
- 短路径实际安装已通过，正在补充默认Program Files中文目录、普通权限运行和原生窗口启动结果。

未完成：Windows10实机、Windows ARM64原生包、真实付费模型调用及各GUI页面逐项人工点选/视觉验收。远端Windows的网络图片校验和进程窗口状态不能替代图片的实际渲染验收。

## 安装器体积复查（用户反馈454 MB偏大）

已用维护者发布的Inno Unpacker 2.71.3直接读取原1.4.0安装器和新1.0.0安装器，均为Inno6.4.3/lzma2。实际新包相对原包增加的主体为native/codex/codex.exe（291870720字节）；npm内@openai/codex-win32-x64/vendor旧二进制239207216字节仍在。Windows bundledCodex明确返回native/codex，npm根包package.json仅用于版本核验；保留版本/许可元数据，仅删未执行的npm vendor副本。两版都有相同212745424字节WebView2离线依赖，不能把它说成此次新增。

采用：仅Windows目标安装树裁剪重复Codex vendor、node-pty非x64预编译与PDB调试符号，锁文件、构建缓存、实际兼容版、x64 addon/DLL/EXE和许可不变；裁剪发生在原有组件自检之前，并记录清单。源码、隔离门禁、工具和文件预览能力保留。依据：Windows生产路径在src/desktop/codex-engine.ts显式固定native/codex；PDB为调试信息（[Microsoft /PDB](https://learn.microsoft.com/en-us/cpp/build/reference/pdb-use-program-database?view=msvc-170)），不参与PE运行时加载。

用户已明确选择保留完整离线安装；WebView2离线安装器保持不变，仅清理确认未使用的冗余。
