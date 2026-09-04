# 0.0.1 最小验收标准

## 必须全部通过

| 编号 | 验收项 | 通过证据 |
|---|---|---|
| H01 | GitHub Actions 在 macOS runner 上构建 ARM64 iPhoneOS App | workflow 绿色，产出 `.ipa` |
| H02 | IPA 可通过 TrollStore 安装到 iPhone XS / iOS 18 | 主屏幕出现 App，启动不闪退 |
| H03 | App 明确显示 `0.0.1 (1)`、`arm64`、系统版本和页大小 | 截图与导出日志 |
| H04 | 日志写入 App 沙盒并可从系统分享面板导出 | 导出的 `wine-ios.log` |
| P01 | pthread 创建/回收成功 | `THREAD=PASS` |
| P02 | 主线程与子线程 TLS 隔离成功 | `TLS=PASS` |
| P03 | 沙盒文件写入、读取、删除成功 | `FILE_IO=PASS` |
| P04 | 匿名页映射、读写、保护切换及释放成功 | `VM_BASIC=PASS` |
| P05 | `MAP_JIT` 申请结果被记录，不因失败闪退 | `MAP_JIT=AVAILABLE` 或明确失败码 |
| P06 | JIT 执行探针只在用户主动确认后运行 | 日志先写 `JIT_EXEC=STARTED` |
| B01 | Wine 版本固定到精确提交，不使用浮动分支 | `verify-tree.sh` 通过 |
| B02 | 公开运行时 ABI 能被 C 与 C++ 编译器读取 | ABI smoke test 通过 |
| S01 | 工程不含 x64 JIT、DX、商店或 DRM 占位伪实现 | 范围检查通过 |

## 明确不属于 0.0.1

- Wine 核心成功初始化；
- 运行 Windows ARM64 PE；
- `ntdll/kernel32` 已完成 iOS 构建；
- Windows 异常/SEH 已通过；
- x64 指令执行；
- DX11 或 Metal 游戏画面。

这些如果没有真实构建日志或真机证据，不得标记为完成。

## 0.0.1 完成定义

只有 H01–H04、P01–P06、B01–B02、S01 全部取得证据，才能把 `0.0.1` 标为完成。任何普通修复只增加构建号，例如 `0.0.1 (2)`，不得升级到 `0.0.2`。

`0.0.2` 的候选门槛是：宿主通过稳定 C ABI 加载实际 Wine-iOS runtime，并完成一次可重复的 Wine 核心初始化与关闭。

