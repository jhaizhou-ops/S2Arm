# 固定 libavc 的 UBSan 风险记录

2026-10-27；固定 `d380d04a78c6c08702e36aca86d0fd4baee390f9`，源包 SHA
`c0af9b9967854a39c8412e47c6dfbd2b08edd63d33d529707142dd8c04bae08d`。
无游戏，原始 CC0 I/P/B 多参考向量，macOS ARM64/Clang21，CMake Release/ARMV8。

完整上游 UBSan **不干净**。严格 halt-on-error 在 `decoder/ih264d_utils.c:1818`
停止；recover 诊断收集覆盖下表。任何 ASan/LSan 错误、shim/driver UBSan 错误，
或固定源码/文件/行/类型列表外的新诊断均失败。日志不压制、不删除、不降低为绿；
`upstream-ubsan.json` 是 owner 明确要求的存量分类表，不是运行时 sanitizer suppression。
我方 shim/driver 用 `-fno-sanitize-recover=all`；完整上游仅为了收齐诊断保留 recover。
`--sanitize-shim` 单独运行上游 ASan + 我方 shim/driver 严格 ASan/UBSan。

## 发布构建的可达性与影响边界

A：非共享 DPB 建立路径源代码可达，`pu1_buf3 = NULL + offset` 是内部图片第三
指针占位；内部 UV 是交错存储。测试没有解引用该占位，最终 I420 view 另做真实
分配范围校验。产生非法指针本身仍是 C UB，不能据“未解引用”声称无风险。

B：CABAC/CAVLC 的系数/预测局部指针路径源代码可达。部分指针仅作局部迭代，
Release 编译器可能消除其无效算术；没有逐一核验最终机器码，不能宣称优化后不可达。

C：CABAC 初始化、位图、反量化、帧内/帧间预测、去块路径源代码可达；涉及有符号
左移（负数、或结果越过 int 范围）。对应 ARM64 Clang Release 和 sanitizer 构建
都在实际 ARMV8 选择器下跑过向量；Release 逐帧 SHA 与独立参考相等，没有观察到
该样本上的错误像素。**这不是 UB 的编译器语义保证，也不排除其它输入/优化器的
误编译；是否影响更广的发布行为尚未知。** 每行的 A/B/C 都采用这条边界。

## 上游修复调查（源码证据，不冒充新 tag 执行结果）

通过官方 Gitiles `+refs?format=JSON` 固定本次各分支/tag 的 commit，逐一读取
所有报告文件，并比较下表每个触发表达式。结果：

- `main@e67b0aa3b0f5eb15b40c4d148c5d070d8a2c6828`：63/63 个触发表达式仍存在。
- `android-17.0.0_r1@4275faf783bc1ce1eb67fe56043f6f052c0de355`：63/63 个触发表达式仍存在。
- `android-security-16.0.0_r9@82092580f1dafe88defd88f873016b585bbd9e52`：63/63 个触发表达式仍存在。

[Android17 r1 的官方源](https://android.googlesource.com/platform/external/libavc/+/4275faf783bc1ce1eb67fe56043f6f052c0de355/)
METADATA 对应 v1.9.0；[main 的官方源](https://android.googlesource.com/platform/external/libavc/+/e67b0aa3b0f5eb15b40c4d148c5d070d8a2c6828/)
METADATA 仍为 v1.6.0。Android16 r4 是 v1.8.1。至少明确的 `NULL + offset`
语句在较新 tag 仍未改；不能声称换 tag 即消除整组告警。未编译/运行这些候选 tag，
没有完成全部历史修复/安全公告审计；更换 pin 仍由 owner 决定，本实现未换源或改上游。
宏定义/调用上下文可能改变具体可达性，表达式匹配不等于所有版本行为完全相同。

## 逐条存量告警

每行仅匹配固定文件 SHA、行号及诊断类型；列中的表达式是定位摘要。
上游链接指向精确 pin，完整数值诊断及源 SHA 见同目录 JSON 分类表。

| 文件:行 | 类型 | 发布路径/影响 | 表达式摘要 |
|---|---|---|---|
| [common/ih264_deblk_edge_filters.c:588](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_deblk_edge_filters.c#588) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `val = ((((q0 - p0) << 2) + (p1 - q1) + 4) >> 3);` |
| [common/ih264_deblk_edge_filters.c:826](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_deblk_edge_filters.c#826) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `val = ((((q0 - p0) << 2) + (p1 - q1) + 4) >> 3);` |
| [common/ih264_deblk_edge_filters.c:1714](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_deblk_edge_filters.c#1714) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `val = ((((q0_u - p0_u) << 2) + (p1_u - q1_u) + 4) >> 3);` |
| [common/ih264_deblk_edge_filters.c:1728](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_deblk_edge_filters.c#1728) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `val = ((((q0_v - p0_v) << 2) + (p1_v - q1_v) + 4) >> 3);` |
| [common/ih264_deblk_edge_filters.c:1852](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_deblk_edge_filters.c#1852) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `val = ((((q0_u - p0_u) << 2) + (p1_u - q1_u) + 4) >> 3);` |
| [common/ih264_deblk_edge_filters.c:1865](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_deblk_edge_filters.c#1865) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `val = ((((q0_v - p0_v) << 2) + (p1_v - q1_v) + 4) >> 3);` |
| [common/ih264_ihadamard_scaling.c:161](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_ihadamard_scaling.c#161) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(pi4_tmp_ptr[i], pu2_iscal_mat[0], pu2_weigh_mat[0],` |
| [common/ih264_inter_pred_filters.c:513](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_inter_pred_filters.c#513) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `+ ((pu1_src[0] + pu1_src[1] - pu1_src[-1] - pu1_src[2]) << 2)` |
| [common/ih264_inter_pred_filters.c:609](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_inter_pred_filters.c#609) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `+ ((pu1_src[0] + pu1_src[off1] - pu1_src[-off1] - pu1_src[off2]) << 2)` |
| [common/ih264_inter_pred_filters.c:710](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_inter_pred_filters.c#710) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `- pu1_pred_vert[off2]) << 2)` |
| [common/ih264_inter_pred_filters.c:722](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_inter_pred_filters.c#722) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `- pu1_pred_horz[2]) << 2)` |
| [common/ih264_iquant_itrans_recon.c:141](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_iquant_itrans_recon.c#141) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(q0, pu2_iscal_mat[0], pu2_weigh_mat[0], u4_qp_div_6, rnd_fact, 4);` |
| [common/ih264_iquant_itrans_recon.c:149](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_iquant_itrans_recon.c#149) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(q2, pu2_iscal_mat[2], pu2_weigh_mat[2], u4_qp_div_6, rnd_fact, 4);` |
| [common/ih264_iquant_itrans_recon.c:155](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_iquant_itrans_recon.c#155) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(q1, pu2_iscal_mat[1], pu2_weigh_mat[1], u4_qp_div_6, rnd_fact, 4);` |
| [common/ih264_iquant_itrans_recon.c:158](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_iquant_itrans_recon.c#158) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(q3, pu2_iscal_mat[3], pu2_weigh_mat[3], u4_qp_div_6, rnd_fact, 4);` |
| [common/ih264_iquant_itrans_recon.c:291](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_iquant_itrans_recon.c#291) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(q0, pu2_iscal_mat[0], pu2_weigh_mat[0], u4_qp_div_6, rnd_fact, 4);` |
| [common/ih264_iquant_itrans_recon.c:409](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_iquant_itrans_recon.c#409) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(q, pu2_iscale_mat[i], pu2_weigh_mat[i], qp_div, rnd_fact, 6);` |
| [common/ih264_iquant_itrans_recon.c:683](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_iquant_itrans_recon.c#683) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(q, pu2_iscale_mat[0], pu2_weigh_mat[0], qp_div, rnd_fact, 6);` |
| [common/ih264_iquant_itrans_recon.c:822](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_iquant_itrans_recon.c#822) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(q0, pu2_iscal_mat[0], pu2_weigh_mat[0], u4_qp_div_6, rnd_fact, 4);` |
| [common/ih264_iquant_itrans_recon.c:826](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_iquant_itrans_recon.c#826) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(q2, pu2_iscal_mat[2], pu2_weigh_mat[2], u4_qp_div_6, rnd_fact, 4);` |
| [common/ih264_iquant_itrans_recon.c:832](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_iquant_itrans_recon.c#832) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(q1, pu2_iscal_mat[1], pu2_weigh_mat[1], u4_qp_div_6, rnd_fact, 4);` |
| [common/ih264_iquant_itrans_recon.c:835](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_iquant_itrans_recon.c#835) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `INV_QUANT(q3, pu2_iscal_mat[3], pu2_weigh_mat[3], u4_qp_div_6, rnd_fact, 4);` |
| [common/ih264_luma_intra_pred_filters.c:1855](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1855) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `b += ((*pu1_tmp1++) - (*pu1_tmp2--)) << 1; /* x=2 */` |
| [common/ih264_luma_intra_pred_filters.c:1857](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1857) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `b += (tmp << 1) + tmp; /* x=3 */` |
| [common/ih264_luma_intra_pred_filters.c:1858](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1858) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `b += ((*pu1_tmp1++) - (*pu1_tmp2--)) << 2; /* x=4 */` |
| [common/ih264_luma_intra_pred_filters.c:1861](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1861) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `b += (tmp << 2) + tmp; /* x=5 */` |
| [common/ih264_luma_intra_pred_filters.c:1863](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1863) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `b += (tmp << 2) + (tmp << 1); /* x=6 */` |
| [common/ih264_luma_intra_pred_filters.c:1865](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1865) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `b += (tmp << 3) - tmp; /* x=7 */` |
| [common/ih264_luma_intra_pred_filters.c:1866](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1866) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `b += ((*pu1_tmp1) - (*pu1_topleft)) << 3; /* x=8 */` |
| [common/ih264_luma_intra_pred_filters.c:1868](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1868) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `b = ((b << 2) + b + 32) >> 6; /*! (5*H + 32)>>6 */` |
| [common/ih264_luma_intra_pred_filters.c:1877](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1877) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `c += ((*pu1_tmp1) - (*pu1_tmp2)) << 1; /* y=2 */` |
| [common/ih264_luma_intra_pred_filters.c:1881](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1881) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `c += (tmp << 1) + tmp; /* y=3 */` |
| [common/ih264_luma_intra_pred_filters.c:1884](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1884) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `c += ((*pu1_tmp1) - (*pu1_tmp2)) << 2; /* y=4 */` |
| [common/ih264_luma_intra_pred_filters.c:1889](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1889) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `c += (tmp << 2) + tmp; /* y=5 */` |
| [common/ih264_luma_intra_pred_filters.c:1893](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1893) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `c += (tmp << 2) + (tmp << 1); /* y=6 */` |
| [common/ih264_luma_intra_pred_filters.c:1897](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1897) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `c += (tmp << 3) - tmp; /* y=7 */` |
| [common/ih264_luma_intra_pred_filters.c:1901](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1901) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `c += ((*pu1_tmp1) - (*pu1_topleft)) << 3; /* y=8 */` |
| [common/ih264_luma_intra_pred_filters.c:1903](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1903) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `c = ((c << 2) + c + 32) >> 6; /*! (5*V + 32)>>32 */` |
| [common/ih264_luma_intra_pred_filters.c:1912](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1912) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `tmpx_init = -(b << shift); /* -8b */` |
| [common/ih264_luma_intra_pred_filters.c:1913](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/common/ih264_luma_intra_pred_filters.c#1913) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `tmp = a - (c << shift) + 16; /* a-((4or8)*c)+16 */` |
| [decoder/ih264d_cabac.c:67](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_cabac.c#67) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `ps_cab_env->u4_code_int_range = (HALF - 2) << 23;` |
| [decoder/ih264d_inter_pred.c:622](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_inter_pred.c#622) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `+ (((u1_sub_y << 2) + i2_tmp_mv_y) << u1_mb_fld);` |
| [decoder/ih264d_inter_pred.c:626](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_inter_pred.c#626) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `i2_frm_y = CLIP3(((1 - u1_dma_ht) << u1_mb_fld),` |
| [decoder/ih264d_inter_pred.c:768](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_inter_pred.c#768) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `+ (((u1_sub_y << 1) + i2_tmp_mv_y) << u1_mb_fld);` |
| [decoder/ih264d_inter_pred.c:772](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_inter_pred.c#772) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `i2_frm_y = CLIP3(((1 - u1_dma_ht) << u1_mb_fld),` |
| [decoder/ih264d_parse_cabac.c:711](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cabac.c#711) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `SET_BIT(ps_tu_8x8->au4_sig_coeff_map[i>31], (i > 31 ? i - 32:i));` |
| [decoder/ih264d_parse_cabac.c:765](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cabac.c#765) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `SET_BIT(ps_tu_8x8->au4_sig_coeff_map[i>31], (i > 31 ? i - 32:i));` |
| [decoder/ih264d_parse_cabac.c:1102](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cabac.c#1102) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += NUM_COEFFS_IN_4x4BLK;` |
| [decoder/ih264d_parse_cabac.c:1269](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cabac.c#1269) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += (2 * NUM_COEFFS_IN_4x4BLK);` |
| [decoder/ih264d_parse_cabac.c:1353](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cabac.c#1353) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += 64;` |
| [decoder/ih264d_parse_cabac.c:1589](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cabac.c#1589) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += MB_CHROM_SIZE;` |
| [decoder/ih264d_parse_cavlc.c:1407](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cavlc.c#1407) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += 64;` |
| [decoder/ih264d_parse_cavlc.c:1799](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cavlc.c#1799) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += NUM_COEFFS_IN_4x4BLK;` |
| [decoder/ih264d_parse_cavlc.c:1988](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cavlc.c#1988) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += NUM_COEFFS_IN_4x4BLK;` |
| [decoder/ih264d_parse_cavlc.c:2177](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cavlc.c#2177) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += NUM_COEFFS_IN_4x4BLK;` |
| [decoder/ih264d_parse_cavlc.c:2365](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cavlc.c#2365) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += NUM_COEFFS_IN_4x4BLK;` |
| [decoder/ih264d_parse_cavlc.c:2532](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cavlc.c#2532) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += 64;` |
| [decoder/ih264d_parse_cavlc.c:2536](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cavlc.c#2536) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += (2 * NUM_COEFFS_IN_4x4BLK);` |
| [decoder/ih264d_parse_cavlc.c:2702](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_parse_cavlc.c#2702) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pi2_coeff_block += MB_CHROM_SIZE;` |
| [decoder/ih264d_process_intra_mb.c:664](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_process_intra_mb.c#664) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `RESET_BIT(u4_sig_coeff_map,idx);` |
| [decoder/ih264d_process_intra_mb.c:677](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_process_intra_mb.c#677) | signed-left-shift | C；本样本未见像素影响，整体仍未知 | `RESET_BIT(u4_sig_coeff_map,idx);` |
| [decoder/ih264d_process_intra_mb.c:1346](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_process_intra_mb.c#1346) | null-pointer-offset | B；本样本未见像素影响，整体仍未知 | `pu1_luma_pred_buffer +=` |
| [decoder/ih264d_utils.c:1818](https://android.googlesource.com/platform/external/libavc/+/d380d04a78c6c08702e36aca86d0fd4baee390f9/decoder/ih264d_utils.c#1818) | null-pointer-offset | A；本样本未见像素影响，整体仍未知 | `ps_pic_buf->pu1_buf3 = (UWORD8 *)(NULL) + u4_offset;` |
