# Wine-iOS build 14：地址诊断与进程内通信

基于已推送的 c1d5709（build 13），固定 Wine 基线不变。

## 真机结论

新日志 wine-ios(20260908-042833).log 确认 VM_MAP_FIXED_IOS 被执行，
请求地址 0x7ffe0000、大小 0x4000，Mach 返回 1（KERN_INVALID_ADDRESS）。
ENOMEM/STATUS_NO_MEMORY 是适配层转换的结果，不能当成手机 RAM 不足的证据。
build 14 增加符号名称和专门错误提示，保留真实失败。

Apple XNU 的 ARM64 可执行文件加载逻辑要求低 4 GiB 的 hard page-zero。
这与当前现象一致，但我们没有读取这台手机内核实际的地址空间下界。
vm_region_64 没找到占用页、Mach-O 没找到 PAGEZERO，都不能证明地址可分配。
本包不启用旧 root build-host.sh 中缩小 PAGEZERO 的实验参数。

参考：
* https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/kern_return.h
* https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/mach_loader.c

## 本次提前完成

1. 从复制请求到读取回复期间独占请求槽，修复等待时其他调用者覆盖请求/回复。
2. 启动、停止、重新绑定 handler 串行化；回收退出但未 join 的线程，停止后
   移除 handler，避免进入已卸载 dylib。
3. 超时或等待错误后停用旧请求槽，stop/join 后才能重启；处理完成与超时重合。
4. 区分非法参数、未实现请求、连接关闭和超时，清理错误回复区；错误文本采用
   线程局部快照。
5. 自动回归测试接入现有脚本，沿用补丁 0009，不增加补丁编号。

handler 必须及时返回，handler 与日志回调不能重入 server API；本包没有强制
终止卡死 handler 的机制。通信线程安全不代表整个 Wine runtime 支持重入。

## 验证及安装

同一套 8 客户端、8000 请求测试：原代码错配 6385 次，修复后 0 次。
这使用真实 pthread 和固定 Wine 头文件，handler 返回测试标记，验证传输正确性，
不声称验证真实 Windows 对象管理。非法帧、并发启动/停止、重启、注入超时和
等待失败测试通过。7 个模拟 VM 用例、runtime 重试回归和 C 编译检查也通过。

ZIP 按原相对路径覆盖并保留其他文件，一次提交推送；测试文件与脚本一起提交。
版本为 0.0.1 (14)，标记 WINE_RUNTIME_REVISION=IOS_TRANSPORT_2。
未替用户推送或运行远程构建，本地没有 iOS SDK/真机执行环境。
build 13 的地址限制不会因本包自动消失，同样的地址错误不代表通信回归。

## 仍需完成

先解决 Windows 来宾地址与 iOS 主机地址的差异；随意把共享页挪到高地址只改
一个指针，不能兼容直接访问 0x7ffe0000 的 Windows 代码。然后推进完整 TEB、
线程初始化、真实 server 对象管理、prefix、PE 装载及 hello.exe 输出/退出码。
这些目前尚未实现，不能取消探针返回来假装完成。本轮不改 AlloyCore 图形路线。

---

## 历史记录：build 13（以下版本和设备验证说明属于上一轮）

Base: WineIOS-Core `99cd469`; Wine `db11d0fe6a169c457e23d007e20404643d067aa8`.
Evidence: device log `wine-ios(20260908-041105).log`, build 12, iOS 18.5, 16 KiB pages.

## Install

Extract the delivered ZIP and replace files at the **same relative paths** in
WineIOS-Core. It is a partial update, not a replacement repository. Do not delete
other files. Commit and push once; the existing workflow builds the IPA.
The Wine patch replaces existing patch 0009; no new patch-series entry is needed.
CI activates the root run-wine-ios-probe.sh automatically. Tests must accompany it.
No remote commit, push or Actions run was performed by this editing session.

## Confirmed fixes

* The iOS branch used mmap with an address hint, not a fixed allocation. When
  Darwin returned a different address, Wine converted this to EEXIST. The probe
  incorrectly labeled that path MACH_VM_MAP, with mach_ret=-1 never populated.
* Use the ARM64 native-width vm_map API with VM_FLAGS_FIXED **without OVERWRITE**
  to reserve the requested range. Use Wine's existing fixed mmap only after our
  own reservation succeeds. Refuse occupied ranges; never unmap someone else's
  mapping. Preserve mmap errno during cleanup and record the actual Mach result.
* Failed initialization must not become success merely because three libraries
  remain loaded. Reject retry after a partial initialization; restart the host.
  A completed probe remains idempotent, but is explicitly not PE execution readiness.
* Build number 13 and WINE_RUNTIME_REVISION=IOS_FIXED_MAP_1 identify this code.

Native VM API reference:
https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_user.c

## Verification performed

* Existing nine-patch series applied to the pinned Wine source; replacement 0009
  reverse/apply checks pass after patches 1–8.
* Actual patched mapping function compiled with mocked Darwin APIs: six cases
  covering success, address collision, protection denial, resource failure,
  remapping failure with errno preservation, and disabled instrumentation.
* Actual runtime_initialize function compiled with mocked loader/server calls:
  partial failure, retained handles, repeated call, load failure, success cache,
  invalid config and post-shutdown retry gates pass.
* No macOS/Xcode compiler or iPhone execution is available in this environment.
  These tests do not prove that iOS allows 0x7ffe0000 or that hello.exe runs.

## Next device gate

Launch the newly built IPA in a fresh host process. Expected new evidence:

```
VERSION=0.0.1 (13)
WINE_RUNTIME_REVISION=IOS_FIXED_MAP_1
WINE_FIRST_TEB_FIXED_MAP=primitive=VM_MAP_FIXED_IOS ... mach_ret=...
WINE_FIRST_TEB_SHARED_DATA_STATUS=...
```

If the native VM call denies the address, retain its exact result and stop.
Do not bypass system restrictions, overwrite occupied memory, or substitute
an arbitrary address for Windows' fixed shared-data page.

## Work still required — not optimization yet

1. Verify the fixed shared-data mapping on device.
2. Finish TEB block reservation/commit and signal/thread initialization.
3. Implement real in-process server process/thread/object lifecycle and required
   requests. Today only the invalid close_handle handler path is connected; a
   protocol round trip is not a functioning wineserver.
4. Implement prefix setup, PE loader initialization and ARM64 execution. The
   current run_arm64_pe deliberately returns -100 (not implemented).
5. Run hello.exe with captured output and exit status; then test file I/O,
   threads, handles and cleanup before compatibility/performance work.

This update intentionally retains the stop after the shared-user-data probe.
It does not report all Wine work complete or enable unimplemented startup paths.
