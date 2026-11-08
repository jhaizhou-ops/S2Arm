#!/usr/bin/env python3
"""Explore the complete production WSI authority and native gate adapter.
Managed events only read a verdict; lifecycle callbacks own resets under the lease
mutex. Internal clock/lifecycle scheduling is tested separately by authority_races.c.
"""
import argparse,ctypes,hashlib,json,subprocess,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);p.add_argument('--cc',default='cc');p.add_argument('--depth',type=int,default=6)
p.add_argument('--negative-cap',action='store_true');p.add_argument('--negative',choices=['pause','resume','observation-reset','stale-clock','owner','epoch','withdrawal','late-progress'])
a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True)
native=ROOT/'android/native';header=(native/'backing_wait.h').read_text();lease=(native/'wsi_lease.c').read_text()
if a.negative_cap:
    header=header.replace('return idle < cap ? idle : cap;','(void)cap; return idle;')
if a.negative=='pause':header=header.replace('if (!foreground) return UINT64_MAX;','(void)foreground;')
if a.negative=='resume':lease=lease.replace('if (foreground && !l->state.stopping) s2a_backing_resumed(&l->backing);','/* negative: omit resume reset */')
if a.negative=='observation-reset':lease=lease.replace('int result = s2a_backing_decision(', 's2a_backing_resumed(&l->backing);\n    int result = s2a_backing_decision(')
if a.negative=='stale-clock':lease=lease.replace('if (foreground && !l->state.stopping) s2a_backing_resumed(&l->backing);','if (foreground && !l->state.stopping) l->backing.start = l->backing.progress = 0;')
if a.negative=='late-progress':header=header.replace('if (!foreground || now < s2a_backing_deadline(b, foreground, S2A_BACKING_ADMISSION_MARGIN_MS)) b->progress = now;', 'b->progress = now;')
if a.negative=='owner':header=header.replace('owner != b->owner || ','')
if a.negative=='epoch':lease=lease.replace('writer == l->backing.writer','1')
if a.negative=='withdrawal':lease=lease.replace('writer && writer == l->backing.writer && l->backing.owner','writer && writer == l->backing.writer && l->backing.owner && l->backing.active')
(a.out/'backing_wait.h').write_text(header);(a.out/'wsi_lease.c').write_text(lease);shutil.copy2(native/'wsi_lease.h',a.out/'wsi_lease.h')
renew=(native/'runtime/fault/thread_android.inc').read_text();renew=renew[renew.index('enum { ANDROID_VM_WAIT_SLICE_MS'):renew.index('// 仅内存SVC的锁外入口允许等待')]
prefix=r"""
#include <stdint.h>
#include <time.h>
static uint64_t model_now; static unsigned epoch;
static int model_clock_gettime(clockid_t id,struct timespec *ts) {
 (void)id;ts->tv_sec=model_now/1000000000ull;ts->tv_nsec=model_now%1000000000ull;return 0;
}
#define clock_gettime model_clock_gettime
#ifdef __APPLE__
#define pthread_condattr_setclock(a,c) ((void)(a),(void)(c),0)
#endif
#include "wsi_lease.c"
static s2a_wsi_lease *current;
unsigned s2a_android_guest_writers_epoch(void){return epoch;}
int s2a_android_host_backing_admission(unsigned writer,uint64_t *deadline){return s2a_wsi_backing_admission(current,writer,deadline);}
"""
wrapper=r"""
void step(uint64_t *v,int e) {
 model_now=v[0];epoch=v[1];
 s2a_wsi_lease l={.mutex=PTHREAD_MUTEX_INITIALIZER,.changed=PTHREAD_COND_INITIALIZER};current=&l;
 l.state.foreground=v[2];l.state.stopping=v[3];l.lifecycle_changes=v[11];
 l.backing=(s2a_backing_wait){.owner=v[4],.generation=v[5],.start=v[6],.progress=v[7],.writer=v[8],.active=v[9]};
 android_vm_renew_state s={.serial_epoch=v[13],.extended=v[14]};
 if(e==0) {uint64_t t=s2a_wsi_backing_progress(&l,epoch,0,1);if(t)v[10]=t;}
 if(e==1 && v[10])s2a_wsi_backing_progress(&l,epoch,v[10],1);
 if(e==2 && v[10])s2a_wsi_backing_progress(&l,epoch,v[10],0);
 if(e==3)s2a_wsi_set_foreground(&l,0);
 if(e==4)s2a_wsi_set_foreground(&l,1);
 if(e==5) {s2a_wsi_set_foreground(&l,0);model_now+=35000000000ull;s2a_wsi_set_foreground(&l,1);}
 if(e==6)epoch++;
 if(e==7)model_now+=350000000ull;
 if(e==8)model_now+=5000000000ull;
 if(e==9)s2a_wsi_backing_progress(&l,epoch,v[10]+100,0);
 if(e==10) {android_vm_admitted(&s,model_now,&v[12]);v[15]=1;}
 if(e==11)model_now+=2500000000ull;
 if(e==12||e==13){for(int n=0;n<(e==12?30:1);n++){model_now+=1000000000ull;if(v[10])s2a_wsi_backing_progress(&l,epoch,v[10],1);}}
 if(e==14)epoch=0;
 if(e==17)s2a_wsi_stop(&l);
 if(e==18)model_now+=3250000000ull;
 if(e==19)model_now+=1000000000ull;
 // Every event is followed by arbitrary managed/native observations. Neither
 // reader can reset budgets; first/late reads therefore commute.
 if(e==16 && !v[15])android_vm_renew(&s,model_now,&v[12]);
 v[16]=s2a_wsi_backing_decision(&l,v[10]);
 if(e!=16 && !v[15])android_vm_renew(&s,model_now,&v[12]);
 v[0]=model_now;v[1]=epoch;v[2]=l.state.foreground;v[3]=l.state.stopping;
 v[4]=l.backing.owner;v[5]=l.backing.generation;v[6]=l.backing.start;v[7]=l.backing.progress;v[8]=l.backing.writer;v[9]=l.backing.active;
 v[11]=l.lifecycle_changes;v[13]=s.serial_epoch;v[14]=s.extended;
 pthread_mutex_destroy(&l.mutex);pthread_cond_destroy(&l.changed);
}
"""
source=a.out/'model.c';source.write_text(prefix+renew+wrapper);lib=a.out/'model.so'
subprocess.run([a.cc,'-shared','-fPIC','-pthread','-Wno-pointer-bool-conversion',str(source),'-o',str(lib)],check=True)
step=ctypes.CDLL(str(lib.resolve())).step;step.argtypes=[ctypes.POINTER(ctypes.c_uint64),ctypes.c_int]
MAX=(1<<64)-1;MS=1000000

def oracle(v,e):
 n=list(v);now,epoch,fg,stop,owner,generation,start,progress,writer,active,token,life,deadline,serial,extended,admitted,verdict=n
 if e in [0,1,2,9,12,13]:
  if e in [12,13]:
   for _ in range(30 if e==12 else 1):
    now+=1000*MS
    if token and active and token==owner and writer==epoch and (not fg or stop or now<min(progress+4000*MS,start+31000*MS)):progress=now
  t=0 if e==0 else token+100 if e==9 else token;advance=e not in [2,9]
  valid=(e==0 or bool(token) or e==9) and bool(epoch) and ((not t and advance and not(active and writer==epoch)) or (bool(t) and active and t==owner and writer==epoch))
  if valid:
   if not t:generation+=1;owner=generation;writer=epoch;start=progress=now;token=owner
   elif advance and (not fg or stop or now<min(progress+4000*MS,start+31000*MS)):progress=now
   active=int(advance)
 if e in [3,4,5]:
  values=[0,1] if e==5 else [int(e==4)]
  for value in values:
   if value!=fg:
    if value and not stop:start=progress=now
    fg=value;life+=1
   if e==5 and value==0:now+=35000*MS
 if e==6:epoch+=1
 if e==7:now+=350*MS
 if e==8:now+=5000*MS
 if e==10:
  if extended:deadline=now+2000*MS
  admitted=1
 if e==11:now+=2500*MS
 if e==14:epoch=0
 if e==17:
  if not stop:life+=1
  stop=1
 if e==18:now+=3250*MS
 if e==19:now+=1000*MS
 verdict=3 if not token or token!=owner or not active else 0
 if verdict==0 and fg and not stop:
  verdict=2 if now>=start+30250*MS else 1 if now>=progress+3250*MS else 0
 if not admitted:
  if serial!=epoch:
   if extended:deadline=now+2000*MS
   serial=epoch
  if epoch and epoch==writer and owner:
   extended=1;deadline=min(progress+4000*MS,start+31000*MS) if fg and not stop else MAX
 return (now,epoch,fg,stop,owner,generation,start,progress,writer,active,token,life,deadline,serial,extended,admitted,verdict)

initial=(0,1,1,0,0,0,0,0,0,0,0,0,2000000000,0,0,0,3)
frontier={initial:()};seen={initial};edges=0;bydepth=[]
for depth in range(a.depth):
 nxt={}
 for state,trace in frontier.items():
  for e in range(20):
   actual=(ctypes.c_uint64*17)(*state);step(actual,e);expected=oracle(state,e);edges+=1
   if tuple(actual)!=expected:raise AssertionError(f'REGRESSION events={trace+(e,)} actual={tuple(actual)} expected={expected}')
   if expected not in seen:seen.add(expected);nxt[expected]=trace+(e,)
 bydepth.append(len(nxt));frontier=nxt
result=dict(passed=True,depth=a.depth,alphabet=20,states=len(seen),transitions=edges,states_by_depth=bydepth,source_sha256={str(q.relative_to(ROOT)):hashlib.sha256(q.read_bytes()).hexdigest() for q in [native/'backing_wait.h',native/'wsi_lease.h',native/'wsi_lease.c',native/'runtime/fault/thread_android.inc',Path(__file__)]},events=['begin','pulse','close','background','foreground','unobserved35s-cycle','new-epoch','350ms','5s','stale-close','admitted','late-first2500ms','30s+continuous-progress','1s+pulse','epoch-zero','managed-observe','native-observe','Stop','3250ms','1s'],scope='complete production WSI callbacks/authority + gate adapter; managed only opaque verdict. Lock internal interleaving separately authority_races; real Stop/barrier/roster separately gate suite. No Android/Vulkan/game.')
(a.out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print('PASS native authority model',json.dumps(result))
