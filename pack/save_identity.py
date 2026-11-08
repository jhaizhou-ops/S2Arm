"""Bind an iOS package to the same selected container identity as G05."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / "jobs"))
from library import selected_packages
from saves import identity


def inspect_identity(directory: Path, title_id: str):
    packages = []
    for line in (directory / "idx").read_text().splitlines():
        number, filename = line.split("\t", 1)
        metadata = directory / f"i{number}.json"
        if not metadata.exists():
            continue  # oneclick reports unreadable containers before selection.
        matches = [p for p in json.loads(metadata.read_text())["packages"] if p["baseId"] == title_id]
        packages.extend(p | {"path": filename} for p in matches)
    game = {"id": title_id, "packages": selected_packages({"packages": packages})}
    if not any(p["type"] == "base" for p in game["packages"]):
        raise ValueError("没有选中的游戏本体")
    hashes = {}
    for package in game["packages"]:
        path = package["path"]
        if path not in hashes:
            with open(path, "rb") as source:
                hashes[path] = hashlib.file_digest(source, "sha256").hexdigest()
        package["sha256"] = hashes[path]
    game["name"] = next((p["name"] for p in reversed(game["packages"]) if p.get("name")), title_id)
    return identity(game)


def validate(value):
    if not isinstance(value, dict) or set(value) != {"id", "name", "version", "contentIdentity"}:
        raise ValueError("存档游戏身份字段不完整")
    if not isinstance(value["id"], str) or not re.fullmatch(r"[0-9A-Fa-f]{16}", value["id"]):
        raise ValueError("游戏号无效")
    if type(value["version"]) is not int or value["version"] < 0 or not isinstance(value["name"], str):
        raise ValueError("游戏版本或名称无效")
    if not isinstance(value["contentIdentity"], str) or not re.fullmatch(r"[0-9a-f]{64}", value["contentIdentity"]):
        raise ValueError("游戏内容身份无效")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inspect", type=Path)
    parser.add_argument("--title-id")
    parser.add_argument("--check", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.check:
        value = validate(json.loads(args.check.read_text()))
    elif args.inspect and args.title_id:
        value = validate(inspect_identity(args.inspect, args.title_id))
    else:
        parser.error("需要 --check 或 --inspect 与 --title-id")
    data = json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
    if args.output:
        args.output.write_text(data)
    else:
        print(hashlib.sha256(data.encode()).hexdigest())


if __name__ == "__main__":
    main()
