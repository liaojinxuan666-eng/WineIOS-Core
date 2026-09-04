# Wine-iOS Core 0.0.1

这是 iOS 上 Windows 兼容运行环境的最小可信起点。本仓库当前只负责：

- 冻结 Wine 11.0 上游基线；
- 构建一个可安装的 iOS ARM64 宿主 App；
- 在真机上记录线程、TLS、文件和虚拟内存能力；
- 以用户主动操作的方式测试 JIT 可执行内存；
- 定义 Wine 与后续闭源运行时之间稳定的 C ABI。
- 建立同版本 macOS Wine tools → iOS ARM64 configure 的两阶段探针。

`0.0.1` **不声称**已经初始化 Wine，不包含 x64 JIT/AOT、DX11、Metal 图形后端、Steam/Epic、DRM、VAC 或启动器。

## 已冻结的 Wine 基线

- Release: `Wine 11.0`
- Tag: `wine-11.0`
- Commit: `db11d0fe6a169c457e23d007e20404643d067aa8`
- Mirror: `https://github.com/wine-mirror/wine.git`
- Canonical upstream: `https://gitlab.winehq.org/wine/wine.git`

准确值保存在 `config/wine-upstream.lock`。脚本会校验提交，不跟随 `master`。

## 工程结构

```text
WineIOS-0.0.1/
├── .github/workflows/       GitHub Actions 构建
├── config/                  Wine 基线与版本配置
├── docs/                    架构、里程碑与日志规范
├── host/WineIOSHost/        极简 iOS ARM64 宿主
│   ├── Resources/           Info.plist 与权限
│   └── Sources/             UIKit、日志和能力探针
├── runtime/
│   ├── include/             稳定 C ABI（公开边界）
│   └── src/                 当前仅 ABI 占位实现
├── patches/wine/            可审计、顺序化的 Wine LGPL 补丁
├── reports/                 每轮构建探针的事实记录
├── scripts/                 拉取、构建、打包与验证脚本
└── tests/                   本地/CI 静态验收
```

完整验收标准见 `docs/MILESTONE-0.0.1.md`。

## 构建方式

代码推入 GitHub 后，Actions 中的 `Build iOS Host 0.0.1` 会生成 `WineIOSHost-0.0.1.ipa`。构建使用 macOS 自带的 iPhoneOS SDK 和 clang，不要求用户在手机终端输入长命令。

本地 macOS 也可以运行：

```sh
bash scripts/build-host.sh
bash scripts/package-ipa.sh
```

## 下一道门

`0.0.1` 真机验收完成后，下一步才开始修改 Wine：

1. 在同一提交上先构建宿主 Wine tools；
2. 建立 `arm64-apple-ios` 目标配置；
3. 记录首轮 configure/compile 阻塞点；
4. 以小补丁逐项处理 Darwin/iOS 差异；
5. 解决 Wine server 在 iOS 进程模型下的启动方式；
6. 只构建 PE 加载闭包、`ntdll`、`kernelbase`、`kernel32` 和必要依赖；
7. 让宿主调用 `wios_runtime_get_api()` 并完成 Wine 核心初始化。
