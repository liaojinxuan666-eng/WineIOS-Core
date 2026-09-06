# WineIOS-Core

`WineIOS-Core` 是一个面向 iOS ARM64 的 Wine 核心 bring-up 与验证仓库。

当前目标是把 **Wine 11.0 → iOS ARM64 → Windows ARM64 PE** 的最小运行链路做成可重复、可验证的基础，并逐步推进真实 Wine 初始化。

当前版本仍为 `0.0.1`。只有跨过明确的核心里程碑后才会升级版本号。

## 当前状态

截至目前，CI 构建与 iPhone 真机探针已经验证：

```text
Wine 11.0 frozen baseline             PASS
macOS host Wine tools                 PASS
iOS ARM64 configure                   PASS
iOS ARM64 ntdll Unix runtime          PASS
iOS ARM64 Wine loader                 PASS
iOS ARM64 wineserver build            PASS
Windows ARM64 ntdll.dll               PASS
Windows ARM64 kernelbase.dll          PASS
Windows ARM64 kernel32.dll            PASS
Windows ARM64 hello.exe build         PASS
runtime bundle/package                PASS
native iOS host execution             PASS
ntdll dlopen                           PASS
__wine_main symbol                    PASS
runtime C ABI                         PASS
in-process server startup             PASS
Wine server protocol ABI              PASS
Wine server handler attach            PASS
Wine server handler dispatch          PASS
ntdll -> __wine_server_call path      PASS
server reply -> ntdll path            PASS
host runtime initialize               PASS
real __wine_main entry                PASS
Wine init_paths                       PASS
Wine virtual_init                     PASS
```

最近一次真机验证已经形成两条已确认链路。

第一条是 server protocol 闭环：

```text
iOS Host
   ↓
Wine Runtime ABI
   ↓
Wine ntdll Unix runtime
   ↓
__wine_server_call
   ↓
in-process Wine server bridge
   ↓
Wine server handler dispatch
   ↓
protocol reply
   ↓
ntdll
```

测试请求得到 `STATUS_INVALID_HANDLE (0xC0000008)` 是预期的协议级返回值，用于证明真实 Wine server handler 已被调用并且 reply 能返回 ntdll；它不是运行失败。

第二条是 Wine 主初始化入口：

```text
iOS Host
   ↓
Wine Runtime ABI
   ↓
ntdll.so
   ↓
__wine_main()
   ↓
init_paths()
   ↓
virtual_init()
   ↓
probe stop
```

当前探针已经验证 `virtual_init()` 完整返回，并在其后主动停止，因此不会误把尚未执行的后续阶段标记为完成。

## 尚未完成

当前 **不声称**已经可以运行 Windows 应用。

```text
init_environment                    NOT RUN
Apple main-thread transition        NOT RUN
start_main_thread                   NOT RUN
server_init_process                 NOT RUN
full Wine initialization            NOT RUN
Wine prefix initialization          NOT RUN
Windows PE loader startup           NOT RUN
Windows ARM64 hello.exe execution   NOT RUN
```

当前重点是继续推进 ARM64 Wine 核心初始化，不提前混入无关功能。

## 已冻结的 Wine 基线

- Release: `Wine 11.0`
- Tag: `wine-11.0`
- Commit: `db11d0fe6a169c457e23d007e20404643d067aa8`
- Mirror: `https://github.com/wine-mirror/wine.git`
- Canonical upstream: `https://gitlab.winehq.org/wine/wine.git`

准确值保存在 `config/wine-upstream.lock`。构建脚本会校验提交，不跟随上游 `master`。

## 工程结构

```text
WineIOS-Core/
├── .github/workflows/       GitHub Actions 构建与探针
├── config/                  Wine 基线与版本配置
├── docs/                    架构、里程碑与日志规范
├── host/WineIOSHost/        iOS ARM64 宿主与真机探针
├── patches/wine/            顺序化 Wine iOS 补丁
│   ├── 0001-...             iOS platform/configure bring-up
│   ├── 0002-...             ntdll in-process server-call bridge
│   ├── 0003-...             Wine main initialization probe
│   └── series               补丁应用顺序
├── runtime/
│   ├── include/             Host ↔ runtime C ABI
│   └── src/                 runtime 与 in-process server 适配层
├── reports/                 构建/探针事实记录
├── scripts/                 构建、打包与设备探针脚本
└── tests/                   静态与 CI 验收
```

## 构建与验证

代码推入 GitHub 后，`Wine iOS core configure probe` 会：

1. 拉取并验证固定版本 Wine 11.0；
2. 构建同版本 macOS Wine tools；
3. 应用当前 iOS 补丁序列；
4. 使用 iPhoneOS SDK 配置 iOS ARM64 Unix runtime；
5. 构建必要的 Windows ARM64 PE 核心；
6. 构建 iOS Wine loader / ntdll / wineserver；
7. 打包真机 runtime artifact；
8. 构建 Wine iOS Core Host。

CI 成功只证明构建链成立。真正的运行状态必须以 iPhone 真机日志为准。

## 当前运行策略

标准 Wine 使用独立 wineserver 进程及 Unix FD transport。当前 iOS bring-up 使用同一宿主进程内的 Wine server 路径，以适配 iOS 进程模型。

当前实现保留 Wine server protocol ABI 与真实 handler，仅替换不适合当前 iOS 宿主模型的进程/transport 边界。现有真机探针已经验证 handler dispatch 和 ntdll server call 往返闭环。

## 下一道门

下一阶段只推进一件事：**从已经通过的 `virtual_init()` 继续进入 `init_environment()`，仍然不启动 `hello.exe`。**

目标探针：

```text
WINE_MAIN_ENTER=PASS
WINE_MAIN_PATH_INIT=PASS
WINE_VIRTUAL_INIT=PASS
WINE_ENV_INIT=PASS / FAIL_AT=<exact stage>
WINE_MAIN_THREAD_INIT=NOT_RUN
WINDOWS_ARM64_HELLO=NOT_RUN
```

如果失败，必须把失败点定位到具体初始化阶段，而不是一次加入大量补丁。

只有 `init_environment()` 稳定后，才继续推进后续主线程初始化。

## 开发原则

- 小步修改，每一步都必须有 PASS / FAIL 证据；
- 优先保证 Wine ARM64 核心初始化链；
- 不以单个应用的特殊 hack 代替通用兼容实现；
- 尽量保留 Wine 原始协议、状态机和 handler，只替换 iOS 平台确实不适用的边界；
- CI 负责可重复构建，真机负责运行事实；
- 不把“可以编译”描述成“已经可以运行 Windows 程序”。
