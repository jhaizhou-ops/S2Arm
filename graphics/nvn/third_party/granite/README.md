来源：https://github.com/Themaister/Granite 提交 5cf67b50a1029dce4d2f53bbcd0d20332f4a6614，
取 `assets/shaders/decode/` 下 s3tc.comp、rgtc.comp、bc6.comp、bc7.comp 及其包含的 rgtc.h、
bitextract.h。许可见 LICENSE（MIT，作者 Hans-Kristian Arntzen）。

用途：不支持 BC 压缩格式的安卓 GPU 上，直连层用 compute 着色器把 BC 纹理解压成普通纹
理（android/native/nvn/nvn_vk_bcdec.c）。本地差异（若有）在文件内以
`S2ARM LOCAL` 注记逐处标明；其余内容与上游提交逐字节一致。

本地改动清单：
- 四个 .comp 顶部补 `#extension GL_GOOGLE_include_directive : require`（上游靠构建
  系统隐式开启；glslc / glslangValidator 均需显式声明）。
- rgtc.comp：`SIGNED` specialization constant + `decode_alpha_rgtc_signed`——上游只有
  UNORM，BC4/BC5 SNORM 是本地实现（端点 −128 钳到 −127，index 6/7 为 −1/+1）。
- s3tc.comp：BC3 alpha 走本地 `decode_alpha_bc3`（截断整数插值，与仓内 CPU 参考
  bcdec__smooth_alpha_block 位级一致）；上游共用的 decode_alpha_rgtc 是 float
  插值 + 存储四舍五入，边界值差 ±1。RGTC 族不动：其 CPU 参考 bcdec__bc4_block
  本就是四舍五入权重，与 float 结果一致。
