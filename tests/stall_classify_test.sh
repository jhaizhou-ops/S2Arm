#!/bin/bash
# K01 / #194 停住现场归类单测：夹具期望 → 真结果表；加反例（正常局 0 次、只有崩溃现场不套低区账）、
# 判据分层（①②GPU.Emu 栈相同也不混判）、性能（1 万行以上 CPU 时间 1 秒内、4 倍行数 CPU 不到 8 倍）、规则表格式错要报红。
# 只用本机 Python 标准库，不联网、不读游戏：bash tests/stall_classify_test.sh
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; [ -n "${3:-}" ] && echo "    期望：$3"; bad=1; fi; }

F="$H/tests/fixtures/stall_classify"
SC="python3 $H/tools/stall_classify.py"

# kind 一行：从 JSON 里取每次停住的归类，逗号连接
kinds() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(",".join(s["kind"] for s in d["stalls"]))' "$1"; }

r() { $SC "$@" > "$T/out.md" 2> "$T/err.txt" --json "$T/out.json"; }

# ---- 正例：四份维护者贴的真实脱敏夹具，期望写在各夹具文件名里 --------------------------
r "$F/01_shader_materialize.log"
ck "① 着色器实化互等" '[ "$(kinds "$T/out.json")" = "着色器实化互等" ]' '着色器实化互等'
ck "① 首次帧号 707" 'grep -q "首次帧号：707" "$T/out.md"' '707'
ck "① 触发来源认得出（没有触发行，按块头原因反推）" 'grep -q "触发来源：.出图停住看门." "$T/out.md"' '出图停住看门'

r "$F/02_pso_job_wait.log"
ck "② 管线作业等待（GPU.Emu 栈与 ① 相同也不混判）" '[ "$(kinds "$T/out.json")" = "管线作业等待" ]' '管线作业等待'
ck "② 首次帧号 1259" 'grep -q "首次帧号：1259" "$T/out.md"' '1259'
ck "② 关键栈帧取在渲染线程 S2A.GPU 上、含 gal_pso_job_wait" \
   'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));k=d[\"stalls\"][0][\"key_frames\"];sys.exit(0 if k and \"S2A.GPU\" in k[0] and any(\"gal_pso_job_wait\" in x for x in k) else 1)" "$T/out.json"' '关键帧在 S2A.GPU'

r "$F/03_lowva_oom.log"
ck "③ 低区地址耗尽" '[ "$(kinds "$T/out.json")" = "低区地址耗尽" ]' '低区地址耗尽'
ck "③ 归属原生层" 'grep -q "建议归属：原生层" "$T/out.md"' '原生层'

r "$F/04_audio_silent.log"
ck "④ 声音（没有 [现场] 块，按日志行判）" '[ "$(kinds "$T/out.json")" = "声音" ]' '声音'
ck "④ 两条判据都满足时备注里写明（回调 0 次 + nx-172 0.98 核）" 'grep -q "两条判据都满足（回调 0 次 + nx-172 0.98 核）" "$T/out.md"' '两条判据'

# ④ 的判据是两条（issue 原文：回调 0 次 + 同时段某 nx-* 线程 ≥0.95 核）。
# 只满足第一条、没有第二条证据的，必须降为「声音（疑似）」而不是冒充 ④。
r "$F/06_audio_no_energy.log"
ck "④ 只满足「回调 0 次」、没有满核证据 → 声音（疑似）" '[ "$(kinds "$T/out.json")" = "声音（疑似）" ]' '声音（疑似）'
ck "声音（疑似）也写归属原生层（不留空）" 'grep -q "| 声音（疑似） | 原生层 | 1 |" "$T/out.md"' '归属原生层'
ck "降级时备注写明缺哪条" 'grep -q "同时段某 nx-\* 线程 ≥0.95 核」这一条在日志里没有证据" "$T/out.md"' '缺第二条'

r "$F/05_spin.log"
ck "满核空转（[s2a] 前缀下的 [现场] 也能解析）" '[ "$(kinds "$T/out.json")" = "满核空转" ]' '满核空转'

# ---- 真实全量日志暴露的三类误判（维护者用 7 份完整 host.log 验收，3/3 崩溃类判错）----------
# 共同原因：每份全线程现场里都有一条**空闲**的 .NET BGC 线程（栈在 gc_heap 里），
# 不加状态约束的话任何崩溃现场都会投到「内存回收」；渲染线程「每帧路过」的 prepare_draw 也会抢票。

r "$F/07_lowva_oom_full.log"
ck "07 低区耗尽 + 空闲 BGC 线程 → 低区地址耗尽（不被 BGC 抢成内存回收）" \
   '[ "$(kinds "$T/out.json")" = "低区地址耗尽" ]' '低区地址耗尽'

r "$F/08_gpu_driver_abort.log"
ck "08 Metal 驱动中止、渲染线程有 prepare_draw 路过 → GPU 驱动中止（不被抢成管线作业等待）" \
   '[ "$(kinds "$T/out.json")" = "GPU 驱动中止" ]' 'GPU 驱动中止'
ck "08 判据是崩溃发起点线程（备注写明）" 'grep -q "崩溃发起点" "$T/out.md"' '崩溃发起点'

r "$F/09_gc_stall_real.log"
ck "09 GC 真在跑（.NET BGC 状态在跑 + 游戏线程等 WaitForGCCompletion）→ 内存回收" \
   '[ "$(kinds "$T/out.json")" = "内存回收" ]' '内存回收'

r "$F/10_idle_bgc_not_gc.log"
ck "10 只有空闲 BGC、GC 没在干活 → 未知（不判成内存回收）" \
   '[ "$(kinds "$T/out.json")" = "未知" ]' '未知'

# ---- 42 份完整真实 host.log 暴露的三类误判（10-24 傍晚复审）------------------------------
# ① 固定 120 行窗口够不着低区账证据：真实日志里「低区账 [托管 OOM]」与崩溃现场块之间隔着约 510 行
#    退场取证（低区全列、窗口尾部逐块等）。夹具 11 把这段照原样留着（>500 行间隔 + 中间的周期统计行）。
r "$F/11_lowva_oom_far_evidence.log"
ck "11 低区账与现场块隔 500 行以上 → 仍是低区地址耗尽（窗口到「上一个站点之后」）" \
   'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));ks=[s[\"kind\"] for s in d[\"stalls\"]];sys.exit(0 if ks and set(ks)=={\"低区地址耗尽\"} and d[\"stalls\"][-1][\"threads\"]>0 else 1)" "$T/out.json"' '全部低区地址耗尽且末站点有现场块'
ck "11 崩溃站点那条（隔了 500 行）也归低区地址耗尽，不是未知" \
   'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if [s[\"kind\"] for s in d[\"stalls\"]][-1]==\"低区地址耗尽\" else 1)" "$T/out.json"' '末站点低区地址耗尽'
ck "11 中间那堆周期统计行不把站点带成内存回收" '! grep -q "内存回收" "$T/out.md"' '不判内存回收'

# ② 现场块被穿插的普通日志行截断：dump 期间别的线程照常打日志，块头下一行就是一条普通红行。
#    早先版本在这一行停住收尾，108 条线程一条都没读进去，第 0 层根本没机会跑。
r "$F/12_crash_interleaved_line.log"
ck "12 块头后紧跟普通日志行 → 线程仍全部读进（不得在那一行收尾）" \
   'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d[\"stalls\"][0][\"threads\"]>=4 else 1)" "$T/out.json"' '读到 >= 4 条线程'
ck "12 发起现场线程读到了（备注里点名 S2A.GPU.Emu）" 'grep -q "崩溃发起点：S2A.GPU.Emu" "$T/out.md"' 'S2A.GPU.Emu'
ck "12 穿插行给出警告、不静默丢掉" 'grep -q "现场块里穿插了普通日志行" "$T/out.md"' '警告里有穿插行'

# ③ 崩溃站点只看发起现场那条线程：别的线程（空闲音频 / 空闲 BGC / 渲染线程路过帧）一律不投票。
r "$F/13_own_abort_idle_audio.log"
ck "13 我方 abort（pso_desc.cold.1）+ 空闲音频线程 → 未知（不判成声音）" \
   '[ "$(kinds "$T/out.json")" = "未知" ]' '未知'
ck "13 备注写发起现场线程名与栈顶前 3 帧" 'grep -q "崩溃发起点：nx-83" "$T/out.md" && grep -q "栈顶前 3 帧" "$T/out.md"' 'nx-83 + 栈顶'

r "$F/14_crash_foreign_votes.log"
ck "14 SIGSEGV 在 nxgal_prog_load_binary + 别的线程有实化栈 → 不得判成着色器实化互等" \
   '[ "$(kinds "$T/out.json")" = "未知" ]' '未知'
ck "14 也不得被渲染线程的 gal_pso_job_wait 带成管线作业等待" '! grep -q "管线作业等待" "$T/out.md"' '不判管线作业等待'

# 模块列：真实栈里驱动帧常是 <redacted>+0xd0（AGXMetalG18P），符号被抹掉、只剩模块名。
r "$F/15_gpu_abort_module_only.log"
ck "15 符号被抹成 <redacted>、只剩模块 AGXMetalG18P → GPU 驱动中止" \
   '[ "$(kinds "$T/out.json")" = "GPU 驱动中止" ]' 'GPU 驱动中止'

# 服务线程只在「在跑」时算票：空闲的 AudioRendererManager.Worker / {AudioMain} 不算。
r "$F/13_own_abort_idle_audio.log"
ck "13 空闲音频线程（状态「等待」）不给票" \
   'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if all(\"音频\" not in (s.get(\"reason\") or \"\") for s in d[\"stalls\"]) else 1)" "$T/out.json"' '空闲音频不投票'

# ---- 停住看门现场里也有「（本线程，发起现场）」：只有崩溃站点才走发起线程那一层 ----------
# 42 份完整日志（9110c5ab）暴露的回退：_is_crash_site 原来还看「有没有线程标了（本线程，发起现场）」，
# 但停住看门现场里触发的 ap_main 也带这个标记 → 停住类整批落进「未知」，约 20 个 xc3 站点全错。
r "$F/16_stall_watchdog_ap_main.log"
ck "16 停住看门现场（发起现场是 ap_main）→ 着色器实化互等，不被当成崩溃站点" \
   '[ "$(kinds "$T/out.json")" = "着色器实化互等" ]' '着色器实化互等'
ck "16 不走「其它线程不投票」那条路（备注里没有这句话）" '! grep -q "其它线程不投票" "$T/out.md"' '不按崩溃站点判'
ck "16 关键栈帧仍取在渲染线程 S2A.GPU 的 WaitForProgram 上" \
   'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));k=d[\"stalls\"][0][\"key_frames\"];sys.exit(0 if k and \"S2A.GPU\" in k[0] and any(\"WaitForProgram\" in x for x in k) else 1)" "$T/out.json"' '关键帧在 WaitForProgram'

# ---- 反例 ----------------------------------------------------------------------------
r "$F/90_normal.log"
ck "反例：正常局（无现场、无触发行）→ 0 次" '[ "$(kinds "$T/out.json")" = "" ] && grep -q "0 次" "$T/out.md"' '0 次'

r "$F/91_crash_only.log"
ck "反例：只有崩溃现场、没有低区账行 → 未知（不套成 ③）" '[ "$(kinds "$T/out.json")" = "未知" ]' '未知'
ck "反例：未知不写归属" 'grep -q "| 未知 |  | 1 |" "$T/out.md"' '归属列为空'

r "$F/92_audio_ok.log"
ck "反例：声音输出正常（回调 12 次）→ 不算停住" '[ "$(kinds "$T/out.json")" = "" ]' '0 次'

# ---- 判据分层：同样的 GPU.Emu 栈，只有渲染线程栈不同，必须分开判 -------------------------
python3 - "$F" "$T" <<'PY'
import sys, pathlib
F, T = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
a = (F / '01_shader_materialize.log').read_text(encoding='utf-8')
b = (F / '02_pso_job_wait.log').read_text(encoding='utf-8')
def emu_parts(text):
    """拆出「S2A.GPU.Emu」那条线程的栈帧（pc / lr / #N）。
    头行里的 tid 和用户态秒数两份本来就不同，维护者说的是「栈相同」，所以只比栈帧。"""
    lines = text.splitlines()
    out, grab = [], False
    for ln in lines:
        if ln.startswith('[现场] 线程 ') and 'tid' in ln:
            grab = 'S2A.GPU.Emu' in ln
            continue
        if grab:
            out.append(ln)
    return out
emu_a, emu_b = emu_parts(a), emu_parts(b)
assert emu_a and emu_a == emu_b, '夹具前提不成立：①② 的 GPU.Emu 栈应完全相同'
# 把 ① 的渲染线程段换成 ② 的（GPU.Emu 段不动）→ 结果必须还是 ②
lines = a.splitlines()
head = lines[0]
tr_i = [i for i, l in enumerate(lines) if l.startswith('[现场] 线程 ')]
render_a = lines[tr_i[0]:tr_i[1]]
render_b = b.splitlines()
bt = [i for i, l in enumerate(render_b) if l.startswith('[现场] 线程 ')]
render_b_seg = render_b[bt[0]:bt[1]]
# GPU.Emu 段取 ① 的，渲染段与头行取 ② 的 → 结果必须跟 ② 走
mixed = [b.splitlines()[0]] + render_b_seg + emu_a
(T / 'mixed.log').write_text('\n'.join(mixed) + '\n', encoding='utf-8')
PY
r "$T/mixed.log"
ck "分层：①② 的 GPU.Emu 栈相同时，按渲染线程栈判（换成 ② 的渲染线程 → 判 ②）" \
   '[ "$(kinds "$T/out.json")" = "管线作业等待" ]' '管线作业等待'

# ---- 一个文件里多次停住：次数、首次帧号 -------------------------------
cat "$F/01_shader_materialize.log" > "$T/multi.log"
cat "$F/02_pso_job_wait.log" >> "$T/multi.log"
cat "$F/04_audio_silent.log" >> "$T/multi.log"
cat "$F/01_shader_materialize.log" >> "$T/multi.log"
r "$T/multi.log"
ck "多站点：4 次，按出现顺序归类" '[ "$(kinds "$T/out.json")" = "着色器实化互等,管线作业等待,声音,着色器实化互等" ]' '4 次顺序'
ck "多站点：着色器首次帧号取最小（707，不是第二次那个）" \
   'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d[\"summary\"][\"着色器实化互等\"][\"first_frame\"]==707 else 1)" "$T/out.json"' '707'

# ---- 性能：1 万行以上 CPU 时间 1 秒内，且 4 倍行数 CPU 不超过 8 倍（线性，不是 O(n²)）--------
# 量子进程自己花的 CPU 时间（用户态 + 内核态），不量墙钟：门禁 289 步并发、负载 30+ 时，
# 墙钟里九成以上是排队等核（10-31 门禁 12108 行墙钟 1915 ms，本机实测 CPU 只用 ~80 ms）。
# CPU 时间只数本进程真干的活，负载高低基本不改它。
# 两条判据各抓一类退化：
#   绝对：12108 行 CPU < 1000 ms（本机 ~80 ms，含 Python 起动 ~55 ms，12 倍余量盖大小核 / 缓存抖动）——抓常数级变慢；
#   增长：48432 行 / 12108 行的 CPU 比 < 8。线性时边际比 4，起动固定成本让它更小（实测 ~2.2）；
#         O(n²) 边际比 16（负控：逐行重扫 12108 行只多 ~650 ms，过得了绝对门槛，但比值 ~15 红）。
python3 - "$F" "$T" <<'PY'
import sys, pathlib
F, T = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
one = (F / '01_shader_materialize.log').read_text(encoding='utf-8')
noise = ''.join(f'2026-10-24 11:{i // 60:02d}:{i % 60:02d}.000 S2Arm[900:1] [gal] 帧节拍：交换间隔 2，每帧 33.3 ms（30 帧/秒）\n' for i in range(3000))
(T / 'perf.log').write_text((noise + one) * 4, encoding='utf-8')
(T / 'perf4.log').write_text((noise + one) * 16, encoding='utf-8')
PY
cpu_ms() {  # 跑一次归类，打印子进程 CPU 毫秒（用户态 + 内核态）
  python3 - "$H/tools/stall_classify.py" "$1" "$2" <<'PY'
import resource, subprocess, sys
r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
subprocess.run([sys.executable, sys.argv[1], sys.argv[2], '--json', sys.argv[3]],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
print(max(1, int((r1.ru_utime + r1.ru_stime - r0.ru_utime - r0.ru_stime) * 1000)))
PY
}
LINES=$(wc -l < "$T/perf.log"); LINES4=$(wc -l < "$T/perf4.log")
MS=$(cpu_ms "$T/perf.log" "$T/perf.json"); MS4=$(cpu_ms "$T/perf4.log" "$T/perf4.json")
ck "性能：${LINES} 行 CPU ${MS} ms（要求 < 1000 ms，量 CPU 时间不量墙钟）" '[ "$MS" -lt 1000 ] && [ "$LINES" -gt 10000 ] && [ -s "$T/perf.json" ]' '1 万行 CPU 1 秒内'
ck "性能增长：${LINES4} 行 CPU ${MS4} ms ÷ ${LINES} 行 CPU ${MS} ms < 8（线性 ≤4，O(n²) ≈16）" '[ -s "$T/perf4.json" ] && [ $((MS4)) -lt $((MS * 8)) ]' '4 倍行数 CPU 不到 8 倍'

# ---- 规则表格式错必须报红（不能悄悄跳过一行规则）-------------------------
printf 'kind\towner\tslot\tthread\tstate\tweight\tpattern\tnote\n坏规则\t原生层\t认不得的slot\t*\t*\t10\tx\t说明\n' > "$T/bad.tsv"
$SC "$F/01_shader_materialize.log" --rules "$T/bad.tsv" > /dev/null 2> "$T/err.txt"
RC=$?
ck "规则表 slot 写错 → 非 0 退出并说明" '[ $RC -ne 0 ] && grep -q "slot 认不得" "$T/err.txt"' '退出非 0'
printf 'kind\towner\tslot\tthread\tstate\tweight\tpattern\tnote\n坏正则\t原生层\tlog_line\t*\t*\t10\t[未闭合\t说明\n' > "$T/bad2.tsv"
$SC "$F/01_shader_materialize.log" --rules "$T/bad2.tsv" > /dev/null 2> "$T/err.txt"
RC=$?
ck "规则表正则坏 → 非 0 退出并说明" '[ $RC -ne 0 ] && grep -q "正则编译不过" "$T/err.txt"' '退出非 0'
printf 'kind\towner\tslot\tthread\tstate\tweight\tpattern\tnote\n坏状态\t原生层\tthread_stack\t*\t在跑|!等待\t10\tx\t说明\n' > "$T/bad3.tsv"
$SC "$F/01_shader_materialize.log" --rules "$T/bad3.tsv" > /dev/null 2> "$T/err.txt"
RC=$?
ck "规则表 state 列自相矛盾（同时写允许和禁止）→ 非 0 退出" '[ $RC -ne 0 ] && grep -q "不能同时写允许和禁止" "$T/err.txt"' '退出非 0'

# ---- 规则表可扩展：加一行新类就能归出来，不改代码 -----------------------
cp "$H/tools/stall_rules.tsv" "$T/ext.tsv"
printf '测试新类\t原生层\tlog_line\t*\t*\t10\t测试用的新停住行\t加一行就能归\n' >> "$T/ext.tsv"
printf '2026-10-24 11:00:00.000 S2Arm[900:1] [s2a] 出图停住看门：上屏帧数停在 42 已 10 秒（第 1 次），游戏线程表 + 宿主线程栈：\n2026-10-24 11:00:00.100 S2Arm[900:1] 测试用的新停住行\n' > "$T/newkind.log"
$SC "$T/newkind.log" --rules "$T/ext.tsv" > "$T/out.md" 2>/dev/null --json "$T/out.json"
ck "规则表加一行 → 新类归得出来（不用改 stall_classify.py）" '[ "$(kinds "$T/out.json")" = "测试新类" ]' '测试新类'

# ---- JSON / Markdown 两种输出都齐 ------------------------------------
r "$F/01_shader_materialize.log"
ck "JSON 有 summary / stalls / source" \
   'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert set([\"summary\",\"stalls\",\"source\"])<=set(d)" "$T/out.json"' '三个顶层键'
ck "Markdown 有每类次数表与逐站点" 'grep -q "每类次数" "$T/out.md" && grep -q "逐站点" "$T/out.md"' '两节都在'
ck "寄存器行被跳过、不计成栈帧" \
   'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if all(not x.startswith(\"x\") for s in d[\"stalls\"] for x in s[\"key_frames\"]) else 1)" "$T/out.json"' '无 x0 帧'

[ $bad = 0 ] && echo "stall_classify 单测全过" || { echo "stall_classify 单测有不通"; exit 1; }
