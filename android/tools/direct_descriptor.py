#!/usr/bin/env python3
"""Generate shaders/vulkan/direct/graphics.v1.json from the ACTUAL compiler identity.

Why this tool exists: the descriptor's translatorClosure must equal the closure of the
compiler baked into the APK. Hand-editing an old descriptor to a new closure is forbidden
(it would make old artifacts pretend to be new). Identity is read from the compiler itself
(`cli identity` -> s2a-direct-identity-v1), never from the git revision or build time.

    direct_descriptor.py --identity identity.json --old old_graphics.v1.json --out new.json

The emitted descriptor keeps gameContentRoot / moduleSetDigest / titleId / ABI fields from
the previous descriptor (content facts, not compiler facts) and replaces only
translatorClosure (and runtimeCompilerABI if it changed). It refuses when the identity file
is not the expected schema, so a stale or fabricated identity cannot slip through.
"""
import argparse, json, sys

CLOSURE_PREFIX = "s2a-dc1-"


def load_identity(path):
    doc = json.load(open(path, encoding="utf-8"))
    if doc.get("schema") != "s2a-direct-identity-v1":
        raise SystemExit(f"identity {path}: schema {doc.get('schema')!r} is not s2a-direct-identity-v1")
    closure = doc.get("translatorClosure", "")
    if not (isinstance(closure, str) and closure.startswith(CLOSURE_PREFIX) and len(closure) == len(CLOSURE_PREFIX) + 64):
        raise SystemExit(f"identity {path}: translatorClosure {closure!r} is not {CLOSURE_PREFIX}<64 hex>")
    abi = doc.get("compilerABI")
    if not isinstance(abi, str) or not abi:
        raise SystemExit(f"identity {path}: compilerABI missing")
    return closure, abi


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--identity", required=True, help="output of `cli identity` (s2a-direct-identity-v1)")
    ap.add_argument("--old", required=True, help="existing graphics.v1.json (content facts come from here)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    closure, compiler_abi = load_identity(args.identity)
    doc = json.load(open(args.old, encoding="utf-8"))
    if doc.get("schema") != "s2a-graphics-v1":
        raise SystemExit(f"{args.old}: schema {doc.get('schema')!r} is not s2a-graphics-v1")
    before = doc.get("translatorClosure")
    doc["translatorClosure"] = closure
    doc["runtimeCompilerABI"] = compiler_abi
    # 离线库内容与编译器身份绑定：身份变了就不能继续声明旧条目。
    doc["profiles"] = []
    doc["files"] = []
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1, sort_keys=False)
        f.write("\n")
    print(f"descriptor: {args.out}")
    print(f"  translatorClosure: {before} -> {closure}")
    print(f"  runtimeCompilerABI: {compiler_abi}")
    print(f"  profiles/files: 0/0 (compiler identity changed: old offline entries must not be claimed)")


if __name__ == "__main__":
    sys.exit(main())
