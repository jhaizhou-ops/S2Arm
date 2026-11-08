# NVN 按 guest 帧保存附件与 pass 快照

`DM_NVN_TEXDUMP` 是显式启用的同步诊断。帧号取 guest 渲染帧 `g_cur_frame`，从 0 开始；与按呈现次数命名的 `DM_NVN_SHOT` PNG 不是同一计数。保存过程会读回 GPU，不能用诊断局衡量正常性能。

```sh
DM_NVN_TEXDUMP='3600,3601,3630:/absolute/private/output/target-%d.png'
DM_NVN_TEXSNAP='49,50,51,52,53,86,87,88,89'
```

调用方须先创建输出目录。逗号列表是显式帧集合，支持乱序与重复项；排序、去重后，每个选定帧只保存一次。列表中的帧必须是非负整数，非法列表立即失败。原有 `3600:path` 单帧和 `size=1280x720:path` 首次尺寸匹配模式保持原文件名。

多帧模式自动在扩展名前加 `_f<guest帧>`，原 `%d` 含义不变：普通附件仍代入 `serial * 100 + layer * 10 + mip`。例如 ser31、level0、slice0 在两个选定帧分别保存为 `target-3100_f3600.png` 和 `target-3100_f3601.png`。TEXSNAP 的文件形如 `target-0_f3600_s087_31_0.png`，携带 guest 帧、帧内 pass、serial 和 level。

`TEXSNAP` 必须和 `TEXDUMP` 一起启用，pass 索引从每帧第一个真实 render pass 的 0 开始；这与 MAGSCAN 的帧内索引一致，PASSDUMP 则使用全局 pass 号。每个选定 pass 结束后，在生产回放流中复制附件；下一 guest 帧首个 pass 打开前，等待已提交 GPU 工作完成并导出上一选定帧，再接续当前帧的采集。因此最后一个选定帧之后还须继续运行到下一帧有 render pass，退出在目标帧本身可能尚未写出文件。

沿用既有 TEXSNAP 的 2D / 2D array、slice0 快照范围；本改动不扩展其他层或 3D 纹理。

`DM_NVN_SNAPRAW=1` 另存附件和快照的原格式字节，`DM_NVN_TEXRAW=<serial,...>` 另存指定 serial；多帧模式也为这些文件加入 guest 帧后缀。PNG 经过采样转换为 RGBA8，浮点值会截断到 `[0,1]`。诊断复制品在 GPU 完成、导出后移出驻留集；游戏原附件保持原驻留状态。

这不是 MAGSCAN 命中触发器，不能回溯保存已经完成的异常帧，也不保证预选帧一定复现间歇缺陷。不同场景的 pass 布局可以改变，须核对本局 PASSDUMP。

内部 `dm_gfx_texdump_next` 由渲染回放线程调用，覆盖已有请求时不等待 GPU；已收集的诊断复制品延迟到使用它的提交完成后退出驻留，原附件只释放诊断引用。它不提供跨线程控制入口；当前宿主没有调用者。

回归入口：`make native-test-nvn_texdump`。它使用生产渲染遍、真实 Metal 清色及读回，在独立进程验证关闭、单帧、尺寸匹配、多帧和覆盖请求；多帧组包含相邻帧、间隔帧、每帧两个不同颜色的 pass，逐像素核对 PNG/RAW、最终游戏纹理及诊断快照驻留回收。覆盖组在已编码但尚未提交的快照存在时调用真实请求入口，核对提前驻留保留及完成后回收。该入口需要支持 Metal 4 的 Mac；可用 `NXGAL_BE=mtl3` 验证同一实现的 Metal 3 编码路径。CPU 编译或解析检查不算 GPU 通过。
