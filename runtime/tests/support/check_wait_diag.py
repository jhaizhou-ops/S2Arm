"""校验真实线程合成夹具输出，不是游戏日志或调度模型。
v1 begin: 0x18 count=句柄数 ns=超时；0x1c object=key(x1) handle=w2 ns=x3。
0x1a handle=w0 object=key(x1) ns=-1 count=-1；
0x34 object=key(x0) kind=w1 count=(int)w2 ns=x3。object 为代号。"""
import re
import sys
from collections import defaultdict

def check(off, on):
    assert "等待诊断v1" not in off
    records = []
    for line in on.splitlines():
        if "[等待诊断v1]" in line:
            fields = dict(re.findall(r"(\w+)=([^ ]*)", line))
            records.append({k: (v if k in ("pc", "lr") else int(v, 0)) for k, v in fields.items()})
    assert len(records) > 1024, len(records)
    assert [r["seq"] for r in records] == list(range(1, len(records) + 1))
    waits = defaultdict(list)
    for r in records:
        waits[r["wait"]].append(r)
        for key in ("pc", "lr"):
            module, offset = r[key].split("+")
            assert not any(c in module for c in "/\\:")
            assert len(module) <= 15
            if r["seq"] == 1:
                assert module == "fixture" and int(offset, 0) == (4 if key == "pc" else 8)
            else:
                assert int(offset, 0) == 0  # unknown PCs emit no absolute address
    complete = [rs for rs in waits.values() if rs[0]["ev"] == 1 and rs[-1]["ev"] == 7]
    assert len(complete) >= 12
    poll, finite, immediate, infinite, invalid, count65 = complete[:6]
    assert poll[0]["ns"] == 0 and poll[-1]["result"] == 0xea01
    assert finite[0]["ns"] == 5000000 and finite[-1]["result"] == 0xea01
    blocks = [r for r in finite if r["ev"] == 3]
    assert blocks and 0 < blocks[0]["deadline_real_ns"] - blocks[0]["real_ns"] <= 5000000
    assert any(r["ev"] == 4 and r["result"] > 0 and r["elapsed_ns"] >= 4000000 for r in finite)
    assert finite[-1]["elapsed_ns"] >= 4000000
    assert immediate[-1]["result"] == 0 and immediate[1]["state"] == 1
    assert not any(r["ev"] == 3 for r in immediate)
    assert infinite[0]["ns"] == -1 and infinite[-1]["result"] == 0
    assert any(r["ev"] == 3 and r["ns"] == -1 and r["deadline_real_ns"] == 0 for r in infinite)
    handles = [r for r in infinite if r["ev"] == 2]
    assert handles and any(r["ev"] == 6 and r["source_tid"] == 0 and r["source_svc"] == 0 and r["object"] == handles[0]["object"] for r in infinite)
    assert invalid[-1]["result"] == 0xe401 and invalid[1]["kind"] == 0
    assert count65[-1]["result"] == 0xee01 and len(count65) == 2
    assert any(r["ev"] == 7 and r["result"] == 0xec01 for r in records)
    assert any(r["ev"] == 5 and r["source_svc"] == 0x19 for r in records)
    assert any(r["ev"] == 6 and r["source_svc"] == 0x11 and r["source_tid"] > 0 for r in records)
    assert any(r["ev"] == 8 and r["source_svc"] == 0x1d and r["object"] > 0 for r in records)
    cvs = [rs for rs in complete if rs[0]["svc"] == 0x1c]
    assert len(cvs) == 3
    assert cvs[0][-1]["result"] == 0 and all(rs[-1]["result"] == 0xea01 for rs in cvs[1:])
    locks = [rs for rs in complete if rs[0]["svc"] == 0x1a]
    assert len(locks) == 3
    assert all(rs[0]["object"] > 0 and rs[0]["handle"] and rs[0]["ns"] == -1 and rs[0]["count"] == -1 for rs in locks)
    assert [rs[-1]["result"] for rs in locks] == [0, 0, 0xe401]
    assert any(r["ev"] == 3 for r in locks[0]) and any(r["ev"] == 5 for r in locks[0])
    assert all(not any(r["ev"] == 3 for r in rs) for rs in locks[1:])
    addresses = [rs for rs in complete if rs[0]["svc"] == 0x34]
    assert len(addresses) == 5
    assert all(rs[0]["object"] > 0 and rs[0]["kind"] == 2 for rs in addresses)
    assert [(rs[0]["count"], rs[0]["ns"], rs[-1]["result"]) for rs in addresses[:3]] == [(2,0,0xfa01),(1,0,0xea01),(1,5000000,0xea01)]
    assert all(rs[-1]["result"] == 0 and any(r["ev"] == 3 for r in rs) and any(r["ev"] == 5 for r in rs) for rs in addresses[3:])
    assert all(rs[0]["tid"] == rs[-1]["tid"] and rs[0]["svc"] == rs[-1]["svc"] for rs in complete)
    ledgers = re.findall(r"produced=(\d+) emitted=(\d+) dropped=(\d+) pending=(\d+) key_overflow=(\d+) cap=(\d+)", on)
    assert ledgers
    produced, emitted, dropped, pending, keys, cap = map(int, ledgers[-1])
    assert produced == emitted + dropped + pending and emitted == len(records) and dropped == pending == keys == 0 and cap == 1024
    print(f"PASS actual wait records: {len(complete)} complete waits, 1A/34, correlation and ledger {produced}/{emitted}/{dropped}/{pending}")

if __name__ == "__main__":
    from pathlib import Path
    import subprocess
    off_path, on_path = map(Path, sys.argv[1:])
    check(off_path.read_text(), on_path.read_text())
    binary = on_path.parent / "t_thread_wait_diag"
    for mode in ("zero", "invalid"):
        result = subprocess.run([str(binary), mode], capture_output=True, text=True, check=True)
        assert "等待诊断v1" not in result.stdout + result.stderr
        assert "records=0 dropped=0" in result.stdout
    result = subprocess.run([str(binary), "ring"], capture_output=True, text=True, check=True)
    log = result.stdout + result.stderr
    seq = [int(n) for n in re.findall(r"\[等待诊断v1\] seq=(\d+)", log)]
    assert seq == list(range(4, 1028)), (seq[:3], seq[-3:])
    assert "produced=1027 emitted=1024 dropped=3 pending=0" in log
    print("PASS overflow: seq 4..1027; produced=1027 emitted=1024 dropped=3 pending=0; zero/invalid disabled")
