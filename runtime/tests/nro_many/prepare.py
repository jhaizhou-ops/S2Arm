"""nn::ro 多 NRO 夹具（11-03 大乱斗 SPECIAL：nro_modules.tsv 764 行，原定长模块表 256 装不下）。
自有 0BSD 模块 runtime/tests/cpatch_loader/module.nso 交出包缺省 C 改写器改写一次（main），再改写一次作 nro0；
改写产物不含模块名（<名>.fixups.tsv / .patched.bin / .gates.tsv / .sites.tsv 内容与名字无关），nro1… 按名字拷贝 nro0 的产物。
nro_modules.tsv：N 行，第 k 行 = nro<k>、SHA-256 = k 低字节 / k 高字节 + 30 个 0x5a、NRO 大小 0x10000、bss 0（单测按同一规则造哈希去装）。
用法：prepare.py <输出目录> <NRO 个数>"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]).resolve(); n = int(sys.argv[2])
shutil.rmtree(out, ignore_errors=True); out.mkdir(parents=True)
fixture = root / "runtime/tests/cpatch_loader/module.nso"
if hashlib.sha256(fixture.read_bytes()).hexdigest() != "2387bf7917e2a680115c802fb10c7023052aa10aef4f8e3cc73f4bfd7799fdaf":
    raise ValueError("自有模块 NSO 的固定 SHA-256 不符")
rewriter = subprocess.check_output([sys.executable, str(root / "pack/rewriter.py"), "c-path"], text=True).strip()
for module in ("main", "nro0"):
    subprocess.run([rewriter, str(fixture), str(out), module], env=dict(os.environ, S2A_TARGET="apple"), check=True, stdout=subprocess.DEVNULL)
kinds = [p.name[len("nro0"):] for p in out.glob("nro0.*")]
for k in range(1, n):
    for kind in kinds: shutil.copyfile(out / f"nro0{kind}", out / f"nro{k}{kind}")
with open(out / "nro_modules.tsv", "w") as f:
    f.write("# 模块名\tSHA-256\tNRO 大小\tbss 大小\tromfs 相对路径\n")
    for k in range(n): f.write(f"nro{k}\t{k & 0xff:02x}{k >> 8:02x}{'5a' * 30}\t0x10000\t0x0\tdata.arc@{k:#x}:zstd\n")
