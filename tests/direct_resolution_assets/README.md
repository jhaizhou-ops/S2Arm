# ABI2 默认 1× 原创测试资产

生成器构造六个原创 IR 程序：全屏三角形 VS、LOD0 尺寸查询 FS、将 LOD0 尺寸写入 SSBO 的 CS、片元坐标渐变 FS，以及同一 LOD2 整数取样 IR 的 exact 与 legacy 两种编译能力配置。它们实际经过生产 CFG、SSA、TexturePass、SPIR-V 生成、AnalyzeSizeTable（由 FetchScales 调用）、ScaleMetadata、SPVC、Dsh Reflect 和 Metal 编译。结论必须来自生产分析：前五项要求 exact，`legacy_fetch_lod2_ps` 要求自然得到 `resolution_scale_exact=false`、`resolution_scale_status=legacy_1x` 且原 `scale_exact=true`；不符合即停止，不补写通过标记。

`tests/direct_resolution_assets_test.sh` 只生成和编译资产，不执行 GPU。`make native-test-nvn_size_abi` 使用公开 NVN bootstrap、录制和提交入口，执行真实尺寸查询并独立读回 float 纹理与 SSBO；同时从真实 shader argument block 的 SUPPORT 地址定位活跃 arena，核对实际绑定表和原支持缓冲前缀。

IR 不包含 Maxwell 机器码。测试将生产 loader 加载的真实 NvShader 放入 prog_get 使用的 serial cache，以便公开 NVN BindProgram 使用；不替换 loader/provider，不构造假 NvShader，不声称覆盖 Maxwell 解码或 ProgramSetShaders 的机器码识别。

当前覆盖：1× 的真实 view/alias、selected mip/layer、换目标附件、同提交 draw→dispatch→draw、同遍换采样绑定、下一提交的数据新鲜度和真实退休后的缓存清空。idx72 目前只验证未使用项保持零；没有声称覆盖第 72 个真实纹理绑定、feedback、非 1× storage 或退休后新局的 GPU 绘制。

宽屏相位场景由 `wide128`、`wide131` 两个独立进程执行，内部倍率仍为 1×。测试只设置正式屏幕与 widen 环境配置，不写 `g_wd_*` 状态：生产核心把 128×72、131×72 目标分别放宽为 156×72、161×72。source 先用原创坐标 FS 真实绘制 mip2/layer1，再通过 level0/count3 的真实 alias view 以 LOD2 取样到另一目标的 mip2/layer1。

128 组的 F=156/128 与所选目标 39/32 相等；131 组的 F=161/131 与 40/32 不等。负 legacy scale 均由生产 `wd_tex_scales` 生成。测试从实际绑定的 SUPPORT 地址核对 F、负 scale、尺寸表及 widen 支持前缀；独立读回 source/target，每组比较 x=1..36、五行共 180 个内部像素。取样期待以像素中心和整数有理数单独计算，同时验证 source 本身是预期坐标渐变。

131 组的真实视口宽为 32×161/131=39.328…，其物理 mip 宽为 40，最后一列中心 39.5 不在三角形 raster 覆盖内。因此这里检验内部采样与片元相位，不把该清零边界当作取样结果。核心区别点包括 128 组 x=3、131 组 x=30，并覆盖其周边多点。131 组实际读回还必须与旧 base-level multiplier、无相位公式对应的 source 像素不同。

每个宽屏进程另画第三张独立目标，使用 `legacy_fetch_lod2_ps`。其唯一编译输入差异是把 `QueryHostSupportsTextureSizeTable` 设为生产接口的默认 false：真实 TexturePass 因而选择当前保留的 `TexelFetchScale` / `TexelFetchScaleY` helper。没有改 metadata/exact 字段，也没有替换运行时 provider。真实 loader 必须接受 ABI2、exact=false、旧 scale_exact=true 的合法程序；实际绑定的 73 个尺寸表项必须全零，前 2608 字节仍完整保留生产 core 的 F、负 legacy scale 等内容。

legacy 目标的同一组 180 个 GPU 像素必须符合 x→x，并再次使用 exact 的 `wide_sample_x` 独立 oracle 对比：128 组要求 0/180 个反例，131 组要求 40/180 个反例，且与两张实际 GPU 输出之间的差异一致。这是**当前生产中保留的 legacy helper GPU 控制**，不是冻结旧 commit 的全宿主负控，不代表旧提交或旧运行时 provider 已执行。

新增宽屏场景是否通过，以各后端实际运行结果为准；生成资产或完成 CPU 数值推演不代表 GPU 通过。
