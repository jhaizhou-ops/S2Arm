import json
import importlib.util
import pathlib
import tempfile
import unittest
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('compatibility_report', ROOT / 'tools/compatibility_report.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
TID = '0100000000000000'
BID = 'a' * 32
REV = 'b' * 40

def sources():
    return {m.FPS: '程序号\t构建号\t款\t日期\t帧率\t整机W\t满屏\t包\t依据局\t能力来源\t备注\t逻辑速度\t逻辑速度局\n',
            m.CAP: '程序号\t构建号\t款\tL1交换间隔\tL1依据\tL2引擎限帧\tL2依据\tL3时间步\tL3依据\t未达标原因\n',
            m.ASPECT: '程序号\t构建号\t款\t档位\t平台\t结论\t日期\t读数\t依据\n',
            m.VERIFIED: '# 程序号\t构建号\t款\t平台\t登记日期\t依据\n',
            m.CENSUS: '# 静态普查\n', m.LDN: '# 联机\n', m.STRONG: '程序号\t构建号\t能力\t内容哈希\t信号\t依据\t日期\n',
            m.DIRECT: '程序号\t构建号\t款\t平台\t直连能跑\t进局\t依据\t日期\n'}

def cap(s, bid=BID):
    s[m.CAP] += f'{TID}\t{bid}\tgame\t已具备\tstatic\t不需要\tstatic\t未知\tstatic\t未测\n'

def fps(s, bid=BID):
    s[m.FPS] += f'{TID}\t{bid}\tgame\t2026-10-27\t60/60\t3/3\t100/100\tabc\tprivate@test.invalid\t规则\t/Users/private SECRET\t未验\t/private/secret/off / on\n'


def split_tables(root):
    """登记表按款拆目录（10-30，tools/reglist.py）：夹具按旧单文件写，git add 前拆成 docs/<表名>/<程序号>.tsv（同表重写 = 整表替换）"""
    import contextlib, io, shutil
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / 'tools')); import reglist
    for n in reglist.TABLES:
        if (pathlib.Path(root) / 'docs' / f'{n}.tsv').exists(): shutil.rmtree(pathlib.Path(root) / 'docs' / n, ignore_errors=True)
    with contextlib.redirect_stdout(io.StringIO()): reglist.migrate(str(root))

class ReportTest(unittest.TestCase):
    def test_capability_not_pass(self):
        s=sources();cap(s);out=m.render(s,REV)
        self.assertIn('未验',out);self.assertNotIn('60帧达标登记',out)
    def test_registered_fps(self):
        s=sources();fps(s);out=m.render(s,REV)
        self.assertNotIn('60帧达标登记',out);self.assertIn('未验：缺逻辑速度判定',out);self.assertIn('机型未记载',out)
        self.assertNotIn('SECRET',out);self.assertNotIn('private@',out)
    def test_capability_enums_preserved(self):
        for status in ('已具备','部分','缺','不需要','未知','缺（据 R7，未实测）'):
            with self.subTest(status=status):
                s=sources();cap(s);s[m.CAP]=s[m.CAP].replace('已具备',status)
                out=m.render(s,REV)
                expected='未验：能力状态未知' if status=='未知' else status.split('（',1)[0]
                self.assertIn('L1交换间隔：'+expected,out)
                self.assertIn('来源文字（非实测）',out)
                self.assertNotIn('60帧达标登记',out)
    def test_bad_capability_enum_rejected(self):
        s=sources();cap(s);s[m.CAP]=s[m.CAP].replace('已具备','随便通过')
        with self.assertRaises(ValueError):m.render(s,REV)
    def test_unverified_reason_is_explicit(self):
        s=sources();cap(s);out=m.render(s,REV)
        for reason in ('无真机局','缺该比例满屏读数','无实机联机局','能力状态未知'):
            self.assertIn('未验：'+reason,out)
        for cell in out.split('|'):
            self.assertNotEqual(cell.strip(),'未验')
    def test_old_header_rejected(self):
        s=sources();s[m.FPS]=s[m.FPS].replace('\t逻辑速度\t逻辑速度局','')
        with self.assertRaises(ValueError):m.render(s,REV)
    def test_speed_contract(self):
        expected={'绿':'60帧达标登记','红':'验证失败：逻辑速度变快',
                  '判不出':'未验：逻辑速度判不出','未验':'未验：缺逻辑速度判定'}
        for status,message in expected.items():
            with self.subTest(status=status):
                s=sources();fps(s);s[m.FPS]=s[m.FPS].replace('\t未验\t','\t'+status+'\t')
                out=m.render(s,REV)
                self.assertIn(message,out)
                if status=='绿':
                    self.assertIn('60 / 60 帧',out);self.assertIn('2026-10-27',out);self.assertIn('逻辑速度绿',out)
                else:self.assertNotIn('60帧达标登记',out)
                self.assertNotIn('/private/secret',out)
    def test_speed_missing_evidence(self):
        s=sources();fps(s);s[m.FPS]=s[m.FPS].replace('未验\t/private/secret/off / on','绿\t')
        self.assertIn('未验：缺逻辑速度判定',m.render(s,REV))
    def test_speed_unknown_rejected(self):
        for value in ('通过','','绿 ','unknown'):
            with self.subTest(value=value):
                s=sources();fps(s);s[m.FPS]=s[m.FPS].replace('\t未验\t','\t'+value+'\t')
                with self.assertRaises(ValueError):m.render(s,REV)
    def test_speed_conflict_not_optimistic(self):
        s=sources();fps(s);lines=s[m.FPS].splitlines()
        s[m.FPS]=lines[0]+'\n'+lines[1].replace('\t未验\t','\t绿\t')+'\n'+lines[1].replace('\t未验\t','\t红\t')+'\n'
        out=m.render(s,REV)
        self.assertIn('未验：证据冲突',out)
        self.assertNotIn('60帧达标登记',out)
    def test_fps_numbers_must_meet_contract(self):
        for old,new in [('60/60','30/30'),('3/3','5/3'),('100/100','98/100'),('60/60','60'),('3/3','unknown')]:
            with self.subTest(value=new):
                s=sources();fps(s);s[m.FPS]=s[m.FPS].replace(old,new)
                with self.assertRaises(ValueError):m.render(s,REV)
    def test_annotated_registered_numbers(self):
        s=sources();fps(s);s[m.FPS]=s[m.FPS].replace('3/3','3.44（充电中·nominal）/ 3.59（未充电·fair）').replace('100/100','100% / 100%')
        self.assertIn('未验：缺逻辑速度判定',m.render(s,REV))
    def test_build_separation(self):
        s=sources();cap(s);fps(s,'c'*32);out=m.render(s,REV)
        rows=[l for l in out.splitlines() if l.startswith('| game')]
        self.assertEqual(len(rows),2);self.assertEqual(sum('60 / 60 帧' in l for l in rows),1)
    def test_aspect_boundaries(self):
        s=sources();s[m.ASPECT]+=f'{TID}\t{BID}\tgame\t4:3\tMac\t不过\t2026-10-27\tx\ty\n'
        s[m.ASPECT]+=f'{TID}\t{BID}\tgame\t19.5:9\tiPhone\t未验\t2026-10-27\tx\ty\n'
        out=m.render(s,REV);self.assertIn('Mac / 4:3：不过',out);self.assertIn('iPhone / 19.5:9：未验',out)
    def test_verified_not_universal(self):
        s=sources();s[m.VERIFIED]+=f'{TID}\t{BID}\tgame\tapple\t2026-10-27\tprivate\n'
        out=m.render(s,REV);self.assertIn('宽屏启用登记',out);self.assertIn('未验：缺逐比例验证',out)
    def test_static_not_runtime(self):
        s=sources();s[m.CENSUS]+=f'| game | {TID} | **可行** |\n'
        out=m.render(s,REV);self.assertIn('静态普查',out);self.assertNotIn('到 MARK',out)
    def test_ldn_not_gameplay(self):
        s=sources();s[m.LDN]+=f'样本：游戏（{TID}）。单测 8 项过；双机未测。\n'
        out=m.render(s,REV);self.assertIn(TID,out);self.assertIn('未验：无实机联机局',out)
    def test_deterministic(self):
        s=sources();fps(s);cap(s)
        self.assertEqual(m.render(s,REV),m.render(dict(reversed(list(s.items()))),REV))
    def test_source_pinned(self):
        s=sources();fps(s);out=m.render(s,REV)
        self.assertIn('/blob/'+REV+'/',out);self.assertIn('#L2',out)
    def test_missing_source(self):
        s=sources();del s[m.CAP]
        with self.assertRaises(ValueError):m.render(s,REV)
    def test_bad_schema(self):
        s=sources();s[m.FPS]='wrong\theader\n'
        with self.assertRaises(ValueError):m.render(s,REV)
    def test_bad_id(self):
        s=sources();fps(s);s[m.FPS]=s[m.FPS].replace(TID,'bad')
        with self.assertRaises(ValueError):m.render(s,REV)
    def test_bad_date(self):
        s=sources();fps(s);s[m.FPS]=s[m.FPS].replace('2026-10-27','2026-02-30')
        with self.assertRaises(ValueError):m.render(s,REV)
    def test_unknown_status(self):
        s=sources();s[m.ASPECT]+=f'{TID}\t{BID}\tgame\t4:3\tMac\t当然过\t2026-10-27\tx\ty\n'
        with self.assertRaises(ValueError):m.render(s,REV)
    def test_markdown_and_privacy(self):
        s=sources();fps(s);s[m.FPS]=s[m.FPS].replace('\tgame\t','\t<script>private@example.com|evil\t')
        out=m.render(s,REV);self.assertNotIn('<script>',out);self.assertNotIn('private@',out);self.assertNotIn('|evil',out)
    def test_conflicting_rows_retained(self):
        s=sources()
        for status in ['过','不过']:s[m.ASPECT]+=f'{TID}\t{BID}\tgame\t4:3\tMac\t{status}\t2026-10-27\tx\ty\n'
        out=m.render(s,REV);self.assertIn('Mac / 4:3：过',out);self.assertIn('Mac / 4:3：不过',out);self.assertIn('不合并结论',out)

class CliTest(unittest.TestCase):
    def git(self, root, *args):
        if args and args[0] == 'add': split_tables(root)
        return subprocess.check_output(['git','-C',str(root),*args],stderr=subprocess.DEVNULL,text=True).strip()
    def fixture(self, root):
        self.git(root,'init','-q');self.git(root,'config','user.name','Synthetic');self.git(root,'config','user.email','synthetic@example.invalid')
        for path,text in sources().items():
            p=root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)
        self.git(root,'add','.');self.git(root,'commit','-qm','fixture')
        return self.git(root,'rev-parse','HEAD')
    def test_exact_commit_not_worktree(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);rev=self.fixture(root)
            (root/m.FPS).write_text('not the committed table')
            data,actual=m.load(root,rev)
            self.assertEqual(actual,rev);self.assertEqual(data[m.FPS],sources()[m.FPS])
    def test_symlink_input_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);self.fixture(root)
            p=root/'docs/名单_60帧/_表头.tsv';p.unlink();p.symlink_to('/never-read-private')   # 按款登记目录里的文件换成链接（10-30）
            self.git(root,'add','.');self.git(root,'commit','-qm','synthetic link')
            with self.assertRaises(ValueError):m.load(root,'HEAD')
    def test_cli_failure_preserves_output(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);self.fixture(root)
            import shutil; shutil.rmtree(root/'docs/名单_60帧能力覆盖');self.git(root,'add','-u');self.git(root,'commit','-qm','missing synthetic input')   # 整个按款登记目录缺失（10-30）
            out=root/'result.md';out.write_text('keep')
            proc=subprocess.run([sys.executable,str(ROOT/'tools/compatibility_report.py'),'--repo',str(root),'--revision','HEAD','--output',str(out)],capture_output=True,text=True)
            self.assertEqual(proc.returncode,1);self.assertEqual(out.read_text(),'keep')


class PlayerTest(unittest.TestCase):
    def inputs(self):
        return {m.TITLES: TID+'\tgame\n'+'FFFFFFFFFFFFFFFF\tother\n',
                m.NAMES: 'game\t示例游戏\n', m.WORDING: '键\t匹配\t玩家文案\n无平台登记\t无平台登记\t尚未测试这个平台\n证据冲突\t未验：证据冲突\t测试结果不一致\n默认\t未验：缺启用记录\t尚未测试\n速度\t未验：缺逻辑速度判定\t尚未确认运行速度\n宽屏\t未验：缺满屏启用登记\t尚未开启满屏\n关闭\t未开启\t尚未开启\n已开未验\t已开未验\t已开启未测试\n默认开启\t默认开：无强信号\t已默认开启\n强信号关闭\t强信号：\t检测到不兼容，暂不启用\n不支持\t不支持：\t这个构建不兼容此功能\n',
                m.ACCEPTANCE: '\t'.join(m.ACCEPTANCE_HEADER)+'\n'}
    def model(self):
        s=sources();cap(s);s[m.CAP]=s[m.CAP].replace('未测\n','\n')
        return m.build_model(s,REV)
    def test_player_order_and_empty_acceptance(self):
        result=m.player_model(self.model(),self.inputs())
        self.assertEqual([r['name'] for r in result['player']],['示例游戏','other'])
        self.assertEqual([r['programId'] for r in result['player']],[TID,'FFFFFFFFFFFFFFFF'])
        for row in result['player']:
            for build in row['builds']:
                self.assertEqual(build['playable'],{'ios':'还没验收','macos':'还没验收'})
        segment=m.render_model(result).split('## 附录：证据索引')[0]
        for word in ('内容见来源列','逻辑速度','登记','证据','MARK'):self.assertNotIn(word,segment)
    def test_missing_platform_and_multibuild(self):
        model=self.model(); first=model['releases'][0]
        model['releases']=[dict(first,targetPlatform='ios'),dict(first,buildId='b'*32,targetPlatform='ios')]
        row=m.player_model(model,self.inputs())['player'][0]
        self.assertEqual(len(row['builds']),2)
        self.assertEqual([b['buildId'] for b in row['builds']],[BID,'b'*32])
        for b in row['builds']:self.assertEqual(b['fps60']['macos'],'关（尚未测试这个平台）')
        rendered=m.render_model(m.player_model(model,self.inputs())).split('## 附录')[0]
        self.assertIn(BID[:8]+'：',rendered);self.assertIn('bbbbbbbb：',rendered)
    def test_copy_must_match_exactly_once(self):
        for suffix in ('', '重复\t默认开\t重复文案\n'):   # 全能力出包后发布原因是「默认开：无强信号…」：缺文案 / 文案歧义都要点名这条
            data=self.inputs()
            if suffix:data[m.WORDING]+=suffix
            else:data[m.WORDING]=data[m.WORDING].replace('默认开启\t默认开：无强信号\t已默认开启\n','')
            with self.assertRaisesRegex(ValueError,'默认开：无强信号'):m.player_model(self.model(),data)
    def acceptance(self,date='2026-10-27',state='过'):
        return dict(zip(m.ACCEPTANCE_HEADER,[TID,BID,'game','ios','合成设备','123456789abcdef','hash']+['过']*12+[state,'2026-10-27',date,'synthetic']))
    def append_row(self,data,row):data[m.ACCEPTANCE]+='\t'.join(row[h] for h in m.ACCEPTANCE_HEADER)+'\n'
    def test_acceptance_latest(self):
        data=self.inputs();self.append_row(data,self.acceptance());self.append_row(data,self.acceptance('2026-10-28','不过'))
        build=m.player_model(self.model(),data)['player'][0]['builds'][0]
        self.assertEqual(build['playable']['ios'],'不能玩');self.assertEqual(build['verification']['ios'],'2026-10-28 / 123456789')
    def test_acceptance_dated_order_and_same_day_are_symmetric(self):
        for older, newer in (('过', '不过'), ('不过', '过')):
            for reverse in (False, True):
                with self.subTest(older=older, reverse=reverse):
                    data=self.inputs()
                    rows=[self.acceptance('2026-10-01',older),self.acceptance('2026-10-02',newer)]
                    for row in rows[::-1] if reverse else rows:self.append_row(data,row)
                    actual=m.acceptance_rows(data[m.ACCEPTANCE])[(TID,BID,'ios')]
                    self.assertEqual(actual['能玩'],newer)
            data=self.inputs()
            for state in (older,newer):self.append_row(data,self.acceptance('2026-10-01',state))
            self.assertEqual(m.acceptance_rows(data[m.ACCEPTANCE])[(TID,BID,'ios')]['能玩'],older)
    def test_every_acceptance_row_requires_date(self):
        for state in ('过','不过','未验'):
            for platform in ('ios','macos'):
                with self.subTest(state=state,platform=platform):
                    data=self.inputs();self.append_row(data,self.acceptance())
                    row=self.acceptance('',state);row['平台']=platform
                    row['程序号']='FFFFFFFFFFFFFFFF'  # Even rows outside this model must validate.
                    if state!='过':row['jhz看过']=''
                    self.append_row(data,row)
                    with self.assertRaisesRegex(ValueError,'日期.*必填'):
                        m.player_model(self.model(),data)
    def test_acceptance_rejects_invalid(self):
        for field,value in [('进局','不过'),('进局','随意'),('jhz看过',''),('日期','2026-02-30'),('平台','linux'),('能玩','是')]:
            with self.subTest(field=field,value=value):
                data=self.inputs();row=self.acceptance();row[field]=value;self.append_row(data,row)
                with self.assertRaises(ValueError):m.player_model(self.model(),data)
        data=self.inputs();data[m.ACCEPTANCE]=data[m.ACCEPTANCE].replace('\t依据','')
        with self.assertRaises(ValueError):m.player_model(self.model(),data)
    def test_all_rendered_off_reasons_are_exact_player_copy(self):
        import re
        data=self.inputs();src=sources();cap(src);src[m.CAP]=src[m.CAP].replace('未测\n','\n')
        # 全能力出包后缺省开：两键各登记一条强信号造出关的格子（强信号原因也必须是玩家文案）
        src[m.STRONG]+=f'{TID}\t{BID}\tfps60\t0123456789abcdef\t崩溃归因\tsynthetic\t2026-10-29\n{TID}\t{BID}\twiden\t0123456789abcdef\t宽屏画面坏\tsynthetic\t2026-10-29\n'
        model=m.build_model(src,REV);first=model['releases'][0]
        # Exercise every off cell, mixed platforms, absent-platform and multi-build rows.
        model['releases'].append(dict(first,buildId='b'*32,targetPlatform='ios'))
        result=m.player_model(model,data)
        section=m.render_model(result).split('## 附录：证据索引')[0]
        rows=[line.split('|')[1:-1] for line in section.splitlines() if line.startswith('| ')][1:]
        allowed={line.split('\t')[2] for line in data[m.WORDING].splitlines()[1:]}
        count=0
        for row in rows:
            for cell in row[2:4]:
                reasons=re.findall(r'关（([^）]*)）',cell)
                self.assertEqual(cell.count('关'),len(reasons),cell)
                for reason in reasons:
                    count+=1;self.assertTrue(reason,cell);self.assertIn(reason,allowed)
        self.assertGreaterEqual(count,6)
    def test_compact_layout_same_and_different_values(self):
        result=m.player_model(self.model(),self.inputs())
        row=result['player'][0];b=row['builds'][0]
        b['playable']={'ios':'能玩','macos':'能玩'}
        b['fps60']={'ios':'开','macos':'关（尚未测试这个平台）'}
        b['fullscreen']={'ios':'关（尚未开启满屏）','macos':'关（尚未开启满屏）'}
        b['features'].update(controller='相同文案',rumble='相同文案',gyro='相同文案')
        section=m.render_model(result).split('## 附录：证据索引')[0]
        lines=[line for line in section.splitlines() if line.startswith('| ')]
        self.assertNotIn(' | 说明 | ',lines[0]);self.assertEqual(len(lines[0].split('|')[1:-1]),8)
        cells=[c.strip() for c in lines[1].split('|')[1:-1]]
        self.assertEqual(cells[1],'能玩')
        self.assertEqual(cells[2],'iPhone 开 / Mac 关（尚未测试这个平台）')
        self.assertEqual(cells[3],'关（尚未开启满屏）')
        self.assertEqual(cells[5],'相同文案')
        b['features']['gyro']='不同文案'
        self.assertIn('相同文案 / 相同文案 / 不同文案',m.render_model(result))
    def test_feature_conflict_not_optimistic(self):
        model=self.model();import copy
        duplicate=copy.deepcopy(model['cards'][0]);duplicate['features']['direct']['display']='未验：证据冲突';model['cards'].append(duplicate)
        row=m.player_model(model,self.inputs())['player'][0]
        self.assertEqual(row['builds'][0]['features']['direct'],'测试结果不一致')


class PlayerCliTest(unittest.TestCase):
    git = CliTest.git
    fixture = CliTest.fixture
    def prepared(self, root):
        self.fixture(root)
        data=PlayerTest().inputs()
        for path,text in data.items():
            p=root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)
        self.git(root,'add','.');self.git(root,'commit','-qm','player sources')
        return self.git(root,'rev-parse','HEAD')
    def cli(self,root,*extra):
        return subprocess.run([sys.executable,str(ROOT/'tools/compatibility_report.py'),'--repo',str(root),'--revision','HEAD','--output',str(root/'result.md'),*extra],capture_output=True,text=True)
    def test_cli_rejects_undated_acceptance_symmetric_cases(self):
        cases=[ [('2026-10-01','不过'),('','过')],
                [('','过'),('2026-01-01','不过')],
                [('2026-10-01','过'),('','不过')], [('', '过')],
                [('', '未验')] ]
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);self.prepared(root)
            for rows in cases:
                with self.subTest(rows=rows):
                    data=PlayerTest().inputs()
                    for date,state in rows:PlayerTest().append_row(data,PlayerTest().acceptance(date,state))
                    (root/m.ACCEPTANCE).write_text(data[m.ACCEPTANCE])
                    self.git(root,'add',m.ACCEPTANCE);self.git(root,'commit','-qm','synthetic acceptance')
                    output=root/'result.md';output.write_text('keep')
                    proc=self.cli(root)
                    self.assertEqual(proc.returncode,1,proc.stderr)
                    self.assertIn('日期',proc.stderr);self.assertIn('必填',proc.stderr)
                    self.assertEqual(output.read_text(),'keep')
    def test_cli_system_errors_hide_paths_and_git_stderr(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);self.prepared(root)
            cases=[(['--revision','NOT_A_REAL_COMMIT'],'CalledProcessError'),
                   (['--output',str(root/'missing-parent'/'output.md')],'FileNotFoundError'),
                   (['--check',str(root/'missing-check.md')],'FileNotFoundError'),
                   (['--repo',str(root/'missing-repo')],'CalledProcessError')]
            for args,kind in cases:
                with self.subTest(args=args):
                    proc=self.cli(root,*args)
                    self.assertEqual(proc.returncode,1)
                    self.assertEqual(proc.stderr,'兼容表生成失败（'+kind+'）：无法读取来源或写出结果，请检查输入与输出。\n')
                    for value in (str(root),str(root/'result.md'),args[-1]):self.assertNotIn(value,proc.stderr)
            # A decoding failure is a ValueError subclass, but must use the safe branch.
            (root/m.WORDING).write_bytes(b'\xff')
            self.git(root,'add',m.WORDING);self.git(root,'commit','-qm','synthetic invalid utf8')
            proc=self.cli(root);self.assertEqual(proc.returncode,1)
            self.assertEqual(proc.stderr,'兼容表生成失败（UnicodeDecodeError）：无法读取来源或写出结果，请检查输入与输出。\n')
    def test_cli_ambiguous_copy_retains_reason(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);self.prepared(root)
            data=sources();cap(data);data[m.CAP]=data[m.CAP].replace('未测\n','\n')
            (root/m.CAP).write_text(data[m.CAP])
            p=root/m.WORDING;p.write_text(p.read_text()+'重复\t默认开\t重复文案\n')
            self.git(root,'add','.');self.git(root,'commit','-qm','synthetic ambiguous copy')
            proc=self.cli(root);self.assertEqual(proc.returncode,1)
            self.assertIn('实际 2',proc.stderr);self.assertIn('默认开：无强信号',proc.stderr)
    def test_reproducible_source_commit_and_check(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);revision=self.prepared(root)
            first=self.cli(root);self.assertEqual(first.returncode,0,first.stderr)
            text=(root/'result.md').read_text();self.assertIn('源表最后改动提交：'+revision,text)
            reference=root/'reference.md';reference.write_text(text)
            (root/'unrelated.txt').write_text('synthetic unrelated commit')
            self.git(root,'add','unrelated.txt');self.git(root,'commit','-qm','unrelated')
            unchanged=self.cli(root,'--check',str(reference));self.assertEqual(unchanged.returncode,0,unchanged.stderr)
            self.assertEqual((root/'result.md').read_text(),text)
            # Local source edits must never leak into fixed-revision output.
            (root/m.TITLES).write_text('invalid uncommitted content')
            self.assertEqual(self.cli(root,'--check',str(reference)).returncode,0)
            reference.write_text(text.replace('# 兼容性清单','# 修改清单',1))
            mismatch=self.cli(root,'--check',str(reference));self.assertEqual(mismatch.returncode,1)
            self.assertIn('第一处差异行 1',mismatch.stderr)
            reference.write_bytes(text.encode()+b'X')
            self.assertEqual(self.cli(root,'--check',str(reference)).returncode,1)
    def test_json_player_and_unknown_copy_diagnostic(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);self.prepared(root)
            proc=self.cli(root,'--format','json');self.assertEqual(proc.returncode,0,proc.stderr)
            model=json.loads((root/'result.md').read_text());self.assertEqual(model['schema'],'s2a.capability-card.v1')
            self.assertEqual(len(model['player']),2)
            # Build a source capability row so the missing release prefix is observable.
            data=sources();cap(data);data[m.CAP]=data[m.CAP].replace('未测\n','\n')
            (root/m.CAP).write_text(data[m.CAP])
            p=root/m.WORDING;p.write_text(p.read_text().replace('默认开启\t默认开：无强信号\t已默认开启\n',''))
            self.git(root,'add','.');self.git(root,'commit','-qm','unknown copy negative')
            proc=self.cli(root);self.assertEqual(proc.returncode,1);self.assertIn('默认开：无强信号',proc.stderr)


class InputCapsTest(unittest.TestCase):
    path = 'docs/名单_输入能力.tsv'
    header = '程序号\t构建号\t项\t静态\t局内\t依据局\t日期\n'

    def source(self, feature='rumble', static='未知', dynamic='调用', pid=TID, bid=BID):
        data = sources(); cap(data)
        data[self.path] = self.header + f'{pid}\t{bid}\t{feature}\t{static}\t{dynamic}\tprivate/run; other\t2026-11-01\n'
        return data

    def test_input_positive_matrix(self):
        for key, label in [('controller', '手柄'), ('rumble', '震动'), ('gyro', '陀螺仪')]:
            for static, dynamic in [('引用', '未测'), ('引用', '未调用'), ('未知', '调用'), ('未见', '调用')]:
                with self.subTest(key=key, static=static, dynamic=dynamic):
                    model = m.build_model(self.source(key, static, dynamic), REV)
                    feature = model['cards'][0]['features'][key]
                    self.assertEqual(feature['support'], 'supported')
                    self.assertEqual(feature['verification'], 'unverified')
                    self.assertEqual(feature['enabled'], 'unknown')
                    self.assertEqual(feature['evidenceRefs']['verification'], [])
                    self.assertEqual(feature['evidenceRefs']['enabled'], [])
                    self.assertEqual(feature['evidenceRefs']['support'], [self.path + ':2'])
                    self.assertIn('设备体感未验', feature['reason'])
                    self.assertIn(('游戏声明引用' if static == '引用' else '局内调用') + label, feature['reason'])
                    self.assertEqual('证据冲突' in feature['reason'], static == '未见')
                    self.assertIn(feature['reason'], feature['display'])
                    output = m.render_model(model)
                    self.assertIn('设备体感未验', output)
                    self.assertNotIn('private/run', output)
                    self.assertNotIn('N 次', output)
                    m.player_model(model, PlayerTest().inputs())  # Current wording contract still accepts displays.

    def test_absent_static_is_never_unsupported(self):
        for static in ('未见', '未知'):
            for dynamic in ('未测', '未调用'):
                with self.subTest(static=static, dynamic=dynamic):
                    feature = m.build_model(self.source(static=static, dynamic=dynamic), REV)['cards'][0]['features']['rumble']
                    self.assertEqual(feature['support'], 'unknown')
                    self.assertEqual(feature['verification'], 'unverified')
                    self.assertEqual(feature['evidenceRefs']['support'], [])
                    self.assertIn('设备体感未验', feature['reason'])

    def test_strict_enums_and_required_evidence(self):
        row = [TID, BID, 'rumble', '未知', '调用', 'synthetic', '2026-11-01']
        for column, bad in [(2,'touch'), (2,'rumble '), (3,'false'), (3,''), (4,'0'), (4,'调用 '), (5,''), (5,' '), (6,'2026-02-30'), (0,'bad'), (1,'')]:
            with self.subTest(column=column,bad=bad):
                data=self.source(); cells=row.copy();cells[column]=bad
                data[self.path]=self.header+'\t'.join(cells)+'\n'
                with self.assertRaisesRegex(ValueError, self.path+':2:'):
                    m.build_model(data,REV)

    def test_actual_file_line_for_invalid_row_and_evidence(self):
        file = 'docs/名单_输入能力/'+TID+'.tsv'
        data = self.source()
        data['__loc__'] = {self.path: [(None,1),(file,7)]}
        card=m.build_model(data,REV)['cards'][0]
        self.assertEqual(card['features']['rumble']['evidenceRefs']['support'], [file+':7'])
        evidence=next(e for e in card['evidence'] if e['id']==file+':7')
        self.assertEqual(evidence['locator'], {'revision':REV,'path':file,'line':7})
        for replacement in ('touch\t未知\t调用','rumble\t未知\tbad','rumble\t未知'):
            broken=dict(data);broken[self.path]=data[self.path].replace('rumble\t未知\t调用',replacement)
            with self.assertRaisesRegex(ValueError,file+':7:'):
                m.build_model(broken,REV)

    def test_identity_and_other_five_features_are_unchanged(self):
        plain=sources();cap(plain)
        before=m.build_model(plain,REV)
        for pid,bid in [('FFFFFFFFFFFFFFFF',BID),(TID,'c'*32)]:
            data=self.source(pid=pid,bid=bid)
            after=m.build_model(data,REV)
            original=next(c for c in after['cards'] if c['identity']==before['cards'][0]['identity'])
            self.assertEqual(json.dumps(original,sort_keys=True),json.dumps(before['cards'][0],sort_keys=True))
        after=m.build_model(self.source(),REV)
        for key in ('direct','fullscreen','fps60','online','quickMenu'):
            self.assertEqual(after['cards'][0]['features'][key],before['cards'][0]['features'][key])
        self.assertEqual(after['releases'],before['releases'])

    def test_empty_table_preserves_every_byte(self):
        plain=sources();cap(plain);fps(plain)
        empty=dict(plain);empty[self.path]=self.header
        self.assertEqual(json.dumps(m.build_model(plain,REV),ensure_ascii=False,sort_keys=True).encode(),
                         json.dumps(m.build_model(empty,REV),ensure_ascii=False,sort_keys=True).encode())
        self.assertEqual(m.render(plain,REV).encode(),m.render(empty,REV).encode())

    def test_positive_and_conflicting_records_both_retained(self):
        data=self.source(static='未见',dynamic='未测')
        data[self.path]+=f'{TID}\t{BID}\trumble\t未知\t调用\tsecond\t2026-11-01\n'
        card=m.build_model(data,REV)['cards'][0]
        feature=card['features']['rumble']
        self.assertEqual(feature['support'],'supported')
        self.assertIn('证据冲突',feature['reason'])
        self.assertEqual(feature['verification'],'unverified')
        self.assertEqual(feature['evidenceRefs']['support'],[self.path+':3'])
        self.assertEqual(len([e for e in card['evidence'] if e['locator']['path']==self.path]),2)

    def test_empty_schema_commit_does_not_rewrite_cli_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);cli=PlayerCliTest();cli.prepared(root)
            before={}
            for fmt in ('markdown','json'):
                result=cli.cli(root,'--format',fmt);self.assertEqual(result.returncode,0,result.stderr)
                before[fmt]=(root/'result.md').read_bytes()
            p=root/self.path;p.write_text(self.header)
            cli.git(root,'add','.');cli.git(root,'commit','-qm','empty schema only')
            for fmt in ('markdown','json'):
                result=cli.cli(root,'--format',fmt);self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual((root/'result.md').read_bytes(),before[fmt])

    def test_committed_directory_cli_and_bad_row_preserves_output(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);cli=PlayerCliTest();cli.prepared(root)
            # Missing table was accepted by old releases and remains accepted.
            first=cli.cli(root);self.assertEqual(first.returncode,0,first.stderr)
            data=self.source();p=root/self.path;p.write_text(data[self.path])
            cli.git(root,'add','.');cli.git(root,'commit','-qm','synthetic input')
            good=cli.cli(root,'--format','json');self.assertEqual(good.returncode,0,good.stderr)
            model=json.loads((root/'result.md').read_text())
            feature=model['cards'][0]['features']['rumble']
            self.assertEqual(feature['support'],'supported')
            self.assertEqual(feature['verification'],'unverified')
            part=root/'docs/名单_输入能力'/f'{TID}.tsv'
            original=part.read_text()
            for old,new in [('\t调用\t','\tbad\t'), ('2026-11-01','2026-02-30'), (BID,'bad'), ('\t未知\t','\t')]:
                part.write_text(original.replace(old,new))
                cli.git(root,'add','.');cli.git(root,'commit','-qm','synthetic bad row')
                output=root/'result.md';output.write_bytes(b'keep\x00unchanged')
                bad=cli.cli(root);self.assertEqual(bad.returncode,1)
                self.assertIn(f'docs/名单_输入能力/{TID}.tsv:2:',bad.stderr)
                self.assertEqual(output.read_bytes(),b'keep\x00unchanged')

if __name__=='__main__':unittest.main()
