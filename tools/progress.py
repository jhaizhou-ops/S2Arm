"""出包进度协议的 Python 写端（格式与 tools/progress.sh 相同：时刻<TAB>阶段<TAB>已完成<TAB>总数；调用方没给 S2A_PROGRESS 就不写）。

用法：from progress import Ticker；tk = Ticker("直连库", total)；每处理完一项 tk.step()（按 1 秒限频写，最后一项必写）。
"""
import os
import time


class Ticker:
    def __init__(self, stage, total, every=1.0):
        self.stage, self.total, self.every = stage, max(int(total), 0), every
        self.done, self.last = 0, 0.0
        self.path = os.environ.get("S2A_PROGRESS")
        self._write(force=True)

    def step(self, n=1):
        self.done = min(self.total, self.done + n)
        self._write(force=self.done >= self.total)

    def _write(self, force=False):
        now = time.time()
        if not self.path or not self.total or (not force and now - self.last < self.every):
            return
        self.last = now
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(f"{int(now)}\t{self.stage}\t{self.done}\t{self.total}\n")
