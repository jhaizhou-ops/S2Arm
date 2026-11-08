#!/usr/bin/env python3
"""天眼道带真机转储着色器（--rt-shaders，内部验证包通道；11-06 Switch2 线 75）：python3 tests/tianyan_rt_shaders_test.py
起因：时之笛 v49r 天眼包没带 rt_shaders（只在本机解包目录），真机首遇现编 10–12 支、撞低区耗尽托管 OOM；本机 --from-extract 出的 dev49 包带了、现编 0。
  转储是游戏内容、只在本机、不分发：玩家包永远没有它，只有显式给 --rt-shaders 的内部验证包带；不给 = 缺省行为不变。
期望按规则手写（不跑被测实现推）：
  ① tianyan_lane.rt_check：两对 <16 位键>.ctl / .code → 2 支；缺一半 / 有别的文件 / 大写键 / 空目录 / 不是目录 → 0 支
  ② tianyan_lane.oneclick_cmd：不给转储时与改前那一行逐字相同（手写）；给了只在末尾多「 --rt-shaders "<远端目录>"」
  ③ tianyan_lane.main：--rt-shaders 指坏目录 → 退 2，且不连天眼（Lane 一构造就算错）
  ④ oneclick_win.put_rt：两对 → 拷进 <解包目录>/rt_shaders/ 逐字节同、返回 2；不成对 / 有别的文件 / 空目录 → Fail，且不建 rt_shaders/
  ⑤ refresh.seed：解包目录有 rt_shaders/ → 产物根现行版本里有同样两对（同 Mac pack/seed_root.sh SEED_DIRS）；没有 → 产物根也没有
反证：改前 refresh.seed 的播种表没有 rt_shaders（⑤ 红），tianyan_lane / oneclick_win 没有这些函数（①–④ 红）。"""
import os, sys, tempfile, unittest
from pathlib import Path
from unittest import mock
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R)); sys.path.insert(0, str(R / 'tools'))
import tianyan_lane as tl   # noqa: E402
from pack.orch import oneclick_win as ow, refresh, roots   # noqa: E402

K1, K2 = '0ac2fdb105c0f532', '5c026b0f5b66c9a8'
def dump(d, files):
    d.mkdir(parents=True, exist_ok=True)
    for n, b in files.items(): (d / n).write_bytes(b)
    return d
GOOD = {f'{K1}.ctl': b'c1', f'{K1}.code': b'x1', f'{K2}.ctl': b'c2', f'{K2}.code': b'x2'}

class T(unittest.TestCase):
    def setUp(self): self.td = tempfile.TemporaryDirectory(prefix='s2a-rt-'); self.t = Path(self.td.name)
    def tearDown(self): roots.remove_owned(self.t); self.td.cleanup()

    def test_1_rt_check(self):
        self.assertEqual(tl.rt_check(dump(self.t / 'ok', GOOD))[0], 2)
        self.assertEqual(tl.rt_check(dump(self.t / 'half', {f'{K1}.ctl': b'c'}))[0], 0)
        self.assertEqual(tl.rt_check(dump(self.t / 'extra', {**GOOD, 'note.txt': b'n'}))[0], 0)
        self.assertEqual(tl.rt_check(dump(self.t / 'upper', {'0AC2FDB105C0F532.ctl': b'c', '0AC2FDB105C0F532.code': b'x'}))[0], 0)
        (self.t / 'empty').mkdir(); self.assertEqual(tl.rt_check(self.t / 'empty')[0], 0)
        self.assertEqual(tl.rt_check(self.t / 'none')[0], 0)

    def test_2_oneclick_cmd(self):
        a = mock.Mock(target='ios', title_id='0400486024DEC000', bundle_id='io.s2arm-exp.v49.t0400486024dec000')
        base = (f'call {tl.PY} -X utf8 -m pack.orch.oneclick_win "R:\\s2a\\lib\\k1\\a.nsp" --out R:\\s2a\\work\\lane\\J1 --target ios'
                ' --shell R:\\s2a\\shell\\S1 --title-id 0400486024DEC000 --bundle-id io.s2arm-exp.v49.t0400486024dec000')
        self.assertEqual(tl.oneclick_cmd(a, '"R:\\s2a\\lib\\k1\\a.nsp"', 'J1', 'R:\\s2a\\shell\\S1'), base)
        self.assertEqual(tl.oneclick_cmd(a, '"R:\\s2a\\lib\\k1\\a.nsp"', 'J1', 'R:\\s2a\\shell\\S1', 'R:\\s2a\\work\\lane\\J1_src\\rt_shaders'),
                         base + ' --rt-shaders "R:\\s2a\\work\\lane\\J1_src\\rt_shaders"')

    def test_3_main_bad_dir_no_lane(self):
        dump(self.t / 'bad', {f'{K1}.ctl': b'c'})
        with mock.patch.object(tl, 'Lane', side_effect=AssertionError('不该连天眼')):
            rc = tl.main(['--commit', 'HEAD', '--source', str(self.t / 'a.nsp'), '--out', str(self.t / 'out'), '--rt-shaders', str(self.t / 'bad')])
        self.assertEqual(rc, 2)

    def test_4_put_rt(self):
        x = self.t / 'x'; x.mkdir()
        self.assertEqual(ow.put_rt(x, dump(self.t / 'ok', GOOD)), 2)
        self.assertEqual({p.name: p.read_bytes() for p in (x / 'rt_shaders').iterdir()}, GOOD)
        for name, files in (('half', {f'{K1}.code': b'x'}), ('extra', {**GOOD, '.DS_Store': b''}), ('empty', {})):
            y = self.t / f'y_{name}'; y.mkdir()
            with self.assertRaises(ow.Fail): ow.put_rt(y, dump(self.t / name, files))
            self.assertFalse((y / 'rt_shaders').exists(), name)

    def test_5_seed_carries_rt_shaders(self):
        store = roots.Roots(self.t / 'roots', shared=False)
        src = self.t / 'ex'; (src / 'exefs').mkdir(parents=True); (src / 'exefs/main').write_bytes(b'm')
        (src / 'romfs').mkdir(); (src / 'romfs/a').write_bytes(b'r'); (src / 'unpack.tsv').write_text('title_id\t0100aaaa00000000\n')
        dump(src / 'rt_shaders', GOOD)
        with mock.patch.dict(os.environ, {'S2A_DUAL': '0'}):
            cur = refresh.seed(store, '原创', src)
        self.assertEqual({p.name: p.read_bytes() for p in (cur / 'rt_shaders').iterdir()}, GOOD)
        store2 = roots.Roots(self.t / 'roots2', shared=False)
        src2 = self.t / 'ex2'; (src2 / 'exefs').mkdir(parents=True); (src2 / 'exefs/main').write_bytes(b'm'); (src2 / 'unpack.tsv').write_text('title_id\t0100aaaa00000000\n')
        with mock.patch.dict(os.environ, {'S2A_DUAL': '0'}):
            cur2 = refresh.seed(store2, '原创', src2)
        self.assertFalse((cur2 / 'rt_shaders').exists())

if __name__ == '__main__':
    r = unittest.main(exit=False, verbosity=1).result
    print(('✗' if r.failures or r.errors else '✓') + f' tianyan_rt_shaders_test：{r.testsRun} 组，失败 {len(r.failures) + len(r.errors)}')
    sys.exit(1 if r.failures or r.errors else 0)
