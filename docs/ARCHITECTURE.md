# 固定架构边界

## 长期数据流

```text
Windows x64 EXE/DLL
        ↓
离线 AOT 为主 / JIT 兜底
        ↓
定制 ARM64 Wine / WinCompat
        ↓
可替换 Graphics Backend C ABI
        ↓
DX11 → Metal 核心
        ↓
Apple GPU
```

当前 `0.0.1` 只实现最左侧运行环境出现之前的 iOS 宿主、日志与能力探针。

## 仓库边界

- Wine 原始代码和直接 Wine 修改保持 LGPL 合规并可公开。
- iOS 通用构建脚本、基础平台补丁和公开 C ABI 可进入公开仓库。
- x64 AOT/JIT、DX 快速入口、自研 Metal 核心、零复制系统、帧模板、跨层调度器和性能数据库不得放入此公开源码树。
- 闭源实现只能通过版本化 C ABI 接入。
- DXMT 如用于验证，必须保持为独立可替换后端，不复制进自研图形核心。

## 不变原则

- 不为单一游戏增加硬编码分支。
- 不绕过 DRM、许可证、VAC 或反作弊。
- 在 ARM64 Windows `hello.exe` 完成 PE 加载闭环以前，不开始 x64 JIT。
- 在 Wine 核心初始化以前，不开始完整图形后端。

## iOS 特有阻塞点

上游 Wine 11.0 没有官方 iOS 目标。它的 Darwin 支持主要面向 macOS，并假定可用的桌面进程、窗口及系统服务。首轮移植必须用探针确定，而不是假定：

- 可执行内存与 JIT 写保护状态；
- `mmap` / `mprotect` 语义；
- Wine server 是否能作为签名 helper 启动，或必须改为进程内服务；
- Mach 异常、Unix signal 与 Windows SEH 的可用映射；
- iOS 沙盒中的前缀、注册表和文件路径；
- 动态库装载、重定位、TLS 和回调行为。

其中 server 进程模型属于 Wine 核心启动链，不是后期启动器功能。

