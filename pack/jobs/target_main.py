#!/usr/bin/env python3
"""Opt-in versioned target entry. CLI/request privacy/cancellation stay in main.py."""
from __future__ import annotations

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from core import Context
import main as legacy
from pack.contracts.protocol import event_fields
from pack.contracts.validate import ContractError, validate
from pack.targets.ios import adapter as ios_adapter


class TargetContext(Context):
    def __init__(self, request):
        # Reject unsupported contracts before Context creates any job files.
        target = request.get("targetId")
        if target not in ("ios", "android"):
            raise ContractError("不支持的宿主目标。")
        if target == "ios":
            ios_adapter.check_request(request)
        else:
            from pack.targets.android import adapter as android_adapter
            validate("target", json.loads((ROOT / "pack/targets/android/target.json").read_text()))
            android_adapter.check_request(request)
        super().__init__(request)

    def emit(self, kind="progress", message="", done=None, total=None, **extra):
        fields = event_fields(kind, message, self.stage, getattr(self, "milestone", None), extra)
        super().emit(kind, message, done, total, **(extra | fields))


def android_build(context):
    from pack.targets.android import adapter as android_adapter
    return android_adapter.build(context)


def main():
    # The manifest describes capabilities; it does not create a second scheduler.
    try:
        validate("target", json.loads((ROOT / "pack/targets/ios/target.json").read_text()))
        return legacy.main(context_class=TargetContext, operation_overrides={"ipa": ios_adapter.build, "android": android_build})
    except ContractError as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
