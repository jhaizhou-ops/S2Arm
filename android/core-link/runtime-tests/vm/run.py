#!/usr/bin/env python3
"""Linux 真实 VM/tracker/内核事务；其余 core 与 thread安全点端点明确为合成。"""
import argparse,json,pathlib,subprocess,re,sys
p=argparse.ArgumentParser();p.add_argument('--out',type=pathlib.Path,required=True);p.add_argument('--cc',default='cc');p.add_argument('--case',action='append');p.add_argument('--svc-source',type=pathlib.Path);a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[4];out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
# 端点核对先跑：svc_*.c 新引用的 core 符号漏登记在这里红（mac 也拦），不等到链接报错。
subprocess.run([sys.executable,str(pathlib.Path(__file__).with_name('check_endpoints.py')),'--root',str(root),'--cc',a.cc,'--out',out/'endpoint-check']+(['--svc-source',str(a.svc_source)] if a.svc_source else []),cwd=root,check=True)
f=[a.cc,'-D_GNU_SOURCE','-DS2A_UNIT_TEST','-std=gnu11','-O2','-Wall','-Wextra','-pthread','-Iruntime/include','-Iruntime/src','-Iandroid/native']
objects=[]
for label,src,extra in [('svc',str(a.svc_source) if a.svc_source else 'runtime/src/svc_mem.c',['-D__ANDROID__','-Werror']),('track','graphics/track/track.c',[])]:
    obj=out/(label+'.o');subprocess.run(f+extra+['-c',src,'-o',str(obj)],cwd=root,check=True);objects.append(str(obj))
sources=['runtime/src/layout.c','runtime/src/os.c','android/core-link/runtime-tests/vm/vm_test.c','android/native/runtime/vm/backing.c','android/native/nvn/s2a_vp_alias.c','android/native/runtime/tracking/platform.c','android/native/runtime/tracking/readonly_copy.c','android/native/runtime/tracking/runtime.c','android/native/runtime/tracking/registry.c','android/native/plat_android.c','android/native/memory.c','android/native/guest_signal.c','android/native/tsd.c','android/native/redlog.c']
exe=out/'vm-test';subprocess.run(f+sources+objects+['-Wl,--wrap=mmap','-Wl,--wrap=mremap','-Wl,--wrap=mprotect','-Wl,--wrap=munmap','-Wl,--wrap=madvise','-Wl,--wrap=fallocate','-Wl,--wrap=plat_page_size','-Wl,--wrap=s2a_track_prot_changed','-Wl,--wrap=s2a_track_backing_reset_before_publish','-Wl,--wrap=s2a_track_backing_begin','-ldl','-o',str(exe)],cwd=root,check=True)
# lockorder-wired：hle_nvn.c 的 vp_lock() 必须真的调断言；主机不链接 NVN 前端，做源码级接线检查。
hle=(root/'graphics/nvn/gfx/nvn/hle_nvn.c').read_text()
start=hle.find('static void vp_lock'); end=hle.find('static void vp_unlock')
if start<0 or end<start or 's2a_mem_lockorder_vp_enter();' not in hle[start:end] or 'pthread_mutex_lock(&g_vp_mu)' not in hle[start:end]:
    raise SystemExit('lockorder-wired FAIL: hle_nvn.c 的 vp_lock 没有按序调断言 / 取 g_vp_mu')
print('lockorder-wired PASS',flush=True)
# vpalias-wired：vpool_map 的「只进页表」早退必须在别名表 / 背板 ref 之前；否则 4K 对齐、16K 不对齐的请求会撞 add/remove 的对齐断言。
start=hle.find('static int vpool_map'); end=hle.find('NVN(nvnMemoryPoolMapVirtual')
body=hle[start:end] if start>=0 and end>start else ''
early=body.find('kept in the page table only'); ref=body.find('s2a_mem_backing_alias_ref('); rem=body.find('s2a_vp_alias_remove(')
if not body or early<0 or ref<0 or rem<0 or not (early<ref and early<rem):
    raise SystemExit('vpalias-wired FAIL: vpool_map 的页表早退不在别名表 / ref 之前')
if 'NVN 别名表' not in (root/'android/native/nvn/s2a_vp_alias.c').read_text():
    raise SystemExit('vpalias-wired FAIL: s2a_vp_alias.c 缺少入口对齐断言')
print('vpalias-wired PASS',flush=True)
results=[]
for case in a.case or ['backing-api','backing-api-16k','backing-vma-merge','physical-unmap-borrowed','backing-alias-shared','backing-alias-merge','nvn-remap-ref','nvn-ref-race','nvn-dead-tail','deferred-report','tmem-close-mapped','stray-alias-refill','readonly-punch-race','nvn-stopworld','lockorder-abort','va-report-lock','punch-stats','vma-far','nvn-alias-16k','unmap-madvise-private','transfer-model16-source','code-model16-source','physical','physical-mirror','physical-mirror-report','physical-mirror-report-limit-unread','physical-mirror-syscall','owner-window-fail','physical-mirror-fallback','physical-mirror-split','physical-mirror-snapshot','physical-mirror-race','private-stack-mirror','heap','physical-map-fail','heap-grow-fail','physical-unmap-fail','heap-unmap-fail','physical-host16-partial','protect-4k','stack-4k','stack-copy','stack-readback','stack-source-readback','hooks-conflict','shared','partial-shared','shared-4k','shared-4k-unmap-fail','shared-model16-source','shared-model16-target','shared-model16-partial','code','code-4k','transfer','transfer-4k','private-source','protect-fail','unmap-fail','quiesce-fail','poison']:
    r=subprocess.run([str(exe),case],capture_output=True,text=True,timeout=15)
    passed=(r.returncode==-6 and '无法恢复地址保留' in r.stderr) if case=='poison' else (r.returncode==-6 and '背板映射失败' in r.stderr) if case in ['physical-map-fail','heap-grow-fail','physical-unmap-fail','heap-unmap-fail'] else (r.returncode==-6 and '宿主writer协调失败 errno=95' in r.stderr) if case=='quiesce-fail' else r.returncode==0
    if case == 'physical-mirror-fallback' and passed:
        passed=r.stderr.count('第二窗口预留失败') == 1
    if case == 'physical-mirror-report' and passed:
        match=re.search(r'retry=(?P<retry>\d+) odd_wait=(?P<odd_wait>\d+) outside=(?P<outside>\d+) init_fail=(?P<init_fail>\d+) VMA guest=(?P<guest>\d+) mirror=(?P<mirror>\d+) total=(?P<total>\d+) max=(?P<max>\d+)',r.stderr)
        passed=bool(match and int(match['guest'])>0 and int(match['mirror'])>0 and 0<int(match['total'])<=int(match['max']))
    if case == 'physical-mirror-report-limit-unread' and passed:
        match=re.search(r'retry=(?P<retry>\d+) odd_wait=(?P<odd_wait>\d+) outside=(?P<outside>\d+) init_fail=(?P<init_fail>\d+) VMA guest=(?P<guest>\d+) mirror=(?P<mirror>\d+) total=(?P<total>\d+) max=不可读 errno=(?P<errno>\d+)',r.stderr)
        passed=bool(match and int(match['guest'])>0 and int(match['mirror'])>0 and int(match['total'])>0 and int(match['errno'])>0)
    if case == 'unmap-madvise-private' and passed:
        passed='UnmapMemory madvise(MADV_FREE) errno=' in r.stderr
    if case == 'deferred-report' and passed:
        passed='deferred=1 ' in r.stderr or 'deferred=1\n' in r.stderr
    if case == 'nvn-ref-race' and passed:
        passed='reuse_denied=1' in r.stderr
    if case == 'va-report-lock' and passed:
        passed='[vma] [fixture]' in r.stderr and 'far=' in r.stderr
    if case == 'punch-stats' and passed:
        match=re.search(r'punch_commit=(\d+)/(\d+) ns punch_release=(\d+)/(\d+) ns punch_unref=(\d+)/(\d+) ns',r.stderr)
        passed=bool(match and int(match.group(1))>=8 and int(match.group(2))>0
                    and int(match.group(3))>=8 and int(match.group(4))>0
                    and int(match.group(5))==1 and int(match.group(6))>0)
    if case == 'vma-far' and passed:
        host=re.search(r'\[vma\] \[vma-far-host\][^\n]*far=0 host=(\d+)',r.stderr)
        guest=re.search(r'\[vma\] \[vma-far-guest\][^\n]*far=1 host=\d+',r.stderr)
        passed=bool(host and int(host.group(1))>0 and guest)
    results.append(dict(case=case,passed=passed,returncode=r.returncode,stdout=r.stdout,stderr=r.stderr));print(case,'PASS' if passed else 'FAIL',r.returncode,flush=True)
(out/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
if not all(x['passed'] for x in results):raise SystemExit(1)
