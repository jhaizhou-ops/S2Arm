#!/usr/bin/env python3
"""把正式包改签成实验身份（11-06 总指挥：调度器派的冒烟 / 补位包用了正式身份 io.s2arm.<款>，直接盖掉 jhz 机上的手测包；
交接 §2 定的是「验证包用实验身份 io.s2arm-exp.*，jhz 手测包用 io.s2arm.*」）。
  python3 tools/ipa_exp_id.py <输入 ipa> <输出 ipa> <款> [--team <团队号>]
包名改 io.s2arm-exp.<款>；显示名：Info.plist 的 ASCII 名加「 Exp」、各 <语言>.lproj/InfoPlist.strings 的本地化名加「 实验」。
只剥顶层签名（_CodeSignature / embedded.mobileprovision），内嵌的游戏镜像包等保留各自签名；重签走 pack/dev_sign.py（缺描述文件先 pack/ensure_profile.sh 建），
签后 pack/iml_check.py 核提高内存上限权限，再 pack/app_bundle.py write_ipa 打包。已是 io.s2arm-exp.<款> 的原样拷贝。退出码：0 成功；1 失败（原因打一行【红】）"""
import argparse, glob, os, plistlib, re, shutil, subprocess, sys, tempfile, zipfile
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); P = os.path.join(R, 'pack')
if os.path.isfile(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pack', 'dev_sign.py')):   # 调度冻结副本（sched/auto/tools_<提交>/）：签名件冻在副本自己的 pack/ 下（tools/sched.sh upgrade）
    P = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pack')


def red(msg): print(f'【红】ipa_exp_id：{msg}'); sys.exit(1)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('src'); ap.add_argument('dst'); ap.add_argument('game')
    ap.add_argument('--team', default=os.environ.get('S2A_TEAM') or os.environ.get('S2A_TEAM_DEFAULT', ''))
    a = ap.parse_args(); bid = f'io.s2arm-exp.{a.game}'
    t = tempfile.mkdtemp(prefix='ipa_exp_')
    try:
        with zipfile.ZipFile(a.src) as z: z.extractall(t)
        apps = glob.glob(os.path.join(t, 'Payload', '*.app'))
        if len(apps) != 1: red(f'{a.src} 里 App 不是恰好一个（{len(apps)}）')
        app = apps[0]; ip = os.path.join(app, 'Info.plist')
        info = plistlib.load(open(ip, 'rb'))
        if info.get('CFBundleIdentifier') == bid: shutil.copyfile(a.src, a.dst); print(f'已是实验身份 {bid}，原样拷贝'); return
        if not a.team: red('没有签名团队（S2A_TEAM / tools/machine.local 的 S2A_TEAM_DEFAULT）')
        info['CFBundleIdentifier'] = bid
        dn = info.get('CFBundleDisplayName') or info.get('CFBundleName') or a.game
        if not dn.endswith(' Exp'): info['CFBundleDisplayName'] = dn + ' Exp'
        with open(ip, 'wb') as f: plistlib.dump(info, f, fmt=plistlib.FMT_XML, sort_keys=False)
        for s in glob.glob(os.path.join(app, '*.lproj', 'InfoPlist.strings')):
            txt = open(s, encoding='utf-8').read()
            txt = re.sub(r'("CFBundleDisplayName"\s*=\s*")(.*?)(?<! 实验)(";)', r'\1\2 实验\3', txt)
            open(s, 'w', encoding='utf-8', newline='\n').write(txt)
        for x in ('_CodeSignature', 'embedded.mobileprovision'):
            p = os.path.join(app, x)
            if os.path.isdir(p): shutil.rmtree(p)
            elif os.path.exists(p): os.remove(p)
        ent = os.path.join(P, 'app.entitlements'); log = os.path.join(t, 'sign.log')
        sign = ['/usr/bin/python3', os.path.join(P, 'dev_sign.py'), app, bid, a.team, ent]
        rc = subprocess.run(sign, stdout=open(log, 'w'), stderr=subprocess.STDOUT).returncode
        if rc == 3:
            subprocess.run(['bash', os.path.join(P, 'ensure_profile.sh'), bid, a.team, ent], stdout=open(log, 'a'), stderr=subprocess.STDOUT)
            rc = subprocess.run(sign, stdout=open(log, 'a'), stderr=subprocess.STDOUT).returncode
        if rc: red(f'签名失败 rc={rc}：{open(log, encoding="utf-8", errors="replace").read().strip().splitlines()[-1:]}')
        if subprocess.run([sys.executable, os.path.join(P, 'iml_check.py'), 'check_app', app], capture_output=True).returncode: red('签后提高内存上限权限核实没过')
        tmp = a.dst + '.tmp'
        if os.path.exists(tmp): os.remove(tmp)
        if subprocess.run([sys.executable, os.path.join(P, 'app_bundle.py'), 'write_ipa', app, tmp], capture_output=True).returncode: red('打 ipa 失败')
        os.replace(tmp, a.dst); print(f'实验身份 {bid}（显示名「{info["CFBundleDisplayName"]}」）→ {a.dst}')
    finally:
        shutil.rmtree(t, ignore_errors=True)


if __name__ == '__main__':
    main()
