#!/usr/bin/env python3
"""通用帧率表（10-29 60 帧泛化，引擎三层的第二层「引擎限帧」按引擎做成通用规则）：python3 tools/fps_generic.py <产物根> <main 构建号>
  仓库 runtime/fps/ 没有本构建号的表时由 pack/stage_rewrite.sh 调；只读产物根里的 exefs/、romfs/、main.patched.bin，有结果才写 <产物根>/fps.tsv。
  UE4（graphics/nvn/games/profile_guess：主程序有 Unreal 标记且 romfs 有 .pak / .utoc）：控制台变量按名定位（tools/ue_cvar_loc.py，不依赖构建号；
    八方2 1.1.1 正对照与社区同构建号条目一致），t.MaxFPS 唯一找到 → 表 = present display（第一层）+ w 行（第二层）；r.VSync、
    r.DynamicRes.FrameTimeBudget（动态分辨率预算，写 1000/60 ms；原值宿主首次写入时记日志，fps.c，GTA III 缺省 36.5 不是 33.3）唯一找到才加，
    找不到不挡（10-30 grokbot 调研：社区补丁里 t.MaxFPS 约 695 个文件、r.VSync 约 530 个，担架拍档 1.0.0 社区改法就没有 r.VSync）。
  其余引擎 / 找不到 / 不唯一 / 已收了社区帧率补丁 → 不写（不猜、不叠两套）。Unity 第二层（Application.targetFrameRate setter，tools/il2cpp_fps_loc.py）要改指令，这里不做；
  Unity 第一层由直连宿主按引擎推导放开（graphics/nvn/host/game_tsv.h s2a_present_decide）。
  逻辑速度：UE4 缺省按帧间隔（DeltaTime）推进；判红的走强信号关（docs/名单_能力强信号/ / 名单_60帧 逻辑速度红 → 包内 fps60=0）。
退出码：0 写了表 / 1 不适用（不是 UE4、变量找不到或不唯一）/ 2 输入读不出"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'graphics', 'nvn', 'games'))
CVARS = (('t.MaxFPS', 'f32', '60', 't.MaxFPS（引擎限帧上限）', True),   # 末列：必需（找不到 / 不唯一就整张表不写）
         ('r.VSync', 'i32', '0', 'r.VSync 关（游戏自己的垂直同步等待；出图节拍由宿主管）', False),
         ('r.DynamicRes.FrameTimeBudget', 'f32', '16.6667', '动态分辨率帧预算 1000/60 ms（原预算按 30 帧算会在 60 帧下判不超预算、不降分辨率）', False))


def is_ue4(root):
    import profile_guess, tempfile
    # 先只看主程序标记（romfs 传空目录：facts_of 的 main_markers 只读 exefs/main）；不是 Unreal 就不遍历 romfs——
    #   11-03 火纹（25 万文件，非 UE4）在 Windows 上这一步整趟读文件头 592 秒，结论只取决于主程序标记
    with tempfile.TemporaryDirectory() as empty:
        if not profile_guess.facts_of(os.path.join(root, 'exefs'), empty).get('main_markers', set()) & {'Unreal', 'Unreal 4'}: return False
    F = profile_guess.facts_of(os.path.join(root, 'exefs'), os.path.join(root, 'romfs')); profile_guess.guess(F)
    m = F.get('main_markers', set())
    return bool(m & {'Unreal', 'Unreal 4'}) and bool(F['romfs']['exts'].get('.pak') or F['romfs']['exts'].get('.utoc'))


def ue4_rows(img):
    import ue_cvar_loc
    hits = ue_cvar_loc.locate(img, [c[0] for c in CVARS]); rows = []
    for n, ty, val, why, need in CVARS:
        h = sorted({o for _, o in hits[n]})
        if len(h) != 1:
            if need: return None, f'{n}：{"没找到注册处" if not h else "多处注册"}'
            continue
        rows.append(f'w main {h[0]:#x} {ty} {val} *0   # {why}（按名定位：注册处 main+{hits[n][0][0]:#x}）')
    return rows, ''


def main(a):
    if len(a) != 2: print(__doc__.strip()); return 2
    root, bid = a
    cp = os.path.join(root, 'cpatch.tsv')   # 已收了社区帧率补丁（编号 fps:）：不再叠通用表（同一款两套各改各的；cpatch 规划在本步之前，见 pack/cpatch.py own_fps）
    if os.path.exists(cp) and any(l.startswith('fps:') for l in open(cp, encoding='utf-8', errors='replace')):
        print('通用帧率表：已有社区帧率补丁进包，不写'); return 1
    try:
        if not is_ue4(root): print('通用帧率表：不是 UE4（或没有 .pak / .utoc），不写'); return 1
        img = open(os.path.join(root, 'main.patched.bin'), 'rb').read()
    except Exception as e:
        print(f'通用帧率表：输入读不出（{type(e).__name__}：{e}）'); return 2
    rows, why = ue4_rows(img)
    if rows is None: print(f'通用帧率表：UE4 但{why}，不写'); return 1
    with open(os.path.join(root, 'fps.tsv'), 'w', encoding='utf-8') as f:
        f.write(f'build {bid[:16]}\npresent display\n' + '\n'.join(rows) + '\n'
                '# 通用规则生成（tools/fps_generic.py：UE4 控制台变量按名定位，第一层放开交换间隔 + 第二层引擎限帧）；逻辑速度判红走强信号关\n')
    print(f'通用帧率表：UE4，写 fps.tsv（present display + {len(rows)} 行 w）'); return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
