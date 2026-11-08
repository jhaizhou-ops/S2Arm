#!/usr/bin/env python3
"""能力卡数据口径（docs/能力卡_数据口径.md，#717）引用的源表：表在、表头含所述列、枚举取值合法。

不生成能力卡、不判定三轴，只核生成器要读的输入形状；每条校验都配合成反例，证明它能红。
"""

import re, sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOC = 'docs/能力卡_数据口径.md'
FPS_LIST = 'docs/名单_60帧/'   # 按款登记目录（10-30，tools/reglist.py），读取合并
FPS_CAP = 'docs/名单_60帧能力覆盖/'
WIDE_RATIO = 'docs/名单_满屏比例/'
WIDE_ON = 'graphics/widen/tables/verified.tsv'
FPS_DIR = 'runtime/fps'

LOGIC_SPEED = {'绿', '红', '判不出', '未验'}
LAYERS = ('L1交换间隔', 'L2引擎限帧', 'L3时间步')
FIVE = ('已具备', '部分', '缺', '不需要', '未知')
# 五档原样，后面最多跟一段全角括注（现表：「缺（据 R7，未实测）」）；括注不是第六档
LAYER_RE = re.compile(r'(%s)(（[^（）]+）)?' % '|'.join(FIVE))
RATIO_VERDICT = {'过', '不过', '未验'}
PID_RE = re.compile(r'[0-9A-F]{16}')
BID_RE = re.compile(r'[0-9a-f]{32}')


def parse(text, header_in_comment=None):
    """→ (表头, 数据行)。表头 = 第一条非 # 行；header_in_comment 给定时取以它开头的注释行（verified.tsv 的写法）"""
    lines = [l for l in text.split('\n') if l]
    if header_in_comment:
        heads = [l[1:].strip() for l in lines if l.startswith('#') and l[1:].strip().startswith(header_in_comment)]
        if not heads: raise AssertionError(f'找不到以「{header_in_comment}」开头的注释表头')
        head, data = heads[0].split('\t'), [l for l in lines if not l.startswith('#')]
    else:
        body = [l for l in lines if not l.startswith('#')]
        if not body: raise AssertionError('没有表头行')
        head, data = body[0].split('\t'), body[1:]
    rows = []
    for n, l in enumerate(data, 1):
        cells = l.split('\t')
        if len(cells) != len(head): raise AssertionError(f'第 {n} 行 {len(cells)} 列，表头 {len(head)} 列')
        rows.append(dict(zip(head, cells)))
    return head, rows


def check_columns(head, need):
    missing = [c for c in need if c not in head]
    if missing: raise AssertionError(f'缺列：{missing}')


def check_identity(rows):
    for n, r in enumerate(rows, 1):
        if not PID_RE.fullmatch(r['程序号']): raise AssertionError(f'第 {n} 行程序号不是 16 位大写十六进制：{r["程序号"]!r}')
        if not BID_RE.fullmatch(r['构建号']): raise AssertionError(f'第 {n} 行构建号不是 32 位小写十六进制：{r["构建号"]!r}')


def check_enum(rows, col, allowed):
    for n, r in enumerate(rows, 1):
        if r[col] not in allowed: raise AssertionError(f'第 {n} 行「{col}」= {r[col]!r}，不在 {sorted(allowed)}')


def check_layers(rows):
    for n, r in enumerate(rows, 1):
        for col in LAYERS:
            if not LAYER_RE.fullmatch(r[col]): raise AssertionError(f'第 {n} 行「{col}」= {r[col]!r}，不是五档（可带一段全角括注）')


def check_green_has_pair(rows):
    """逻辑速度=绿 只认 tools/fps_speed_judge.py 关 / 开两局的峰值速度比：逻辑速度局要写出关局、开局两个目录和 ρ 读数（#743 F-fps-green-unjudged）"""
    for n, r in enumerate(rows, 1):
        if r['逻辑速度'] != '绿': continue
        g = r['逻辑速度局']
        if not ('_off' in g and '_on' in g and 'ρ' in g): raise AssertionError(f'第 {n} 行逻辑速度=绿，但逻辑速度局没写关 / 开两局目录与 ρ：{g[:60]!r}')


UNMEASURED = ('未到MARK', '未到 MARK', '未实测', '没读到')


def check_l3_measured(rows):
    """L3=不需要 要有读数：依据自己写着「无速度比」又写着没到 MARK / 未实测 的，只能记「未知」（#743 F-l3-native-unmeasured）"""
    for n, r in enumerate(rows, 1):
        why = r['L3依据']
        if r['L3时间步'].startswith('不需要') and '无速度比' in why and any(u in why for u in UNMEASURED):
            raise AssertionError(f'第 {n} 行 L3=不需要，但依据写无速度比且未实测：{why[:60]!r}')


def check_fps_tables(names, read):
    """runtime/fps/<构建号前16位>.tsv：文件名 16 位小写十六进制，build 行与文件名相同（runtime/src/fps.c 不符整表不用）"""
    for name in names:
        stem = name[:-4]
        if not (name.endswith('.tsv') and re.fullmatch(r'[0-9a-f]{16}', stem)): raise AssertionError(f'文件名不是 <16 位小写十六进制>.tsv：{name}')
        builds = [l.split()[1] for l in read(name).split('\n') if l.split()[:1] == ['build'] and len(l.split()) >= 2]
        if builds != [stem]: raise AssertionError(f'{name} 的 build 行 = {builds}，应只有一行 build {stem}')


def text(rel):
    if rel.startswith('docs/名单_') and rel.endswith('/'):   # 按款登记目录：合并读
        sys.path.insert(0, str(ROOT / 'tools')); import reglist
        return reglist.text(str(ROOT), rel[5:-1])
    return (ROOT / rel).read_text(encoding='utf-8')


class RealTables(unittest.TestCase):
    """仓内真表；每条打出射程（扫了几行）"""

    def report(self, what, n):
        print(f'  {what}：{n} 行', flush=True)
        self.assertGreater(n, 0, f'{what} 没有数据行，校验是空转')

    def test_doc_names_every_source(self):
        doc = text(DOC)
        for rel in (FPS_LIST, FPS_CAP, WIDE_RATIO, WIDE_ON, FPS_DIR + '/', '逻辑速度局', *LAYERS, *FIVE, *LOGIC_SPEED, *RATIO_VERDICT):
            self.assertIn(rel, doc, f'口径文档没写到 {rel}')

    def test_fps_list(self):
        head, rows = parse(text(FPS_LIST))
        check_columns(head, ['程序号', '构建号', '逻辑速度', '逻辑速度局'])
        check_identity(rows); check_enum(rows, '逻辑速度', LOGIC_SPEED); check_green_has_pair(rows)
        self.report(FPS_LIST, len(rows))

    def test_fps_capability(self):
        head, rows = parse(text(FPS_CAP))
        check_columns(head, ['程序号', '构建号', *LAYERS, 'L1依据', 'L2依据', 'L3依据'])
        check_identity(rows); check_layers(rows); check_l3_measured(rows)
        self.report(FPS_CAP, len(rows))

    def test_widen_ratio(self):
        head, rows = parse(text(WIDE_RATIO))
        check_columns(head, ['程序号', '构建号', '档位', '平台', '结论'])
        check_identity(rows); check_enum(rows, '结论', RATIO_VERDICT)
        for n, r in enumerate(rows, 1):
            self.assertTrue(r['档位'] and r['平台'], f'第 {n} 行档位 / 平台为空：按比例分行的限定丢了')
        self.report(WIDE_RATIO, len(rows))

    def test_widen_verified(self):
        head, rows = parse(text(WIDE_ON), header_in_comment='程序号\t')
        check_columns(head, ['程序号', '构建号'])
        check_identity(rows)
        self.report(WIDE_ON, len(rows))

    def test_fps_enable_tables(self):
        names = sorted(p.name for p in (ROOT / FPS_DIR).iterdir())
        check_fps_tables(names, lambda n: text(f'{FPS_DIR}/{n}'))
        self.report(FPS_DIR, len(names))


class Negatives(unittest.TestCase):
    """合成反例：每条校验都要能红"""

    def red(self, fn, *a):
        with self.assertRaises(AssertionError): fn(*a)

    def test_missing_logic_speed_column(self):
        head, _ = parse('# 注\n程序号\t构建号\t逻辑速度局\n')
        self.red(check_columns, head, ['逻辑速度', '逻辑速度局'])

    def test_logic_speed_out_of_enum(self):
        for bad in ('黄', '', '绿 ', '绿（两局）', 'green'):
            with self.subTest(bad=bad):
                self.red(check_enum, [{'逻辑速度': bad}], '逻辑速度', LOGIC_SPEED)
        check_enum([{'逻辑速度': v} for v in LOGIC_SPEED], '逻辑速度', LOGIC_SPEED)

    def test_layer_values(self):
        good = ['已具备', '缺（据 R7，未实测）', '未知（无留存）', '不需要', '部分']
        for v in good:
            check_layers([{c: v for c in LAYERS}])
        for bad in ('具备', '缺(据 R7)', '缺（据 R7）（又一段）', '缺（', '（据 R7）', '缺 （据 R7）', '', '已验'):
            with self.subTest(bad=bad):
                self.red(check_layers, [{**{c: '缺' for c in LAYERS}, 'L3时间步': bad}])

    def test_row_width_and_identity(self):
        self.red(parse, '程序号\t构建号\n0100726014352000\n')
        self.red(check_identity, [{'程序号': '0100726014352000', '构建号': 'DB0507F36B84200AC05F75D76ED5026F'}])
        self.red(check_identity, [{'程序号': '0100726014352000', '构建号': 'db0507f36b84200a'}])
        self.red(check_identity, [{'程序号': '0100a3501946e000', '构建号': '0d9649011312f62e93f6a5673a09d7e9'}])

    def test_comment_header(self):
        head, rows = parse('# 说明\n# 程序号\t构建号\t款\n0100726014352000\tdb0507f36b84200ac05f75d76ed5026f\td2r\n', header_in_comment='程序号\t')
        self.assertEqual((head, len(rows)), (['程序号', '构建号', '款'], 1))
        self.red(parse, '# 说明\n0100726014352000\tdb0507f36b84200ac05f75d76ed5026f\n', '程序号\t')

    def test_green_needs_pair_and_rho(self):
        check_green_has_pair([{'逻辑速度': '绿', '逻辑速度局': 'entry_check/x_off / _on，ρ 中位 0.85'}])
        check_green_has_pair([{'逻辑速度': '未验', '逻辑速度局': '游戏原生 60 帧，无关 / 开两局'}])
        for bad in ('游戏原生 60 帧，无关 / 开两局', 'entry_check/x_off / _on，r = 1.025 判绿', 'ρ 0.9'):
            with self.subTest(bad=bad):
                self.red(check_green_has_pair, [{'逻辑速度': '绿', '逻辑速度局': bad}])

    def test_l3_needs_reading(self):
        check_l3_measured([{'L3时间步': '不需要', 'L3依据': '游戏原生就出 60；无速度比读数'}])
        check_l3_measured([{'L3时间步': '未知', 'L3依据': '无速度比读数；能玩清单记未到MARK'}])
        for why in ('无速度比读数；能玩清单记未到MARK', '规则推断判不出，未实测；无速度比读数', '无速度比，帧率比没读到'):
            with self.subTest(why=why):
                self.red(check_l3_measured, [{'L3时间步': '不需要', 'L3依据': why}])

    def test_fps_table_names(self):
        ok = {'db0507f36b84200a.tsv': 'build db0507f36b84200a\npresent display\n'}
        check_fps_tables(ok, ok.get)
        for name, body in [('DB0507F36B84200A.tsv', 'build DB0507F36B84200A\n'),
                           ('db0507f36b84200ac05f.tsv', 'build db0507f36b84200ac05f\n'),
                           ('db0507f36b84200a.txt', 'build db0507f36b84200a\n'),
                           ('db0507f36b84200a.tsv', 'build 0d9649011312f62e\n'),
                           ('db0507f36b84200a.tsv', 'present display\n')]:
            with self.subTest(name=name, body=body):
                self.red(check_fps_tables, [name], {name: body}.get)


if __name__ == '__main__':
    unittest.main(verbosity=2)
