#!/usr/bin/env python3
"""遍内自采样改片上读取的离线两半（10-30 帧率能耗线）：S2A.Dsh DshFetch.ProjUv / Variant 的 proj 标记（graphics/tools/direct/dsh/Fetch.cs）、
DshCompiler.ScrUvLocns（graphics/tools/direct/dsh/Dsh.cs），经 dsh_cmp --fn fetch_variant / scr_uv_locns 调（graphics/tools/direct/tests/dshfn.py）。
夹具是照塞尔达 753d0169ae3ce4f0（片元）/ 0224fecce6565477（顶点）写法手写的小段 MSL，期望值按写法手写，不跑被测实现得来；每条正例配反例。"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "graphics" / "tools" / "direct" / "tests"))
import dshfn  # noqa: E402


def variant(msl, binds):
    return dshfn.fn("fetch_variant", msl, binds, False)


def scr_uv_locns(src):
    return dshfn.fn("scr_uv_locns", src)

FS = """#include <metal_stdlib>
using namespace metal;

struct spvDescriptorSetBuffer0
{
    texture2d<float> fp_t_tcb_8 [[id(0)]];
    sampler fp_t_tcb_8Smplr [[id(1)]];
    texture2d<float> fp_t_tcb_A [[id(2)]];
    sampler fp_t_tcb_ASmplr [[id(3)]];
};

struct main0_out
{
    float4 m_10 [[color(0)]];
    float4 m_11 [[color(1)]];
};

struct main0_in
{
    float4 m_54 [[user(locn6)]];
    float4 m_60 [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    main0_out out = {};
    float _98 = in.m_54.w;
    float _104 = in.m_54.x;
    float _108 = in.m_54.y;
    float _159 = 1.0 / _98;
    float _199 = _104 * _159;
    float _201 = _159 * _108;
    float2 _946 = float2(_199, _201);
    float _300 = in.m_60.x;
    float _301 = in.m_60.y;
    float2 _950 = float2(_300, _301);
    float _203 = spvDescriptorSet0.fp_t_tcb_A.sample(spvDescriptorSet0.fp_t_tcb_ASmplr, select(_946, float2(0.0), isnan(_946))).x;
    float _204 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, select(_950, float2(0.0), isnan(_950))).x;
    out.m_10 = float4(_203);
    out.m_11 = float4(_204);
    return out;
}
"""
BINDS = [{"kind": "tex", "msl_name": "fp_t_tcb_8", "reg": 0}, {"kind": "tex", "msl_name": "fp_t_tcb_A", "reg": 1}]

VS = """struct main0_out
{
    float4 m_70 [[user(locn6)]];
    float4 m_71 [[user(locn7)]];
    float4 gl_Position [[position]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4& s2a_push [[buffer(13)]])
{
    main0_out out = {};
    out.m_70 = float4(0.0, 0.0, 0.0, 1.0);
    out.gl_Position.x = 0.0;
    float _673 = in.m_1.x;
    float _677 = in.m_1.w;
    float _679 = in.m_1.y;
    out.gl_Position.x = _673;
    out.gl_Position.w = _677;
    out.gl_Position.y = _679;
    float _683 = _673 + _677;
    out.m_70.w = _677;
    float _685 = -_679;
    float _687 = _685 + _677;
    if (_673 > 0.0)
    {
        float _691 = _673;
    }
    float _695 = _683 * 0.5;
    float _697 = _687 * 0.5;
    out.m_70.x = _695;
    out.m_70.y = _697;
    out.m_71.x = _673;
    out.m_71.y = _679;
    out.m_71.w = _677;
    { float4 s2a_q = s2a_push; out.gl_Position.x = out.gl_Position.x * (1.0f - s2a_q.z); }
    return out;
}

"""


def vs_with_z(body):
    """main0 原样，再复制一份同体的 main0_z（两个入口都要成立）"""
    z = body.replace("vertex main0_out main0(", "vertex main0_out main0_z(", 1).split("struct main0_out", 1)[1]
    return body + "struct main0_out" + z


class ProjUv(unittest.TestCase):
    def test_projective_and_direct(self):
        fv, meta = variant(FS, BINDS)
        self.assertIsNotNone(fv)
        calls = sorted(meta["calls"], key=lambda c: c["tex_reg"])
        # 槽 1（fp_t_tcb_A）：in.m_54.xy * (1 / in.m_54.w)，乘数前后都认 → proj，插值量 locn6；槽 0：直接插值 locn0，无 proj
        self.assertEqual(calls, [{"fc": 1, "tex_reg": 0, "varying_locn": 0}, {"fc": 0, "tex_reg": 1, "varying_locn": 6, "proj": 1}])
        self.assertEqual(meta["mixed_regs"], [])

    def test_w_from_other_varying_is_not_projective(self):
        bad = FS.replace("float _98 = in.m_54.w;", "float _98 = in.m_60.w;")
        fv, meta = variant(bad, BINDS)
        self.assertEqual([c["tex_reg"] for c in meta["calls"]], [0])   # 槽 1 不再可改

    def test_different_reciprocal_is_not_projective(self):
        bad = FS.replace("float _201 = _159 * _108;", "float _201 = _104 * _108;")
        fv, meta = variant(bad, BINDS)
        self.assertEqual([c["tex_reg"] for c in meta["calls"]], [0])

    def test_inlined_component_reads(self):
        # 11-07 卡顿线：翻译器关 DebugMode 后表达式传播把分量读并进乘法 / 倒数 / float2（旷野之息 0b6d8f4f993ae7ee：「_70 = in.m_40.x * _64; _64 = 1.0 / in.m_40.w;」），
        #   期望同展开写法：槽 1 proj、locn6；槽 0 直接插值 locn0
        inl = FS.replace("""    float _98 = in.m_54.w;
    float _104 = in.m_54.x;
    float _108 = in.m_54.y;
    float _159 = 1.0 / _98;
    float _199 = _104 * _159;
    float _201 = _159 * _108;
""", """    float _159 = 1.0 / in.m_54.w;
    float _199 = in.m_54.x * _159;
    float _201 = _159 * in.m_54.y;
""").replace("""    float _300 = in.m_60.x;
    float _301 = in.m_60.y;
    float2 _950 = float2(_300, _301);""", """    float2 _950 = float2(in.m_60.x, in.m_60.y);""")
        self.assertNotIn("float _98", inl); self.assertIn("float2 _950 = float2(in.m_60.x, in.m_60.y);", inl)   # 夹具确实换成了并入写法
        fv, meta = variant(inl, BINDS)
        self.assertIsNotNone(fv)
        calls = sorted(meta["calls"], key=lambda c: c["tex_reg"])
        self.assertEqual(calls, [{"fc": 1, "tex_reg": 0, "varying_locn": 0}, {"fc": 0, "tex_reg": 1, "varying_locn": 6, "proj": 1}])
        # 反例：并入写法里 w 取自别的插值量 → 槽 1 不是投影坐标；x 与 y 来自不同插值量 → 槽 0 不可改
        bad = inl.replace("float _159 = 1.0 / in.m_54.w;", "float _159 = 1.0 / in.m_60.w;")
        self.assertEqual([c["tex_reg"] for c in variant(bad, BINDS)[1]["calls"]], [0])
        bad2 = inl.replace("float2(in.m_60.x, in.m_60.y)", "float2(in.m_60.x, in.m_54.y)")
        self.assertEqual([c["tex_reg"] for c in variant(bad2, BINDS)[1]["calls"]], [1])

    def test_reassigned_coordinate_is_not_resolved(self):
        # 11-07 卡顿线：坐标分量的临时量在别处又被赋值（循环变量，旷野之息 0e0440f4f042f99d「float _80 = _46;」后循环体里「_80 = _299;」）→ 值随路径变，不能代回成插值量读，
        #   期望槽 0（float2(_300, _301)，_300 被改写）不可改，槽 1 照旧
        bad = FS.replace("    out.m_10 = float4(_203);\n", "    _300 = _201;\n    out.m_10 = float4(_203);\n")
        self.assertNotEqual(bad, FS)
        self.assertEqual([c["tex_reg"] for c in variant(bad, BINDS)[1]["calls"]], [1])

    def test_second_use_marks_mixed(self):
        extra = "    float _205 = spvDescriptorSet0.fp_t_tcb_A.sample(spvDescriptorSet0.fp_t_tcb_ASmplr, float2(0.5, 0.5)).x;\n"
        bad = FS.replace("    out.m_10 = float4(_203);\n", extra + "    out.m_10 = float4(_203 + _205);\n")
        fv, meta = variant(bad, BINDS)
        self.assertEqual(meta["mixed_regs"], [1])   # 槽 1 还有一处非本像素读法 → 混用，宿主不改


class ScrUv(unittest.TestCase):
    def test_screen_uv_locn(self):
        # m_70 = ((P.x + P.w) / 2, (-P.y + P.w) / 2, ·, P.w) → locn6；m_71 = (P.x, P.y, ·, P.w) 不是 → 不记
        self.assertEqual(scr_uv_locns(vs_with_z(VS)), [6])

    def test_main0_only_is_enough_when_no_z_entry(self):
        self.assertEqual(scr_uv_locns(VS), [6])

    def test_assignment_inside_block(self):
        bad = VS.replace("    out.m_70.x = _695;\n", "    if (_673 > 0.0) { out.m_70.x = _695; }\n")
        self.assertEqual(scr_uv_locns(vs_with_z(bad)), [])

    def test_position_changed_inside_block(self):
        bad = VS.replace("        float _691 = _673;\n", "        out.gl_Position.y = _673;\n")
        self.assertEqual(scr_uv_locns(vs_with_z(bad)), [])

    def test_y_not_negated(self):
        self.assertEqual(scr_uv_locns(vs_with_z(VS.replace("float _685 = -_679;", "float _685 = _679;"))), [])

    def test_w_not_position_w(self):
        self.assertEqual(scr_uv_locns(vs_with_z(VS.replace("    out.m_70.w = _677;\n", "    out.m_70.w = _673;\n"))), [])

    def test_z_entry_disagrees(self):
        good, bad = VS, VS.replace("float _695 = _683 * 0.5;", "float _695 = _683 * 0.25;")
        z = bad.replace("vertex main0_out main0(", "vertex main0_out main0_z(", 1).split("struct main0_out", 1)[1]
        self.assertEqual(scr_uv_locns(good + "struct main0_out" + z), [])

    def test_inlined_form(self):
        # 11-07 卡顿线：关 DebugMode 后表达式内联（旷野之息 008308c18fc89a42：out.m_72.x = (_237 + _239) * 0.5; out.m_72.y = ((-_241) + _239) * 0.5;），期望同展开写法 → locn6
        inl = VS.replace("""    float _695 = _683 * 0.5;
    float _697 = _687 * 0.5;
    out.m_70.x = _695;
    out.m_70.y = _697;
""", """    out.m_70.x = (_673 + _677) * 0.5;
    out.m_70.y = ((-_679) + _677) * 0.5;
""")
        self.assertNotEqual(inl, VS)
        self.assertEqual(scr_uv_locns(vs_with_z(inl)), [6])
        self.assertEqual(scr_uv_locns(vs_with_z(inl.replace("((-_679) + _677) * 0.5", "(_679 + _677) * 0.5"))), [])   # y 没取负 → 不是
        self.assertEqual(scr_uv_locns(vs_with_z(inl.replace("(_673 + _677) * 0.5", "(_673 + _677) * 0.25"))), [])

    def test_temp_reassigned_in_block_is_not_resolved(self):
        # 临时量在块里又被赋值（值随路径变）→ 不能代回：m_70.x 的来源 _695 在 if 里改写 → 不成立
        bad = VS.replace("        float _691 = _673;\n", "        _695 = _673;\n").replace("    float _695 = _683 * 0.5;\n", "")
        bad = bad.replace("    float4 gl_Position [[position]];", "    float4 gl_Position [[position]];").replace("    out.m_70.w = _677;\n", "    out.m_70.w = _677;\n    float _695 = _683 * 0.5;\n")
        self.assertEqual(scr_uv_locns(vs_with_z(bad)), [])

    def test_no_main0(self):
        self.assertEqual(scr_uv_locns(VS.replace("main0(", "other(")), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
