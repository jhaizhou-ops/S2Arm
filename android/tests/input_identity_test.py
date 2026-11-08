#!/usr/bin/env python3
"""Check that a build artifact is bound to its input manifest.

Usage: input_identity_test.py <staged-game-root>

Adds a `game-input-manifest.json` to the active revision and an `input` block to
the artifact, then proves:
  - a matching input manifest validates;
  - changing input.titleId is rejected;
  - changing an input module buildId is rejected.
"""
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VALIDATE = os.path.join(HERE, "..", "contracts", "validate.py")


def fail(msg):
    sys.exit(f"input_identity_test: {msg}")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def validate(root):
    return subprocess.run([sys.executable, VALIDATE, "--game", root],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def main():
    if len(sys.argv) != 2:
        fail("usage: input_identity_test.py <game-root>")
    root = os.path.abspath(sys.argv[1])
    current = json.load(open(os.path.join(root, "current.json"), encoding="utf-8"))
    revision = os.path.join(root, current["revisionDir"])
    artifact_path = os.path.join(revision, current["artifact"])
    artifact = json.load(open(artifact_path, encoding="utf-8"))
    module = artifact["modules"][0]
    if "buildId" not in module:
        fail("synthetic module has no buildId")

    manifest = {
        "version": 1,
        "titleId": artifact["titleId"],
        "name": "S2Arm synthetic",
        "displayVersion": "0.1",
        "base": {
            "contentId": artifact["titleId"],
            "version": "0",
            "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        },
        "update": None,
        "dlc": [],
        "systemData": None,
        "modules": [{
            "name": module["name"],
            "type": "exefs",
            "buildId": module["buildId"],
            "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        }],
        "romfs": {
            "contentRoot": artifact["contentRoot"],
            "files": 2,
            "bytes": 1024,
        },
        "tool": {"name": "input_identity_test", "version": "1"},
        "createdAt": "2026-10-22T15:30:00Z",
    }
    manifest_path = os.path.join(revision, "game-input-manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
        f.write("\n")

    artifact["input"] = {
        "manifest": "game-input-manifest.json",
        "manifestSha256": sha(manifest_path),
        "contentRoot": manifest["romfs"]["contentRoot"],
        "titleId": artifact["titleId"],
    }
    with open(artifact_path, "w", encoding="utf-8") as f:
        json.dump(artifact, f, ensure_ascii=False, indent=1)
        f.write("\n")
    current["artifactSha256"] = sha(artifact_path)
    with open(os.path.join(root, "current.json"), "w", encoding="utf-8") as f:
        json.dump(current, f, ensure_ascii=False, indent=1)
        f.write("\n")

    r = validate(root)
    if r.returncode != 0:
        fail("matching input rejected:\n" + r.stdout)

    manifest["titleId"] = "0100000000AAAAAA"
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
        f.write("\n")
    artifact["input"]["manifestSha256"] = sha(manifest_path)
    with open(artifact_path, "w", encoding="utf-8") as f:
        json.dump(artifact, f, ensure_ascii=False, indent=1)
        f.write("\n")
    current["artifactSha256"] = sha(artifact_path)
    with open(os.path.join(root, "current.json"), "w", encoding="utf-8") as f:
        json.dump(current, f, ensure_ascii=False, indent=1)
        f.write("\n")
    if validate(root).returncode == 0:
        fail("changed input titleId was accepted")

    manifest["titleId"] = artifact["titleId"]
    manifest["modules"][0]["buildId"] = "ff" * 20
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
        f.write("\n")
    artifact["input"]["manifestSha256"] = sha(manifest_path)
    with open(artifact_path, "w", encoding="utf-8") as f:
        json.dump(artifact, f, ensure_ascii=False, indent=1)
        f.write("\n")
    current["artifactSha256"] = sha(artifact_path)
    with open(os.path.join(root, "current.json"), "w", encoding="utf-8") as f:
        json.dump(current, f, ensure_ascii=False, indent=1)
        f.write("\n")
    if validate(root).returncode == 0:
        fail("changed input buildId was accepted")

    print("input identity: ok")


if __name__ == "__main__":
    main()
