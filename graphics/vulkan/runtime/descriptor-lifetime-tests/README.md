# 普通 descriptor set 缓存与 buffer 生命周期回归

编译完整真实 Vulkan C# 源码及项目中的 linked source，以受控 Silk API dispatch
记录 descriptor 写入、action、buffer/view 销毁和 fence 完成。不创建真实 VkDevice、
不访问内核或游戏内存；不能代替 Vulkan validation、真实 GPU 或游戏验收。

```sh
python3 graphics/vulkan/runtime/descriptor-lifetime-tests/run.py \
  --dotnet /absolute/path/to/dotnet \
  --deps /absolute/path/to/current-managed-runtime-dlls \
  --out /absolute/path/outside-source/new-output
```

依赖 DLL 必须来自匹配源码的现有运行时构建，清单沿用相邻 `rebind-tests`，不联网恢复。
输出目录必须不存在，且位于源码和依赖之外；完整输入 SHA、二进制 SHA、命令及原始结果保留。
在原始源码 checkout 上加 `--source-root` 和 `--baseline` 可保留原物理 set 身份断言，
原语义失败仍返回非零，不把负控标成通过。

13 个场景覆盖 recording/pending owner 删除、两轮 16 个 CB index、实际 mirror、
同 coverage 复用、无 action 控制、UBO/SSBO usage 子集切换、不可变 coverage 身份，
以及非数组 storage image 空 view 回退到 dummy（null-image，断言无 0 描述符、计数与无违规）。
固定基线 98360aa1 的相同 Fixture/Dispatch 为 7 绿、5 红；两文件隔离原型为 12 绿、125 项检查。
这里提交的两份 C# 夹具与该冻结原型逐字节相同。公共 runner 尚未独立执行，不能把原型结果
写成当前整树或公共入口通过。API 是受控边界，active-set 关系源于 authored metadata，
不是实际 pipeline 反射或驱动执行。

不同 coverage 会多建整组 PLCE（含 pipeline/set layout，以及懒分配的 pool/set）；
这是程序创建期的空间及建表成本，不能称为免费。常驻 set cache 不额外长期持有旧 buffer。
记录中的 `UpdateDescriptor` 是 binding 写事件，`CmdDispatch_active_set` 是每 set 事件，
不得直接相加充当 Vulkan API 次数或性能收益。

边界：texel 类型及数组在本组只验缓存身份；同 coverage 非空转 null、被 non-template 更新
跳过的旧 view 是另一未关闭缺口。null-image 只证明 CPU 侧描述符写入回退到 dummy，不证明
真实驱动执行；与 9000 的 DeviceLost 无关（9000 上本回退命中 0 次），本项不宣称修 9000。
已有补充 push 记录仅支持 CPU
路径与保守重推，缺完整运行来源收据且没有 draw/action，不列为本入口已通过的场景。
