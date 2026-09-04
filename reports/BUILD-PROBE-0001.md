# Wine-iOS Build Probe 0001

## 源码事实

- Wine 基线：`wine-11.0` / `db11d0fe6a169c457e23d007e20404643d067aa8`。
- `tools/config.sub` 已能把 `arm64-apple-ios` 规范化为 `aarch64-apple-ios`。
- 上游 `configure.ac` 没有 `ios*` 的 `host_os` 平台分支。
- 未修改时，iOS 目标会落入默认 Unix 分支，产生 Linux/ELF 风格链接选项，而不是 Mach-O dylib 设置。
- macOS 的 `darwin*` 分支不能直接复用：它默认启用 `winemac`，并声明 AppKit、IOKit、ApplicationServices、CoreServices 等桌面依赖。
- Wine 交叉编译明确要求 `--with-wine-tools=DIR`，所以必须先构建同一提交的 macOS 宿主工具。

## 第一块补丁

`0001-configure-add-ios-platform-target.patch` 新增独立 `ios*` 分支：

- 使用 Mach-O `.dylib`；
- 禁用 `winemac`；
- 不引入 AppKit、IOKit、ApplicationServices 或 CoreServices；
- 只声明第一阶段可接受的公开 iOS framework；
- 禁用 macOS preloader 假设；
- 保留 `@rpath` 动态库安装名；
- 定义 `WINE_IOS=1`，供后续通用条件编译使用。

## 尚未宣称完成

- 尚未在真实 iPhoneOS SDK 上运行 configure；
- 尚未编译 `ntdll`；
- 尚未决定 Wine server 使用签名 helper 还是进程内模式；
- 尚未处理 Windows SEH 与 iOS/Mach 异常映射；
- 尚未接入任何 x64 翻译、Direct3D 或 Metal 后端。

第一次 macOS CI 的职责仅是验证 `CONFIGURE=PASS`，并保存完整 `wine-ios-configure.log`。下一轮才根据真实编译器输出进入 `ntdll`。

