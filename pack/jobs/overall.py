# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""整单进度（每条作业事件的 overall，0–1）：作业层唯一一份，前端只显示它、不自己拼。

为什么在这里算（11-11 维护者：「编译着色器这一步百分比反复到 91% 又跳回 40%」「最后一步也是，91% 到 99% 又跳回来」）：
前端原先按「当前计数器的 done / total」填当前一步。一步里几个计数器先后出现（抽取 1..4/4 → 直连库 k/5 → 翻译与收尾 n/3974 → 编批库 0..100），
还有贯穿整单的「刷新各阶段 k/10」夹在中间、「出包 6/5」越界；收尾几个阶段（清理、写单一 IMG、组装 ipa）各报 1/1。
每换一个计数器，百分比就回退。

口径（期望值可以不跑实现、按事件手算）：
- 权重 = plan 事件里各里程碑的本机实测（source=history 且有样本的 expected；source=reuse 的按记录、缺了 0；pack/jobs/milestones.py），
  每步至少 1 秒；有任何一步没有实测 → 各步等权。
  与前端分段条的分段宽度同一口径（ExportSessionView / ExportPages.cs weights）。
- 当前里程碑内部的完成度 = 本步已用时 ÷ 本步 expected，最多 STEP_CAP；没有历史时为 0（只在换步时前进，不编常数）。
  计数器不参与：同一步里几个计数器先后出现、互不嵌套，任何一个都不代表整步。
- overall = (前面各步权重和 + 本步权重 × 本步完成度) ÷ 权重总和，最多 RUN_CAP；只增不减（取历史最大）。
- 成功的结果事件（state succeeded / completed）才到 1。失败、取消停在原处。
- 没有 plan、或当前里程碑不在 plan 里（导入、准备等别的作业）：不给 overall（None），前端按原来的计数显示。
"""

STEP_CAP = 0.95
RUN_CAP = 0.99


class Overall:
    def __init__(self):
        self.value = None
        self.weights = None      # [(里程碑 id, 权重)]
        self.timed = False       # 有没有历史（决定本步内部按时间推不推）
        self.current = None
        self.started = 0.0

    def plan(self, milestones):
        def measured(m):   # 同前端 Milestone.measured（PackModels.cs / Milestones.swift）：复用的步按记录（缺了 0），有本机历史的取它，其余算没有
            e = m.get("expected")
            if m.get("source") == "reuse":
                return float(e or 0)
            return float(e) if m.get("source") == "history" and (m.get("samples") or 0) > 0 and isinstance(e, (int, float)) else None
        rows = [(m.get("id"), measured(m)) for m in milestones or [] if m.get("id")]
        if not rows:
            return
        self.timed = all(e is not None for _, e in rows) and sum(e for _, e in rows) > 0
        self.weights = [(mid, max(float(e), 1.0) if self.timed else 1.0) for mid, e in rows]   # 每步至少按 1 秒（同前端分段条 weights）
        if self.value is None:
            self.value = 0.0

    def feed(self, kind, elapsed, milestone, state=None):
        """一条事件 → 这条事件该带的 overall（None = 本作业没有整单进度）"""
        if self.weights is None:
            return None
        if kind == "result":
            if state in ("succeeded", "completed"):
                self.value = 1.0
            return round(self.value, 4)
        ids = [mid for mid, _ in self.weights]
        if milestone in ids:
            if milestone != self.current:
                self.current, self.started = milestone, elapsed
            k = ids.index(milestone)
            before = sum(w for _, w in self.weights[:k])
            w = self.weights[k][1]
            inside = min(STEP_CAP, max(0.0, elapsed - self.started) / w) if self.timed and w > 0 else 0.0
            total = sum(w for _, w in self.weights)
            raw = min(RUN_CAP, (before + w * inside) / total) if total > 0 else 0.0
            self.value = max(self.value, raw)
        return round(self.value, 4)
