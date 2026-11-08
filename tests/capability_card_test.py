#!/usr/bin/env python3
"""#717 权威合同的原创合成回归；不读取真实帧率表或游戏资源。"""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('compatibility_report', ROOT / 'tools/compatibility_report.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

FPS = 'docs/名单_60帧.tsv'
CAP = 'docs/名单_60帧能力覆盖.tsv'
ASPECT = 'docs/名单_满屏比例.tsv'
WIDE = 'graphics/widen/tables/verified.tsv'
CENSUS = 'docs/研究/直连泛化普查.md'
LDN = 'docs/方案_联机LDN.md'
STRONG = 'docs/名单_能力强信号.tsv'
DIRECT = 'docs/名单_直连实测.tsv'
PID = '0100ABCDEF123456'
BID = '1234567890abcdef1234567890abcdef'
OTHER = 'fedcba0987654321fedcba0987654321'
REV = 'a' * 40
FPS_PATH = 'runtime/fps/1234567890abcdef.tsv'
FEATURES = {'direct', 'fullscreen', 'fps60', 'online', 'controller', 'rumble', 'gyro', 'quickMenu'}


def sources():
    # 期望表头独立写定，不借被测模块的 HEADERS 生成输入。
    return {
        FPS: '程序号\t构建号\t款\t日期\t帧率\t整机W\t满屏\t包\t依据局\t能力来源\t备注\t逻辑速度\t逻辑速度局\n',
        CAP: '程序号\t构建号\t款\tL1交换间隔\tL1依据\tL2引擎限帧\tL2依据\tL3时间步\tL3依据\t未达标原因\n',
        ASPECT: '程序号\t构建号\t款\t档位\t平台\t结论\t日期\t读数\t依据\n',
        WIDE: '# 程序号\t构建号\t款\t平台\t登记日期\t依据\n',
        CENSUS: '# 原创静态文本\n',
        LDN: '# 原创联机文本\n',
        STRONG: '程序号\t构建号\t能力\t内容哈希\t信号\t依据\t日期\n',
        DIRECT: '程序号\t构建号\t款\t平台\t直连能跑\t进局\t依据\t日期\n',
    }


def fps(s, speed='绿', source='合成规则', bid=BID):
    s[FPS] += '\t'.join([PID, bid, 'synthetic', '2026-10-28', '60/60', '3/3', '100/100',
                          'synthetic-package', 'synthetic-session', source, '', speed,
                          'synthetic-off;synthetic-on']) + '\n'


def cap(s, values=('已具备', '部分', '未知'), bid=BID):
    s[CAP] += '\t'.join([PID, bid, 'synthetic', values[0], '合成文字1', values[1], '合成文字2',
                          values[2], '合成文字3', '未测']) + '\n'


def aspect(s, platform='Mac', ratio='19.5:9', verdict='过', bid=BID):
    s[ASPECT] += '\t'.join([PID, bid, 'synthetic', ratio, platform, verdict, '2026-10-28',
                             '合成读数', '合成依据']) + '\n'


def direct(s, runs='是', platform='Mac', bid=BID):
    s[DIRECT] += '\t'.join([PID, bid, 'synthetic', platform, runs, '否', '合成普查依据', '2026-10-30']) + '\n'


def widen(s, bid=BID):
    s[WIDE] += '\t'.join([PID, bid, 'synthetic', 'apple', '2026-10-28', '合成启用登记']) + '\n'



def split_tables(root):
    """登记表按款拆目录（10-30，tools/reglist.py）：夹具按旧单文件写，git add 前拆成 docs/<表名>/<程序号>.tsv（同表重写 = 整表替换）"""
    import contextlib, io, shutil
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'tools')); import reglist
    for n in reglist.TABLES:
        if (Path(root) / 'docs' / f'{n}.tsv').exists(): shutil.rmtree(Path(root) / 'docs' / n, ignore_errors=True)
    with contextlib.redirect_stdout(io.StringIO()): reglist.migrate(str(root))

class CapabilityCardTest(unittest.TestCase):
    # 直连实测（10-30，census.py direct_reg）：本平台有行 = 启用；能跑 是 / 否 = 已验 / 验证失败；Mac 实测不代 iOS
    def test_direct_census_verified_on_mac_only(self):
        s = sources(); direct(s)
        cards = m.build_model(s, REV, requested_scopes=[('ios', None)])['cards']
        mac = [c for c in cards if c['identity']['targetPlatform'] == 'macos']; ios = [c for c in cards if c['identity']['targetPlatform'] == 'ios']
        self.assertEqual(len(mac), 1); self.assertEqual(len(ios), 1)
        d = mac[0]['features']['direct']
        self.assertEqual((d['support'], d['enabled'], d['verification']), ('supported', 'on', 'verified'))
        self.assertEqual(d['display'], '已开已验（仅登记平台 / 比例范围；非当前包实测）')
        self.assertEqual(ios[0]['features']['direct']['display'], '未验：缺启用记录')
    def test_direct_census_failed(self):
        s = sources(); direct(s, runs='否')
        d = m.build_model(s, REV)['cards'][0]['features']['direct']
        self.assertEqual((d['enabled'], d['verification']), ('on', 'failed'))
        self.assertEqual(d['display'], '已开；验证失败：普查直连局崩溃或卡在致命红行')
    def build(self, s, tables=()):
        result = m.build_model(s, REV, fps_tables=tables)
        self.assertEqual(result['schema'], 's2a.capability-card.v1')
        self.assertEqual(result['sourceRevision'], REV)
        for card in result['cards']:
            self.assertEqual(set(card['features']), FEATURES)
            self.assertIsNone(card['identity']['packageDigest'])
            self.assertIn(card['identity']['targetPlatform'], (None, 'ios', 'macos'))
        return result

    def card(self, model, platform, ratio=None, bid=BID):
        matches = [c for c in model['cards'] if c['identity']['programId'] == PID
                   and c['identity']['buildId'] == bid and c['identity']['targetPlatform'] == platform
                   and c['scope']['ratio'] == ratio]
        self.assertEqual(len(matches), 1, (platform, ratio, bid))
        return matches[0]

    def test_native_sixty_without_table(self):
        s = sources(); fps(s, source='游戏原生 60 帧：原创合成')
        f = self.card(self.build(s), 'ios')['features']['fps60']
        self.assertEqual((f['support'], f['enabled'], f['verification']), ('supported', 'on', 'verified'))
        self.assertIn('已开已验', f['display'])

    def test_native_prefix_not_substring(self):
        s = sources(); fps(s, source='资料提到游戏原生 60 帧')
        c = self.card(self.build(s), 'ios')   # 来源文字里提到「游戏原生 60 帧」不算原生例外：发布原因是缺省开，不是原生
        self.assertNotEqual(c['releaseDefaults']['fps60']['reason'], '游戏原生 60 帧')
        self.assertEqual(c['features']['fps60']['support'], 'supported')

    def test_table_present_red_is_failed(self):
        s = sources(); fps(s, speed='红')
        f = self.card(self.build(s, (FPS_PATH,)), 'ios')['features']['fps60']
        self.assertEqual((f['support'], f['enabled'], f['verification']), ('unsupported', 'off', 'failed'))   # 逻辑速度红 = 强信号：不支持、关
        self.assertEqual(f['display'], '不支持：验证失败：逻辑速度变快')
        self.assertNotIn('已开已验', f['display'])

    def test_table_present_inconclusive_and_unverified(self):
        for speed in ('判不出', '未验'):
            with self.subTest(speed=speed):
                s = sources(); fps(s, speed=speed)
                f = self.card(self.build(s, (FPS_PATH,)), 'ios')['features']['fps60']
                self.assertEqual((f['enabled'], f['verification']), ('on', 'unverified'))
                self.assertEqual(f['display'], '已开未验；未验：缺逻辑速度判定')

    def test_table_absent_historical_green(self):
        s = sources(); fps(s)
        f = self.card(self.build(s), 'ios')['features']['fps60']
        self.assertEqual((f['enabled'], f['verification']), ('off', 'verified'))
        self.assertEqual(f['display'], '未开启')

    def test_other_build_table_not_inherited(self):
        s = sources(); fps(s)
        f = self.card(self.build(s, ('runtime/fps/fedcba0987654321.tsv',)), 'ios')['features']['fps60']
        self.assertFalse(any('fedcba0987654321' in ref for ref in f['evidenceRefs']['enabled']))   # 别构建的表不当本构建的启用证据

    def test_ios_fps_not_applied_to_macos(self):
        s = sources(); fps(s, source='游戏原生 60 帧'); aspect(s)
        model = self.build(s)
        self.assertEqual(self.card(model, 'ios')['features']['fps60']['verification'], 'verified')
        f = self.card(model, 'macos', '19.5:9')['features']['fps60']
        self.assertEqual(f['verification'], 'unverified')

    def test_fullscreen_platform_ratio_isolation(self):
        s = sources(); widen(s); aspect(s); aspect(s, ratio='4:3', verdict='未验')
        aspect(s, platform='iPhone', verdict='未验')
        model = self.build(s)
        good = self.card(model, 'macos', '19.5:9')['features']['fullscreen']
        self.assertEqual((good['enabled'], good['verification']), ('on', 'verified'))
        for platform, ratio in [('macos', '4:3'), ('ios', '19.5:9')]:
            f = self.card(model, platform, ratio)['features']['fullscreen']
            self.assertEqual(f['verification'], 'unverified')
            self.assertEqual(f['reason'], '未验：缺该比例满屏读数')

    def test_duo_is_ios_with_original_ratio(self):
        for platform, ratio in [('Duo', '1.42'), ('Duo 内屏', '1.455'), ('Duo 外屏 + 折叠', '1.42')]:
            with self.subTest(platform=platform):
                s = sources(); widen(s); aspect(s, platform=platform, ratio=ratio)
                f = self.card(self.build(s), 'ios', ratio)['features']['fullscreen']
                self.assertEqual(f['verification'], 'verified')

    def test_fullscreen_failure_not_unsupported(self):
        s = sources(); widen(s); aspect(s, verdict='不过')
        f = self.card(self.build(s), 'macos', '19.5:9')['features']['fullscreen']
        self.assertEqual((f['support'], f['enabled'], f['verification']), ('supported', 'on', 'failed'))   # 满屏比例不过不是强信号
        self.assertEqual(f['display'], '已开；验证失败：满屏比例不过')

    def test_fullscreen_conflict_is_not_best_case(self):
        s = sources(); widen(s); aspect(s); aspect(s, verdict='不过')
        f = self.card(self.build(s), 'macos', '19.5:9')['features']['fullscreen']
        self.assertEqual(f['verification'], 'conflicting')
        self.assertEqual(f['display'], '未验：证据冲突')

    def test_conflicting_speed_is_not_best_case(self):
        s = sources(); fps(s); fps(s, speed='红')
        f = self.card(self.build(s, (FPS_PATH,)), 'ios')['features']['fps60']
        self.assertEqual(f['verification'], 'conflicting')
        self.assertEqual(f['display'], '未验：证据冲突')

    def test_same_program_other_build_no_pass_inheritance(self):
        s = sources(); fps(s, source='游戏原生 60 帧'); cap(s, bid=OTHER)
        model = self.build(s)
        others = [c for c in model['cards'] if c['identity']['buildId'] == OTHER]
        self.assertTrue(others)
        for c in others:
            self.assertEqual(c['features']['fps60']['verification'], 'unverified')
            self.assertNotIn(c['releaseDefaults']['fps60']['reason'], ('逻辑速度绿（仅 iOS 登记范围）', '游戏原生 60 帧'))   # 别构建的绿 / 原生不继承

    def test_six_source_less_features_unknown(self):
        s = sources(); cap(s)
        s[CENSUS] += f'| synthetic | {PID} | 可行 |\n'
        s[LDN] += f'{PID} 合成文字声称联机成功、单测通过\n'
        for card in self.build(s)['cards']:
            for name in ('direct', 'online', 'controller', 'rumble', 'gyro', 'quickMenu'):
                f = card['features'][name]
                self.assertEqual((f['support'], f['enabled'], f['verification']), ('unknown', 'unknown', 'unverified'))
                self.assertEqual(f['display'], '未验：缺启用记录')

    def test_capability_does_not_become_support(self):
        s = sources(); cap(s, ('已具备', '已具备', '已具备'))
        for card in self.build(s)['cards']:   # 全能力出包：support 缺省 supported；能力覆盖「已具备」仍不变成验证
            self.assertEqual(card['features']['fps60']['support'], 'supported')
            self.assertEqual(card['features']['fps60']['verification'], 'unverified')

    def test_legacy_eleven_column_header_rejected(self):
        s = sources(); fps(s)
        lines = s[FPS].splitlines()
        s[FPS] = '\n'.join('\t'.join(line.split('\t')[:-2]) for line in lines) + '\n'
        # #696 名单线 6462929466 明确拒绝旧11列；#717合同泛缺列文案待澄清。
        with self.assertRaises(ValueError):
            self.build(s, (FPS_PATH,))

    def test_unknown_speed_enum_rejected(self):
        s = sources(); fps(s, speed='自称通过')
        with self.assertRaises(ValueError):
            self.build(s)

    def test_deterministic_serialization(self):
        s = sources(); fps(s); cap(s); aspect(s)
        first = self.build(s, (FPS_PATH,))
        second = self.build(dict(reversed(list(s.items()))), (FPS_PATH,))
        self.assertEqual(json.dumps(first, ensure_ascii=False, sort_keys=True),
                         json.dumps(second, ensure_ascii=False, sort_keys=True))

    def test_requested_scope_does_not_inherit_ratio_or_platform(self):
        s = sources(); widen(s); aspect(s)
        model = m.build_model(s, REV, requested_scopes=(('macos', '4:3'), ('ios', '19.5:9')))
        for platform, ratio in [('macos', '4:3'), ('ios', '19.5:9')]:
            f = self.card(model, platform, ratio)['features']['fullscreen']
            self.assertEqual(f['verification'], 'unverified')
            self.assertEqual(f['reason'], '未验：缺该比例满屏读数')

    def test_requested_null_scope_is_not_wildcard(self):
        s = sources(); fps(s, source='游戏原生 60 帧'); aspect(s); widen(s)
        model = m.build_model(s, REV, requested_scopes=((None, None),))
        c = self.card(model, None)
        self.assertEqual(c['features']['fps60']['verification'], 'unverified')
        self.assertEqual(c['features']['fullscreen']['verification'], 'unverified')

    def test_layer_five_values_and_annotation(self):
        for value in ('已具备', '部分', '缺', '不需要', '未知', '缺（据 R7，未实测）'):
            with self.subTest(value=value):
                s = sources(); cap(s, ('已具备', '部分', value))
                c = self.card(self.build(s), None)
                layer = c['fpsLayers']['L3时间步']
                self.assertEqual(len(layer), 1)
                expected = '缺' if value.startswith('缺（') else value
                self.assertEqual(layer[0]['status'], expected)
                self.assertEqual(layer[0]['display'], '未验：能力状态未知' if value == '未知' else expected)
                evidence = {e['id']: e for e in c['evidence']}
                self.assertTrue(layer[0]['evidenceRefs'])
                for ref in layer[0]['evidenceRefs']:
                    self.assertIn(ref, evidence)
                    self.assertIn(evidence[ref]['kind'], ('capabilityRegister', 'sourceText'))
                if value.startswith('缺（'):
                    self.assertTrue(any('据 R7，未实测' in e.get('annotation', '') for e in c['evidence']))

    def test_layer_conflicting_records_preserved(self):
        s = sources(); cap(s, ('已具备', '部分', '缺')); cap(s, ('已具备', '部分', '不需要'))
        c = self.card(self.build(s), None)
        self.assertEqual({r['status'] for r in c['fpsLayers']['L3时间步']}, {'缺', '不需要'})
        self.assertEqual(c['features']['fps60']['verification'], 'unverified')

    def test_evidence_pins_identity_and_source(self):
        s = sources(); fps(s); cap(s); aspect(s)
        for c in self.build(s, (FPS_PATH,))['cards']:
            ids = [e['id'] for e in c['evidence']]
            self.assertEqual(len(ids), len(set(ids)))
            for e in c['evidence']:
                self.assertEqual(e['locator']['revision'], REV)
                self.assertTrue(e['locator']['path'])
                self.assertEqual(e['scope']['programId'], PID)
                self.assertEqual(e['scope']['buildId'], BID)
                self.assertIsNone(e['scope']['packageDigest'])
            for f in c['features'].values():
                for axis, refs in f['evidenceRefs'].items():
                    self.assertIn(axis, ('support', 'enabled', 'verification'))
                    for ref in refs:
                        self.assertIn(ref, ids)

    def test_legacy_render_uses_single_model(self):
        sentinel = {'synthetic': 'not a second judge'}
        with mock.patch.object(m, 'build_model', return_value=sentinel) as build:
            with mock.patch.object(m, 'render_model', return_value='one model') as render:
                self.assertEqual(m.render(sources(), REV), 'one model')
                build.assert_called_once()
                render.assert_called_once_with(sentinel)

    def test_strong_signal_closes_both_keys(self):
        s = sources(); widen(s); aspect(s); fps(s)
        s[STRONG] += f'{PID}\t{BID}\twiden\t0123456789abcdef\t宽屏画面坏\t合成截图\t2026-10-29\n{PID}\t{BID}\tfps60\t0123456789abcdef\t崩溃归因\t合成局\t2026-10-29\n'
        c = self.card(self.build(s, (FPS_PATH,)), 'ios')
        for key, sig in (('fullscreen', '宽屏画面坏'), ('fps60', '崩溃归因')):
            self.assertEqual((c['releaseDefaults'][key]['value'], c['releaseDefaults'][key]['reason']), (0, '强信号：' + sig))
            self.assertEqual((c['features'][key]['support'], c['features'][key]['enabled']), ('unsupported', 'off'))

    def test_stale_strong_signal_kept_like_pack(self):
        # 10-30 改：实现哈希（load 按提交算的 __signal_hashes__）≠ 登记值 → 强信号照旧生效（保持关、待重新实测，复测过删行才放开），能力卡与包里清单一致
        s = sources(); widen(s); aspect(s); fps(s)
        s[STRONG] += f'{PID}\t{BID}\twiden\t0123456789abcdef\t宽屏画面坏\t合成截图\t2026-10-29\n'
        s['__signal_hashes__'] = {'widen': '0123456789abcdef', 'fps60': 'ffffffffffffffff'}
        self.assertEqual(self.card(self.build(s, (FPS_PATH,)), 'ios')['releaseDefaults']['fullscreen']['value'], 0)   # 哈希一致：照旧关
        s['__signal_hashes__'] = {'widen': 'fedcba9876543210', 'fps60': 'ffffffffffffffff'}
        c = self.card(self.build(s, (FPS_PATH,)), 'ios')
        self.assertEqual((c['releaseDefaults']['fullscreen']['value'], c['features']['fullscreen']['support']), (0, 'unsupported'))   # 过时：照旧关
        self.assertEqual(c['releaseDefaults']['fullscreen']['reason'], '强信号（过时·待重新实测）：宽屏画面坏')   # 读数标出过时

    def test_strong_signal_outside_contract_rejected(self):
        s = sources(); s[STRONG] += f'{PID}\t{BID}\twiden\t0123456789abcdef\t判不出\t合成\t2026-10-29\n'
        with self.assertRaises(ValueError): self.build(s)

    def test_markdown_displays_model_status_without_rejudging(self):
        s = sources(); fps(s, speed='红')
        model = self.build(s, (FPS_PATH,))
        text = m.render_model(model)
        self.assertIn('不支持：验证失败：逻辑速度变快', text)   # 逻辑速度红 = 强信号：不支持、关
        self.assertNotIn('已开已验', text)
        self.assertNotIn('synthetic-off;synthetic-on', text)

    def synthetic_git_loader(self, symlink=False):
        # 仓外全新仓库全部由本测试原创，故意用非UTF8帧率载荷证明loader不读表。
        with tempfile.TemporaryDirectory(prefix='s2arm-card-synthetic-') as tmp:
            repo = Path(tmp)
            def git(*args):
                if args and args[0] == 'add': split_tables(repo)   # 登记表按款拆目录（10-30）
                return subprocess.check_output(['git', '-C', str(repo), '-c', 'core.hooksPath=/dev/null', *args],
                                               stderr=subprocess.DEVNULL, text=True).strip()
            git('init'); git('config', 'user.name', 'Synthetic Test'); git('config', 'user.email', 'synthetic@example.invalid')
            for path, content in sources().items():
                dst = repo / path; dst.parent.mkdir(parents=True, exist_ok=True); dst.write_text(content, encoding='utf-8')
            dst = repo / FPS_PATH; dst.parent.mkdir(parents=True, exist_ok=True); dst.write_bytes(bytes([255, 254, 0]))
            if symlink:
                (dst.parent / 'fedcba0987654321.tsv').symlink_to('missing-synthetic-target')
            git('add', '.'); git('commit', '-m', 'synthetic metadata fixture')
            revision = git('rev-parse', 'HEAD')
            original = subprocess.check_output
            def guarded(argv, *args, **kwargs):
                self.assertFalse(any(':runtime/fps/' in str(part) for part in argv), argv)
                return original(argv, *args, **kwargs)
            with mock.patch.object(m.subprocess, 'check_output', side_effect=guarded):
                if symlink:
                    # 安全loader拒非普通blob；不把拒绝算成读取或游戏验证。
                    with self.assertRaises(ValueError):
                        m.load(repo, revision)
                    return
                loaded, full = m.load(repo, revision)
            self.assertEqual(full, revision)
            self.assertEqual(set(loaded['__fps_tables__']), {FPS_PATH})

    def test_git_loader_reads_only_fps_tree_metadata(self):
        self.synthetic_git_loader()

    def test_git_loader_rejects_symlink_fps_without_reading(self):
        self.synthetic_git_loader(symlink=True)

    def test_release_fullscreen_cross_platform_does_not_change_verification(self):
        # owner6466444465明确修订：发布策略可用Mac任一档；scope实测仍不跨平台。
        s = sources(); widen(s); aspect(s, platform='Mac', ratio='19.5:9')
        model = m.build_model(s, REV, requested_scopes=(('ios', '4:3'),))
        c = self.card(model, 'ios', '4:3')
        self.assertEqual(c['features']['fullscreen']['verification'], 'unverified')
        self.assertEqual(c['releaseDefaults']['fullscreen']['value'], 1)

    def test_release_fullscreen_any_red_blocks_every_scope(self):
        for platform, ratio in [('iPhone', '4:3'), ('Mac', '19.5:9')]:
            with self.subTest(platform=platform, ratio=ratio):
                s = sources(); widen(s); aspect(s, platform='iPhone', ratio='19.5:9')
                aspect(s, platform=platform, ratio=ratio, verdict='不过')
                model = m.build_model(s, REV, requested_scopes=(('ios', '19.5:9'), ('macos', '4:3')))
                for c in model['cards']:   # 满屏比例不过（宽屏没生效、只是留边）不是强信号：各范围都缺省开，原因写明
                    r = c['releaseDefaults']['fullscreen']
                    self.assertEqual(r['value'], 1)
                    self.assertEqual(r['reason'], '默认开：无强信号；满屏比例有不过登记（宽屏没生效，不是强信号）')

    def test_release_fullscreen_needs_enable_registration(self):
        s = sources(); aspect(s)
        r = self.card(self.build(s), 'macos', '19.5:9')['releaseDefaults']['fullscreen']
        self.assertEqual((r['value'], r['reason']), (1, '默认开：无强信号；未验：缺满屏读数'))   # 没启用登记不再关，也不冒称通过

    def test_release_fullscreen_unverified_only_is_closed(self):
        s = sources(); widen(s); aspect(s, verdict='未验')
        r = self.card(self.build(s), 'macos', '19.5:9')['releaseDefaults']['fullscreen']
        self.assertEqual((r['value'], r['reason']), (1, '默认开：无强信号；未验：缺满屏读数'))

    def test_release_native_capability_two_layers_without_table(self):
        s = sources(); cap(s, ('不需要', '不需要', '未知'))
        model = m.build_model(s, REV, requested_scopes=(('ios', None),))
        r = self.card(model, 'ios')['releaseDefaults']['fps60']
        self.assertEqual(r['value'], 1)
        self.assertEqual(r['reason'], '游戏原生 60 帧')

    def test_release_one_native_layer_is_not_enough(self):
        for layers in [('不需要', '已具备', '未知'), ('部分', '不需要', '未知')]:
            with self.subTest(layers=layers):
                s = sources(); cap(s, layers)
                model = m.build_model(s, REV, requested_scopes=(('ios', None),))
                self.assertNotEqual(self.card(model, 'ios')['releaseDefaults']['fps60']['reason'], '游戏原生 60 帧')   # 单层不需要不算原生

    def test_release_native_capability_exception_requires_no_table(self):
        s = sources(); cap(s, ('不需要', '不需要', '未知'))
        model = m.build_model(s, REV, fps_tables=(FPS_PATH,), requested_scopes=(('ios', None),))
        self.assertNotEqual(self.card(model, 'ios')['releaseDefaults']['fps60']['reason'], '游戏原生 60 帧')   # 有帧率表就不是原生例外

    def test_release_fps_green_is_ios_only(self):
        s = sources(); fps(s)
        model = m.build_model(s, REV, fps_tables=(FPS_PATH,), requested_scopes=(('macos', None),))
        self.assertEqual(self.card(model, 'ios')['releaseDefaults']['fps60']['reason'], '逻辑速度绿（仅 iOS 登记范围）')
        mac = self.card(model, 'macos')['releaseDefaults']['fps60']   # 绿登记只算 iOS：Mac 是缺省开，不借 iOS 的验证
        self.assertEqual((mac['value'], mac['reason']), (1, '默认开：无强信号；未验：缺逻辑速度判定'))

    def test_release_fps_failure_reason_not_overridden(self):
        s = sources(); fps(s, speed='红'); cap(s)
        s[CAP] = s[CAP].replace('未测', '合成能耗超线')
        c = self.card(self.build(s, (FPS_PATH,)), 'ios')
        self.assertEqual(c['features']['fps60']['verification'], 'failed')
        r = c['releaseDefaults']['fps60']
        self.assertEqual(r['value'], 0)
        self.assertEqual(r['reason'], '强信号：逻辑速度红')   # 未达标文案不覆盖实测失败

    def test_release_fps_unverified_reason_uses_registered_failure_only_as_text(self):
        s = sources(); fps(s, speed='未验'); cap(s)
        s[CAP] = s[CAP].replace('未测', '合成能耗超线')
        c = self.card(self.build(s, (FPS_PATH,)), 'ios')
        self.assertEqual(c['features']['fps60']['verification'], 'unverified')
        r = c['releaseDefaults']['fps60']
        self.assertEqual(r['value'], 1)   # 未达标只作文案、不是强信号
        self.assertEqual(r['reason'], '默认开：无强信号；未达标：合成能耗超线')

    def test_release_fps_reason_keeps_readings(self):
        # 启动器直接展示：数字、小数点、括号、比较号要原样保留
        s = sources(); fps(s, speed='未验'); cap(s)
        s[CAP] = s[CAP].replace('未测', '能耗超线：整机 W 中位 4.92(6) > 4.8')
        r = self.card(self.build(s, (FPS_PATH,)), 'ios')['releaseDefaults']['fps60']
        self.assertEqual(r['reason'], '默认开：无强信号；未达标：能耗超线：整机 W 中位 4.92(6) > 4.8')

    def test_release_fps_reason_truncated(self):
        s = sources(); fps(s, speed='未验'); cap(s)
        s[CAP] = s[CAP].replace('未测', '甲' * 100)
        r = self.card(self.build(s, (FPS_PATH,)), 'ios')['releaseDefaults']['fps60']
        self.assertEqual(r['reason'], '默认开：无强信号；未达标：' + '甲' * 79 + '…')

    def test_release_view_one_entry_per_package(self):
        # 同一包多比例多平台：releases 每（程序号, 构建号, 平台）一条，值与该平台各卡一致
        s = sources(); fps(s); cap(s); widen(s)
        aspect(s, 'Mac', '19.5:9'); aspect(s, 'Mac', '4:3'); aspect(s, 'iPhone', '19.5:9')
        model = self.build(s, (FPS_PATH,))
        rel = model['releases']
        self.assertEqual([(e['programId'], e['buildId'], e['targetPlatform']) for e in rel],
                         [(PID, BID, 'ios'), (PID, BID, 'macos')])
        for e in rel:
            for c in model['cards']:
                if c['identity']['targetPlatform'] == e['targetPlatform'] and c['identity']['buildId'] == BID:
                    for key in ('fps60', 'fullscreen'):
                        self.assertEqual(e[key]['value'], c['releaseDefaults'][key]['value'])
        self.assertEqual(rel[0]['fps60']['value'], 1)
        self.assertEqual((rel[1]['fps60']['value'], rel[1]['fps60']['reason']), (1, '默认开：无强信号；未达标：未测'))   # iOS 的绿不借给 Mac（未达标读数照带）
        self.assertEqual({e['fullscreen']['value'] for e in rel}, {1})

    def test_release_view_disagreeing_scopes_close(self):
        def card(v):
            return {'name': 'x', 'identity': {'programId': PID, 'buildId': BID, 'targetPlatform': 'ios'},
                    'releaseDefaults': {'fps60': {'value': v, 'reason': str(v), 'evidenceRefs': []},
                                        'fullscreen': {'value': 0, 'reason': 'r', 'evidenceRefs': []}}}
        rel = m.release_view([card(1), card(0)])
        self.assertEqual(len(rel), 1)
        self.assertEqual((rel[0]['fps60']['value'], rel[0]['fps60']['reason']), (0, '未验：证据冲突'))
        self.assertEqual(rel[0]['fullscreen']['value'], 0)

    def test_release_view_platformless_card_gives_both_platforms_closed(self):
        # 只有能力覆盖登记（平台未记载）的款也要一包一值：两平台都出、缺省开、未达标读数进原因
        s = sources(); cap(s)
        s[CAP] = s[CAP].replace('未测', '合成能耗超线')
        rel = self.build(s)['releases']
        self.assertEqual([e['targetPlatform'] for e in rel], ['ios', 'macos'])
        for e in rel:
            self.assertEqual((e['fps60']['value'], e['fps60']['reason']), (1, '默认开：无强信号；未达标：合成能耗超线'))
            self.assertEqual(e['fullscreen']['value'], 1)

    def test_release_view_skips_unknown_build(self):
        c = {'name': 'x', 'identity': {'programId': PID, 'buildId': None, 'targetPlatform': None},
             'releaseDefaults': {'fps60': {'value': 1, 'reason': 'r', 'evidenceRefs': []},
                                 'fullscreen': {'value': 1, 'reason': 'r', 'evidenceRefs': []}}}
        self.assertEqual(m.release_view([c]), [])

    def test_release_empty_or_dash_failure_reason_is_not_copied(self):
        for reason in ('', '—'):
            with self.subTest(reason=reason):
                s = sources(); fps(s, speed='未验'); cap(s)
                s[CAP] = s[CAP].replace('未测', reason)
                c = self.card(self.build(s, (FPS_PATH,)), 'ios')
                self.assertEqual(c['releaseDefaults']['fps60']['reason'], '默认开：无强信号；未验：缺逻辑速度判定')

    def test_release_only_two_keys_and_valid_evidence_references(self):
        s = sources(); fps(s); cap(s); widen(s); aspect(s)
        for c in self.build(s, (FPS_PATH,))['cards']:
            self.assertEqual(set(c['releaseDefaults']), {'fps60', 'fullscreen'})
            evidence = {e['id'] for e in c['evidence']}
            for r in c['releaseDefaults'].values():
                self.assertIn(r['value'], (0, 1))
                self.assertIsInstance(r['reason'], str)
                self.assertIsInstance(r['evidenceRefs'], list)
                for ref in r['evidenceRefs']:
                    self.assertIn(ref, evidence)

    def test_text_evidence_unknown_build_does_not_inherit_card_build(self):
        s = sources(); cap(s)
        s[CENSUS] += f'| synthetic | {PID} | 仅程序号来源 |\n'
        s[LDN] += f'{PID} 仅程序号联机文本\n'
        c = self.card(self.build(s), None)
        self.assertEqual(c['identity']['buildId'], BID)
        text_evidence = [e for e in c['evidence'] if e['locator']['path'] in (CENSUS, LDN)]
        self.assertEqual({e['locator']['path'] for e in text_evidence}, {CENSUS, LDN})
        for e in text_evidence:
            self.assertIsNone(e['scope']['buildId'])

    def test_duplicate_tid_on_one_ldn_line_keeps_evidence_id_unique(self):
        s = sources(); cap(s)
        s[LDN] += f'{PID} 与 {PID} 是同一原创标识\n'
        c = self.card(self.build(s), None)
        ids = [e['id'] for e in c['evidence']]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(sum(e['locator']['path'] == LDN for e in c['evidence']), 1)

    def test_sensitive_capability_annotation_not_serialized(self):
        for secret in ('/Users/private-synthetic/secret', 'token=synthetic-secret'):
            with self.subTest(secret=secret):
                s = sources(); cap(s, ('已具备', '部分', '缺（' + secret + '）'))
                model = self.build(s)
                self.assertNotIn(secret, json.dumps(model, ensure_ascii=False))
                c = self.card(model, None)
                self.assertTrue(any(e['locator']['path'] == CAP for e in c['evidence']))
                self.assertEqual(c['fpsLayers']['L3时间步'][0]['status'], '缺')
                self.assertEqual(c['releaseDefaults']['fps60']['value'], 1)
                self.assertNotIn('未达标：' + secret, c['releaseDefaults']['fps60']['reason'])

    def test_sensitive_failure_reason_not_serialized(self):
        for secret in ('/Users/private-synthetic/secret', 'token=synthetic-secret'):
            with self.subTest(secret=secret):
                s = sources(); cap(s); fps(s, speed='未验')
                s[CAP] = s[CAP].replace('未测', secret)
                model = self.build(s)
                self.assertNotIn(secret, json.dumps(model, ensure_ascii=False))
                c = self.card(model, 'ios')
                self.assertEqual(c['releaseDefaults']['fps60']['value'], 1)
                self.assertIn('来源', c['releaseDefaults']['fps60']['reason'])
                self.assertTrue(any(e['locator']['path'] == CAP for e in c['evidence']))

    def test_native_capability_contradicts_logic_red_release_closed(self):
        # 名单线 6467095707：实测红优先于能力规则推断，不是两条实测冲突。
        s = sources(); cap(s, ('不需要', '不需要', '未知')); fps(s, speed='红')
        c = self.card(self.build(s), 'ios')
        self.assertEqual(c['features']['fps60']['verification'], 'failed')
        self.assertEqual(c['releaseDefaults']['fps60']['value'], 0)
        self.assertEqual(c['releaseDefaults']['fps60']['reason'], '强信号：逻辑速度红')
        self.assertEqual(c['features']['fps60']['support'], 'unsupported')

    def test_unknown_build_does_not_prove_fps_disabled(self):
        s = sources(); s[LDN] += f'{PID} 原创无构建号文本\n'
        model = self.build(s)
        cards = [c for c in model['cards'] if c['identity']['programId'] == PID]
        self.assertEqual(len(cards), 1)
        c = cards[0]
        self.assertIsNone(c['identity']['buildId'])
        self.assertEqual(c['features']['fps60']['enabled'], 'unknown')
        self.assertEqual(c['features']['fps60']['display'], '未验：缺启用记录')

    def test_requested_scopes_generator_is_not_consumed_before_projection(self):
        s = sources(); cap(s)
        scopes = (('ios', '4:3'), ('macos', '19.5:9'))
        expected = m.build_model(s, REV, requested_scopes=scopes)
        actual = m.build_model(s, REV, requested_scopes=(scope for scope in scopes))
        self.assertEqual(actual, expected)
        self.card(actual, 'ios', '4:3')
        self.card(actual, 'macos', '19.5:9')

    def test_cli_json_markdown_same_model_and_fixed_commit(self):
        with tempfile.TemporaryDirectory(prefix='s2arm-card-cli-synthetic-') as tmp:
            repo = Path(tmp)
            def git(*args):
                if args and args[0] == 'add': split_tables(repo)   # 登记表按款拆目录（10-30）
                return subprocess.check_output(['git', '-C', str(repo), '-c', 'core.hooksPath=/dev/null', *args],
                                               stderr=subprocess.DEVNULL, text=True).strip()
            git('init'); git('config', 'user.name', 'Synthetic Test'); git('config', 'user.email', 'synthetic@example.invalid')
            s = sources(); fps(s, speed='红'); cap(s); widen(s); aspect(s)
            player_sources = {
                m.TITLES: PID + '\tsynthetic\n',
                m.NAMES: 'synthetic\t原创合成游戏\n',
                m.WORDING: ('键\t匹配\t玩家文案\n'
                    '无平台登记\t无平台登记\t这个平台还没测试\n'
                    '证据冲突\t未验：证据冲突\t测试结果不一致\n'
                    '速度异常\t验证失败：逻辑速度变快\t游戏运行过快\n'
                    '强信号\t强信号：\t检测到不兼容\n'
                    '不支持\t不支持：\t这个构建不兼容\n'
                    '默认开\t默认开：无强信号\t已默认开启\n'
                    '未完成\t未达标：未测\t尚未完成测试\n'
                    '满屏发布\t已有满屏通过登记且无失败登记\t已开启满屏\n'
                    '未开启\t未开启\t尚未开启\n'
                    '未知\t未验：缺启用记录\t尚未测试\n'
                    '已开未验\t已开未验\t已开启，尚未测试\n'
                    '已开失败\t已开；验证失败\t已开启，但测试未通过\n'
                    '已开已验\t已开已验\t已开启并测试过\n'),
                m.ACCEPTANCE: ('程序号\t构建号\t款\t平台\t机型\t包提交\t包哈希\t包身份\t进局\t崩溃报红\t帧率\t能耗\t首局卡顿\t画面\t能力比对\t逻辑速度\t存档往返\t外设\t玩家路径\t能玩\tjhz看过\t日期\t依据\n'),
            }
            s.update(player_sources)
            for path, content in s.items():
                dst = repo / path; dst.parent.mkdir(parents=True, exist_ok=True); dst.write_text(content, encoding='utf-8')
            dst = repo / FPS_PATH; dst.parent.mkdir(parents=True, exist_ok=True); dst.write_bytes(bytes([255, 254, 0]))
            git('add', '.'); git('commit', '-m', 'synthetic CLI evidence')
            revision = git('rev-parse', 'HEAD')
            def run(format_name, output):
                args = [sys.executable, str(ROOT / 'tools/compatibility_report.py'), '--repo', str(repo),
                        '--revision', revision, '--output', str(output)]
                if format_name is not None:
                    args += ['--format', format_name]
                result = subprocess.run(args, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                return output.read_bytes()
            json_bytes = run('json', repo / 'card.json')
            markdown_bytes = run(None, repo / 'card.md')
            parsed = json.loads(json_bytes)
            loaded, full = m.load(repo, revision)
            base_model = m.build_model(loaded, full)
            self.assertEqual({k: v for k, v in parsed.items() if k != 'player'}, base_model)
            self.assertEqual(parsed['player'], m.player_model(base_model, player_sources)['player'])
            self.assertEqual(markdown_bytes, m.render_model(parsed).encode('utf-8'))
            self.assertEqual(parsed['sourceRevision'], revision)
            # 工作树伪造源表/新增表都不能影响固定提交；不使用本地资源真值。
            (repo / FPS).write_text('NOT A SOURCE TABLE\n', encoding='utf-8')
            (repo / FPS_PATH).unlink()
            (repo / 'runtime/fps/fedcba0987654321.tsv').write_text('synthetic dirty file\n', encoding='utf-8')
            self.assertEqual(run('json', repo / 'card-dirty.json'), json_bytes)
            self.assertEqual(run(None, repo / 'card-dirty.md'), markdown_bytes)


if __name__ == '__main__':
    unittest.main(verbosity=2)
