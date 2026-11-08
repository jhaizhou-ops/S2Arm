"""把自有 NSO 交给出包缺省 C 改写器；不手造容器或替换生产入口。"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
fixture = Path(__file__).with_name("module.nso")
if hashlib.sha256(fixture.read_bytes()).hexdigest() != "2387bf7917e2a680115c802fb10c7023052aa10aef4f8e3cc73f4bfd7799fdaf":
    raise ValueError("自有模块 NSO 的固定 SHA-256 不符")
rewriter = subprocess.check_output(
    [sys.executable, str(root / "pack/rewriter.py"), "c-path"], text=True).strip()
rows = out / "cpatch_rows.tsv"
rows.write_text("".join(
    f"p\t{module}\t{0x100 + bit * 8:x}\t528003c0\t52800780\t{bit}\n"
    for module in ("main", "subsdk0") for bit in range(64)))
for module in ("main", "subsdk0"):
    subprocess.run([rewriter, str(fixture), str(out), module],
                   env=dict(os.environ, S2A_CPATCH_TSV=str(rows), S2A_TARGET="apple"), check=True)
