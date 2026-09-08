# Wine-iOS batch correction — build 13

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
