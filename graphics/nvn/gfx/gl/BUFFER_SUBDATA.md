# 缓冲区局部更新的命令顺序

关联 #272，分片范围为 `gl_buf.m` 的 `glBufferSubData`。此前入口直接 `memcpy` 到共享 Metal 缓冲区；若前一笔绘制已经编码但尚未提交，CPU 更新会让它读到后一次调用的数据。GL 要求前面的读取完成后才更新该区域。

缓冲绑定进顶点／索引编码器时，记录当前提交序号；提交完成回调推进已完成序号。SubData 发现当前存储还被未完成的命令引用时，分配完整新存储，CPU 复制旧内容和本次修改范围，再替换对象的存储。此前编码的命令继续持有旧存储，GPU 完成后由 ARC 释放。没有未完成引用时直接原地 memcpy。BufferData 换新存储后清除引用序号，删除对象不影响已编码命令保活的存储。

当前前端只有 BufferData／SubData 写缓冲，没有 GPU 写缓冲或 Map 路径，所以 CPU 旧内容可直接复制；默认 uniform 由 setBytes 快照，不消费 UBO 缓冲。以后增加 GPU 写入或映射接口时，需要同步扩展这项约束。更新不切渲染遍，不创建 GPU 拷贝或计算派发；任意字节范围都由 memcpy 处理。

offset / size 先分别检查符号，再以减法检查范围，避免 `offset + size` 有符号溢出。零字节的合法更新不创建 GPU 工作。入口登记为 `GLB`，遵守调 Metal 重操作使用宿主栈的前端约定。

本片不增加 Map / Unmap、不可变缓冲区、其他绑定目标或客体装载器接线。宿主 EGL / GL 测试只能证明接口与 GPU 行为，不能据此宣称游戏启动或移动设备验收通过。

## 回归入口

```sh
bash graphics/nvn/tests/gl/t_gl_min.sh
```

沿用既有 13 项，并增加维护者给出的第④组：先画红三角，SubData 改绿，再平移绘制，最后一次 Finish；手算两点分别应为红 128 和绿 255。测试只经 EGL／GL 入口；公共上屏后端用测试里的替身（本单测只测 GL 前端语义）。规范依据为 [Khronos glBufferSubData](https://registry.khronos.org/OpenGL-Refpages/gl4/html/glBufferSubData.xhtml)。

Apple M5 Pro / 48 GB / macOS 27.0（26A428），`MTL_DEBUG_LAYER=1`：15 项通过，④两点实读 `128 0 0`／`0 255 0`。禁用复制写入、强制原地 memcpy 的负向对照仅④前笔失败，实读 `0 255 0`；恢复后 15 项再次通过。这些是宿主接口证据，未验证游戏、老系统或能耗。
