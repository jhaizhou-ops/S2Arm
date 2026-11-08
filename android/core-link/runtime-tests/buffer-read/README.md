# Buffer 正常上传读取回归

直接执行生产 `Buffer.SyncAction → ExcludeModifiedRegions → LoadRegion → BufferHolder.SetData → Memmove`，以及非 granular 的 whole-buffer 上传路径。Vulkan 分配/提交环境由夹具建立，目的地址为真实宿主页；生产 BufferHolder、空 fence 等待和 SetData 不替换，也不在 renderer 记录器提前复制 source。

复用相邻 `readonly-copy` 的 native_fixture、Mach VM adapter、生产 tracker/readonly_copy。Mac ARM64 的实际 16 KiB 页验证正常宿主消费者；它不是 Android、NativeAOT、真实 VkDevice/在途提交或设备退休证明。测试不要求 GPU 或新工具环境。每个用例独立进程，预期 AV 的源/目标负控都会真正崩溃。

旧保护源路径必须在实际 Memmove AV；只恢复源可读必须转绿。单字节仍崩排除该夹具长度越界，单独保护目的地址也产生同栈，证明不能仅据游戏托管栈就推断设备故障地址。修复正控核 CPU bytes、GPU-owned 排除范围、邻居 dirty、原页 None、无回写；另核 whole-buffer、copy/renderer 失败、错误 GPU owner、lease 释放和纯复制不重复发跟踪事件。

```sh
dotnet build android/core-link/runtime-tests/buffer-read/BufferRead.Tests.csproj --artifacts-path "$OUT/build" -p:RestoreConfigFile="$OFFLINE_NUGET_CONFIG"
clang -std=gnu11 -O2 -fPIC -dynamiclib -pthread -Iruntime/include android/core-link/runtime-tests/readonly-copy/native_fixture.c android/core-link/runtime-tests/readonly-copy/mac_vm_adapter.c android/native/runtime/tracking/readonly_copy.c graphics/track/track.c -o "$OUT/libreadonly_fixture.dylib"
python3 android/core-link/runtime-tests/buffer-read/run.py --out "$OUT" --dotnet dotnet
```

第一、二行准备一次；之后第三行是数秒的红绿反馈入口。明确指定现有离线 NuGet 配置和输出目录，不自动安装环境、不联网、不向 checkout 写编译产物。`results.json` 记录每个子进程的命令、退出码和日志。
