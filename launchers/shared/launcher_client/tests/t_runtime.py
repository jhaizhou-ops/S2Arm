"""Real Linux/POSIX worker tests. Only the injected test operation is synthetic."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT/'launchers/shared'))
from launcher_client.client import Client, Cursor, Projection, ProtocolError

WORKER = '''import json,os,pathlib,signal,sys,time
time.sleep(float(os.environ.get("LC_TEST_WORKER_DELAY","0")))   # 负控用：人为拖慢工作进程起来（模拟 gate-host 满载无缓存跑全套时被饿住）
sys.path.insert(0,sys.argv[1])
import main
from core import Failure
mode=sys.argv[3]
def operation(c):
 c.begin("合成阶段甲",1,2)
 c.emit("progress",done=2,total=7)
 c.begin("合成阶段乙",2,2)
 if mode=="fail": raise Failure("原创测试失败",code="tool_missing")
 if mode=="exit0": sys.exit(0)
 if mode in ("wait","ack"):
  if mode=="ack": signal.signal(signal.SIGTERM,lambda *_: (c.private/"signal").write_text("TERM"))
  (c.private/"armed").write_text("ready")
  while not (c.private/"release").exists(): c.check();time.sleep(.01)
 return {"synthetic":True}
sys.exit(main.run_request(sys.argv[2],operation_overrides={"saveStatus":operation}))
'''


# 等待都按事件判（就绪 = 工作进程写出标记文件、结束 = 进程退出码），到了立刻往下走；下面的秒数只是兜底上限（11-01 出包线：
#   原先 5 / 10 秒，门禁 gate-host 满载无缓存跑全套时工作进程起来慢，偶发「worker did not reach」/ 超时红；同合入线 fix/timing-tests-2 的修法）
READY_S = EXIT_S = 60


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.private=self.root/'private'
        self.request=self.root/'request.json'
        self.request.write_text(json.dumps(dict(schema=1,taskId='sample',operation='saveStatus',privateRoot=str(self.private),engineDir=str(ROOT))))
        self.request.chmod(0o600); self.client=Client(ROOT,self.private)

    def start(self,mode):
        p=subprocess.Popen([sys.executable,'-B','-I','-c',WORKER,str(ROOT/'pack/jobs'),str(self.request),mode],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        def cleanup():
            if p.poll() is None: p.kill(); p.communicate(timeout=EXIT_S)
        self.addCleanup(cleanup); return p

    def wait_for(self,name):
        end=time.monotonic()+READY_S
        while time.monotonic()<end:
            if (self.private/name).exists(): return
            time.sleep(.01)
        self.fail('worker did not reach '+name)

    def run_worker(self,mode):
        p=self.start(mode); out,err=p.communicate(timeout=EXIT_S)
        return p.returncode,[json.loads(x) for x in out.splitlines()],err

    def test_eof_success_failure_and_zero_exit_without_result(self):
        for mode,rc,state in [('ok',0,'completed'),('fail',1,'failed'),('exit0',0,'interrupted')]:
            code,events,err=self.run_worker(mode); self.assertEqual(code,rc,err)
            view=Projection('sample')
            for e in events: view.consume(e)
            view.eof(code); self.assertEqual(view.state,state)

    def test_real_cancel_and_interruption(self):
        p=self.start('wait'); self.wait_for('armed')
        ack=self.client.cancel('sample'); self.assertTrue(ack['cancelled'])
        out,err=p.communicate(timeout=EXIT_S); self.assertEqual(p.returncode,130,err)
        self.assertEqual(self.client.get('sample')['state'],'cancelled')
        (self.private/'armed').unlink()
        p=self.start('wait'); self.wait_for('armed'); p.kill(); p.communicate(timeout=EXIT_S)
        self.assertTrue(self.client.get('sample')['interrupted'])

    def test_ack_cannot_overrule_success(self):
        p=self.start('ack'); self.wait_for('armed'); view=Projection('sample')
        view.cancel_ack(self.client.cancel('sample')); self.wait_for('signal')
        self.assertEqual(view.state,'running'); self.assertFalse(self.client.get('sample')['terminal'])
        (self.private/'release').write_text('finish')
        out,err=p.communicate(timeout=EXIT_S); self.assertEqual(p.returncode,0,err)
        for e in map(json.loads,out.splitlines()): view.consume(e)
        self.assertEqual(view.state,'completed')

    def test_physical_cursor_attempt_and_bad_line(self):
        self.run_worker('ok'); path=self.private/'logs/jobs/sample.events.jsonl'   # 还没建库：任务记录在私有目录 logs/jobs（core.logs_root）
        with path.open('ab') as f: f.write(b'\n{invalid}\n')
        cursor=Cursor(); first=self.client.events('sample',cursor)
        self.assertEqual(len(first),4); self.assertEqual(cursor.line,6)
        self.assertEqual(self.client.get('sample')['events'],4)
        self.run_worker('ok'); second=self.client.events('sample',cursor)
        self.assertEqual([e['seq'] for e in second],[1,2,3,4]); self.assertEqual(cursor.line,10)
        self.assertEqual(self.client.get('sample')['attemptNo'],2)
        self.assertEqual(self.client.events('sample',cursor),[])

    def test_source_replacement_and_truncation_refused(self):
        self.run_worker('ok'); path=self.private/'logs/jobs/sample.events.jsonl'; c=Cursor()
        self.client.events('sample',c); path.write_bytes(b'')
        with self.assertRaises(ProtocolError): self.client.events('sample',c)
        self.run_worker('ok'); c=Cursor(); self.client.events('sample',c)
        other=path.with_suffix('.replacement'); other.write_bytes(path.read_bytes()); other.replace(path)
        with self.assertRaises(ProtocolError): self.client.events('sample',c)

    def test_terminal_shell_does_not_execute_missing_capabilities(self):
        p=subprocess.run([sys.executable,'-B',str(ROOT/'launchers/linux/main.py'),'devices'],capture_output=True,timeout=EXIT_S)
        self.assertEqual(p.returncode,2); self.assertFalse(json.loads(p.stdout)['supported'])
        p=subprocess.run([sys.executable,'-B',str(ROOT/'launchers/linux/main.py'),'install'],capture_output=True,timeout=EXIT_S)
        self.assertEqual(p.returncode,2)

if __name__=='__main__': unittest.main()
