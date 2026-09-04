# Wine-iOS Build Probe 0002

## 本轮修正

- `0001` 补丁现在同时修改 `configure.ac` 与 Wine 11.0 随源码发布的 `configure`。
- 核心探针不再依赖运行时执行 `autoreconf`，避免生成器版本改变上游产物。
- macOS 宿主 Wine tools 使用 `--enable-archs=none`。这些工具只服务交叉构建，不要求宿主先生成 ARM64 PE。
- iOS 配置不再使用错误的 `--without-mingw`；它改用 Homebrew LLVM 的 clang 检测 Windows ARM64 PE 编译能力。
- iOS 配置门现在验证 `host_os`、`HOST_ARCH`、`PE_ARCHS`、Mach-O dylib 链接参数、空 preloader 参数和 `WINE_IOS` 宏。
- 宿主 App workflow 改为仅手动触发，当前自动构建资源只用于 Wine-iOS 核心。

## 已在本地验证

- Wine 源码仍固定在 `db11d0fe6a169c457e23d007e20404643d067aa8`。
- 新补丁可在干净 Wine 11.0 源码上通过 `git apply --check`。
- 补丁后的发布版 `configure --help` 可以解析。
- 所有 shell 脚本通过语法检查。
- C ABI smoke test 通过。

## 仍需 macOS runner 给出的事实

- Homebrew LLVM 是否通过 Wine 的 `aarch64-windows` PE/SEH 检测。
- iPhoneOS SDK 头文件与 Wine Unix runtime 的第一处不兼容。
- `configure` 是否完整生成 Makefile 与 `include/config.h`。

本轮没有宣称 `ntdll` 已编译，也没有开始 x64 JIT、图形后端或启动器。
