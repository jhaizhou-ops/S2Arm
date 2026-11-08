"""Add machine-readable fields while preserving the local job v1 payload."""
from __future__ import annotations


STAGES = {
    "unpack": "input.unpack", "rewrite": "rewrite",
    "sysdata": "sysdata", "layout": "uilayout", "index": "romfsidx",
    "sh_extract": "shader.extract", "sh_translate": "shader.translate", "sh_compile": "shader.metal",
    "sh_pipeline": "shader.archive", "sh_link": "shader.dylib", "ipa": "bundle.ipa",
}


def event_fields(kind, message, stage, milestone, extra):
    diagnostic = extra.get("diagnostic") or extra.get("error") or {}
    if kind == "result" and extra.get("state") == "failed":
        diagnostic = next((d for d in reversed(extra.get("diagnostics", [])) if d.get("severity") == "error"), diagnostic)
    state = extra.get("state", "running")
    if diagnostic.get("code"):
        code = diagnostic["code"]
    elif state == "failed" or kind == "diagnostic":
        # Same stable generic error as the upstream worker; never job.failed.
        code = "job_failed"
    elif kind == "result":
        code = {"succeeded": "job.succeeded", "cancelled": "job.cancelled"}[state]
    else:
        code = f"job.{kind}"
    suggestion = diagnostic.get("suggestion") or {
        "succeeded": "使用本次交付的安装包与资源包。",
        "failed": "查看本任务的错误摘要，修复后重试。",
        "cancelled": "需要时重新发起任务，已有成功产物保留。",
    }.get(state, "等待当前阶段完成；可取消本任务。")
    return dict(contract="s2a.job-event.v1", code=code,
                description=message or ("任务运行中" if kind == "heartbeat" else "任务状态已更新"),
                stageId=STAGES.get(milestone, "input.validate" if stage == "检查游戏输入" else "job"), nextAction=suggestion)
