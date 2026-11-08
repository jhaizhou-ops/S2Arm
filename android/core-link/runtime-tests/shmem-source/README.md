# 共享内存源地址对齐

在 Linux ARM64、真实 4 KiB 内核页环境运行：

```sh
python3 android/core-link/runtime-tests/shmem-source/run.py --out /tmp/shmem-source-test
```

直接编译生产 `thread.c` 的 wrap/lookup/句柄表，以及 `plat_android.c` 的 alias；
未用替身实现这些函数。4 KiB 案例故意把真实共享匿名源放在 16 KiB 边界后 4 KiB，
验证 4 KiB 长度的 wrap 接受、alias 成功、双向写穿，且整页长度不误报额外别名字节；
不按 4 KiB 对齐的源必须拒绝。
16 KiB 案例仅替换平台页大小查询，验证不合法页内偏移被拒绝；不是 16 KiB 内核验收。
输出记录生产源码 SHA、完整命令与各案例日志。`--thread-source` 可指定只读旧源，
验证旧的固定 16 KiB 校验会在真实 4 KiB 正例上失败。

测试使用既有 `S2A_UNIT_TEST` 排除确定性句柄分区依赖；不启动 guest、托管服务或 GPU，
不改变生产宿主页、服务内存分配与游戏目标地址策略。Android/Bionic 实机验收仍独立执行。
