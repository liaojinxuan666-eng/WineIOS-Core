# 日志约定

日志每行使用以下格式，便于手机阅读和后续自动分析：

```text
2026-09-04T12:00:00.000Z [INFO] KEY=value
```

规则：

- 时间统一为 UTC ISO-8601。
- 能力结果使用稳定键名，如 `TLS=PASS`。
- 系统错误同时记录十进制 errno 和文本。
- JIT 探针执行前先落盘 `JIT_EXEC=STARTED`，便于区分执行崩溃与未执行。
- 不写入用户文件名、账号、令牌或其他隐私数据。
- 当前日志位置为 App 沙盒 `Documents/Logs/wine-ios.log`。

