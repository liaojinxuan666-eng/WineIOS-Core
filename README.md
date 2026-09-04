# Wine-iOS Core 0.0.1

这是 iOS 上 Windows 兼容运行环境的最小可信起点。本仓库当前优先开发 Wine-iOS 核心：

- 冻结 Wine 11.0 上游基线；
- 保留一个极简 iOS ARM64 宿主与能力探针，但暂不扩展 App 壳；
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

## 当前构建方式

代码推入 GitHub 后，`Wine iOS core configure probe` 负责运行当前核心探针。它先构建同版本的 macOS Wine tools，再用 iPhoneOS SDK 和 LLVM 配置 Windows ARM64 PE + iOS ARM64 Unix runtime。完整日志作为 artifact 保存。

`Build iOS Host 0.0.1` 现在只允许手动触发。宿主源码继续保留，但在 Wine 核心达到可初始化状态之前不继续扩展 UI 或启动器。

本地 macOS 也可以运行：

```sh
bash scripts/build-host.sh
bash scripts/package-ipa.sh
```

## 下一道门

当前核心门按以下顺序推进：

1. 在同一提交上先构建宿主 Wine tools；
2. 建立 `arm64-apple-ios` Unix runtime 配置，同时生成 Windows ARM64 PE；
3. 记录首轮真实 configure/compile 阻塞点；
4. 以小补丁逐项处理 Darwin/iOS 差异；
5. 解决 Wine server 在 iOS 进程模型下的启动方式；
6. 只构建 PE 加载闭包、`ntdll`、`kernelbase`、`kernel32` 和必要依赖；
7. 让宿主调用 `wios_runtime_get_api()` 并完成 Wine 核心初始化。
