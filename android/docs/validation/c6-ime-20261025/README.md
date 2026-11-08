# C6 IME 真机原始日志（2026-10-25）

对应文档：[../../c6-ime-device-validation.md](../../c6-ime-device-validation.md)。

- `environment.txt`：设备、Android、Gboard 版本/子类型、APK SHA、采集时 HEAD。
- `confirm.log`：preview `mode=5`，Gboard 简体中文 9 键，拼音 `nihao` → 首候选“你好” → 确定；broker `ok/result=0`，`chars=2 utf8=6`。
- `cancel.log`：同一请求点取消；broker `cancel/result=0`。
- `stop.log`：组字中通过 HostApi `request_stop`；selftest waiter `rc=-4`，无 FATAL/ANR。仅 preview，不是单虚拟核。
- `broker-host-tests.txt`：生产 `host_ui.c` / `host_ui_android.c` 的 host 断言（session、owner、UTF-8、stop）。

日志仅 `logcat -s S2Arm:I`，不含玩家文本、存档、游戏资源。文本固定为测试串“你好”，S2Arm 只记录长度/状态。
