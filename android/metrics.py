#!/usr/bin/env python3
"""显式启用/标记/导出 Android 生产采集；不启动、停止或安装游戏。"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

# PR #209 (wdjwxh): validate producer output and publish only a complete copy.
from collect_run import collect, runtime_files


def safe_state(value):
    if (not value.startswith("files/") or not re.fullmatch(r"[A-Za-z0-9._/-]+", value)
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise ValueError("state-dir 必须是 App 私有 files/ 下的规范相对路径")
    return value


def runtime_library(remote, state, package, pid):
    """(runtime-library.json 原文或 None, kind)。外壳起局时在状态目录写这份记录（MainActivity，按 PID 绑定）：
    dev-override = 开发替换库的局，不作读数。没有记录时看本包的 BootSpec：BootSpec 已带 runtimeLibrary 字段
    （有这套记录的新包）却缺记录 → 拒绝；BootSpec 没有该字段或读不到（之前的包）→ "apk-legacy"，按正式局。"""
    try:
        raw = remote("cat", state + "/runtime-library.json")
    except subprocess.CalledProcessError:
        raw = None
    if raw is None:
        title = re.fullmatch(r"org\.s2arm\.game\.t([0-9a-f]{16})", package)
        boot = None
        if title:
            try:
                boot = json.loads(remote("cat", f"cache/boot-spec-{title[1].upper()}.json"))
            except (subprocess.CalledProcessError, ValueError):
                boot = None
        if isinstance(boot, dict) and isinstance(boot.get("diagnostics"), dict) and "runtimeLibrary" in boot["diagnostics"]:
            raise ValueError("本包的 BootSpec 带 runtimeLibrary，却缺 runtime-library.json：不能确认这一局跑的是哪份运行库，拒绝导出")
        return None, "apk-legacy"
    doc = json.loads(raw)
    if not isinstance(doc, dict) or not isinstance(doc.get("runtimeLibrary"), dict):
        raise ValueError("runtime-library.json 不是 {pid, runtimeLibrary: {kind…}} 对象，拒绝导出")
    kind = doc["runtimeLibrary"].get("kind")
    if doc.get("pid") != pid or kind not in ("apk", "dev-override"):
        raise ValueError("runtime-library.json 与该采集的 PID 不符或 kind 不认识，拒绝导出")
    return raw, kind


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("enable", "disable", "mark", "export"))
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--power-samples", type=Path)
    parser.add_argument("--run-manifest", type=Path)
    parser.add_argument("--allow-dev-run", action="store_true",
                        help="导出开发局（开发替换库）的原始证据；产物标 NOT-A-READING，不作读数")
    args = parser.parse_args()
    try:
        state = safe_state(args.state_dir)
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+", args.package):
            raise ValueError("非法包名")

        def remote(*command):
            # No PTY keeps stdout bytes unchanged; shell v2 also reports remote
            # failures for optional files. exec-out reports 0 even when cat fails.
            return subprocess.run([args.adb, "-s", args.serial, "shell", "-T", "run-as", args.package, *command],
                                  stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=20).stdout

        if args.action in ("enable", "disable"):
            remote("touch" if args.action == "enable" else "rm", state + "/metrics.enable")
            print("采集开关已设置；仅下次游戏进程启动生效，不改变当前局")
            return
        active = remote("cat", state + "/metrics-active.txt").decode("utf-8").strip()
        match = re.fullmatch(r"metrics-([0-9]+)-([0-9]+)-[a-f0-9]{32}", active)
        if not match:
            raise ValueError("无有效的生产采集 id")
        location = state + "/" + active
        if args.action == "mark":
            status = json.loads(remote("cat", location + "/runtime-metrics.json"))
            if not isinstance(status, dict) or status.get("id") != active:
                raise ValueError("active 指针与生产采集 id 不同")
            if status.get("status") != "capturing":
                raise ValueError("当前采集已结束；不能标记旧局")
            remote("touch", location + "/mark.request")
            print("已请求 MARK；只有后续成功提交游戏帧时才生效，请核 host.log")
            return
        if not args.output or args.output.exists():
            raise ValueError("export 需要不存在的 --output 目录")
        metadata = remote("cat", location + "/runtime-metrics.json")
        metadata_doc = json.loads(metadata)
        if not isinstance(metadata_doc, dict) or metadata_doc.get("id") != active:
            raise ValueError("active 指针与生产采集 id 不同")
        if metadata_doc.get("status") != "completed":
            raise ValueError("请先正常收局；当前采集未完成")
        library, kind = runtime_library(remote, state, args.package, int(match[2]))
        if kind == "dev-override" and not args.allow_dev_run:
            raise ValueError("开发局（开发替换库 sha256=" + str(json.loads(library)["runtimeLibrary"].get("sha256"))
                             + "），不作读数，拒绝导出；只要原始证据用 --allow-dev-run")
        # PR209 owner 的导出修复：Toybox ls 默认可能输出多列，必须显式一行一项。
        names = remote("ls", "-1", state).decode("utf-8").splitlines()
        pattern = rf"host-{match[1]}-{match[2]}-[A-Za-z0-9]+\.log"
        logs = [name for name in names if re.fullmatch(pattern, name)]
        if len(logs) != 1:
            raise ValueError("不能唯一绑定同 session/PID 的 host.log，拒绝猜选最新文件")
        # 本切片只导出原始证据；评分/能耗由独立共享工具消费，不在这里复制一套。
        frames = remote("cat", location + "/frames.tsv")
        host = remote("cat", state + "/" + logs[0])
        with tempfile.TemporaryDirectory(prefix="s2a-metrics-export-") as temporary:
            stage = Path(temporary)
            (stage / "frames.tsv").write_bytes(frames)
            (stage / "host.log").write_bytes(host)
            (stage / "runtime-metrics.json").write_bytes(metadata)
            files = {"host.log": stage / "host.log", **runtime_files(stage, stage / "host.log")}
            if library is not None:
                (stage / "runtime-library.json").write_bytes(library)
                files["runtime-library.json"] = stage / "runtime-library.json"
            if kind == "dev-override":
                marker = stage / "NOT-A-READING.txt"
                marker.write_text("开发局（开发替换库），不作读数、不进正式回执\n", encoding="utf-8")
                files[marker.name] = marker
            if args.power_samples:
                source = Path(str(args.power_samples) + ".source.json")
                info = json.loads(source.read_text(encoding="utf-8"))
                if not isinstance(info, dict) or info.get("serial") != args.serial:
                    raise ValueError("电池样本的 ADB transport 与本次导出不符")
                files.update({"battery.tsv": args.power_samples, "battery-source.json": source})
            if args.run_manifest:
                files["run-manifest.json"] = args.run_manifest
            collect(args.output, files)
        print(json.dumps({"directory": str(args.output), "id": active, "runtimeLibrary": kind,
                          "reading": kind != "dev-override"}, ensure_ascii=False))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(2, f"采集操作失败：{error}\n")


if __name__ == "__main__":
    main()
