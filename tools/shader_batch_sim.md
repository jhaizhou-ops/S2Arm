# 着色器合批模拟

用每支着色器的编译耗时 CSV（`shader,seconds`）估算合批后的墙钟：

```sh
python3 tools/shader_batch_sim.py tests/fixtures/shader_batch_sim/times.csv --workers 8 --overhead 1 --max-batches 8
bash tests/shader_batch_sim_test.sh
```

程序对 1 到 `--max-batches`（不超过着色器数）的每个批次数，分别尝试按输入顺序均分数量和按耗时降序放进当前最轻批次。然后按批次耗时降序派给最先空闲的工作线程。输出全部候选的批次着色器名单、耗时、派工及墙钟，并选出候选中墙钟最短的一项；同耗时优先较少批次。缺省 8 路，`--overhead` 是每批固定开销（秒），应根据实际环境测量。

规则是在候选中比较拖尾与额外批次开销；结果不是全局最优证明。模型假定单支耗时可相加且批开销固定，没有模拟合批共享编译、内存争用、启动波动或编译器行为；实测数据与真实出包仍需验证。输入为本地耗时表，不读取游戏或着色器内容。
