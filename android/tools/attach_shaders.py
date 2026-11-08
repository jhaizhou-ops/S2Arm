#!/usr/bin/env python3
"""Attach a prebuilt offline Vulkan shader pack to an existing Android resource package.

    attach_shaders.py <resource package> <shader pack dir>

<shader pack dir> is the producer's output root written by graphics/tools/shbake --vulkan-profile; it
holds exactly one vulkan/generic/<profileKey>/ (manifest.json, profile.json, shcache/). That
whole vulkan/ tree is copied into the package as shaders/vulkan/... (the tree the runtime
reads from the installed revision). The package's index.tsv, manifest.json and game-build-artifact.json
are rewritten in place, so the resource package stays a complete, self-consistent package;
the APK binding is unchanged (this tool never regroups modules or re-signs the APK).

Why this is separate from make_pack.py: the pack manifest names the game content root, and
the runtime computes that identity from the installed revision's index.tsv *without* the
shaders/ rows (ShaderPackLayout.GameContentRoot). The pack must therefore be built from the
package without shaders and attached afterwards; copying shaders/ in make_pack.py would
change the pack's own claimed identity.

The pack is refused when its manifest content root does not match the package, when the
package already contains shaders/ other than a verified direct library, or when any existing
file no longer matches the index. A package that already carries a direct (NVN -> Vulkan)
library is accepted only after the direct descriptor's file list, bytes, index rows and
identity fields are verified by direct_library.verify_pack; this is how one immutable revision
can carry both the generic pack and the direct library.
"""
import hashlib
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import direct_library   # noqa: E402  F5.2：直连库的文件清单/字节/身份规则只有这一份实现

MANIFEST = "manifest.json"
INDEX = "index.tsv"
ARTIFACT = "game-build-artifact.json"
DIRECT_FEATURE = direct_library.GRAPHICS_FEATURE


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 22), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_rows(package):
    with open(os.path.join(package, INDEX), "rb") as stream:
        raw = stream.read()
    rows = []
    for line in raw.decode("utf-8").splitlines():
        path, size, digest = line.split("\t")
        rows.append((path, int(size), digest))
    return rows, raw


def content_root(rows):
    """Same canonical identity as ShaderPackLayout.GameContentRoot."""
    text = "".join(f"{path}\t{size}\t{digest}\n" for path, size, digest in rows
                   if not path.startswith("shaders/"))
    return "sha256-" + sha256_bytes(text.encode("utf-8"))


def write_atomic(path, data):
    temporary = path + ".tmp"
    with open(temporary, "wb") as stream:
        stream.write(data)
    os.replace(temporary, path)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    package, pack = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    # <shader pack dir> is the producer's output root: it holds vulkan/generic/<profileKey>/.
    profiles = []
    generic = os.path.join(pack, "vulkan", "generic")
    if os.path.isdir(generic):
        profiles = [name for name in sorted(os.listdir(generic))
                    if os.path.isfile(os.path.join(generic, name, MANIFEST))]
    if len(profiles) != 1:
        sys.exit(f"{pack}: expected exactly one vulkan/generic/<profileKey>/manifest.json, found {len(profiles)}")
    profile = profiles[0]
    with open(os.path.join(package, MANIFEST), encoding="utf-8") as stream:
        manifest = json.load(stream)
    if manifest.get("version") != 2:
        sys.exit(f"{package}: manifest.json is not version 2")
    rows, _ = read_rows(package)
    if sha256_bytes(open(os.path.join(package, INDEX), "rb").read()) != manifest.get("index_sha256"):
        sys.exit(f"{package}: index.tsv does not match manifest.json")

    for path, size, digest in rows:
        full = os.path.join(package, path)
        if os.path.getsize(full) != size or sha256_file(full) != digest:
            sys.exit(f"{package}: {path} does not match index.tsv")

    existing_shaders = [path for path, _, _ in rows if path.startswith("shaders/")]
    if existing_shaders:
        # A direct library also lives under shaders/. Attaching the generic pack to a direct
        # package is allowed, but only to a package whose shaders/ rows are exactly the
        # descriptor's direct files: prove identity/bytes/index first, then refuse to mix in a
        # second generation of generic pack.
        with open(os.path.join(package, ARTIFACT), encoding="utf-8") as stream:
            existing_artifact = json.load(stream)
        if DIRECT_FEATURE not in (existing_artifact.get("requiredFeatures") or []):
            sys.exit(f"{package}: already contains shaders/; attach a pack to the original package")
        try:
            direct_library.verify_pack(package)
        except direct_library.LibraryError as error:
            sys.exit(f"{package}: {error}")
        foreign = [path for path in existing_shaders
                   if not path.startswith(direct_library.DIRECT_PREFIX)]
        if foreign:
            sys.exit(f"{package}: already contains {foreign[0]}; attach the generic pack to the "
                     f"original package instead (a revision carries one pack generation)")

    with open(os.path.join(generic, profile, MANIFEST), encoding="utf-8") as stream:
        pack_manifest = json.load(stream)
    if pack_manifest.get("schema") != "s2a-vulkan-pack-v1":
        sys.exit(f"{pack}: manifest.json is not an offline Vulkan pack")
    expected = content_root(rows)
    if pack_manifest.get("contentRoot") != expected:
        sys.exit(f"{pack}: pack content root {pack_manifest.get('contentRoot')} does not match "
                 f"this package ({expected}); build the pack from this package's index.tsv")

    added = []
    for directory, _, files in os.walk(os.path.join(pack, "vulkan")):
        for name in sorted(files):
            source = os.path.join(directory, name)
            relative = os.path.relpath(source, pack).replace(os.sep, "/")
            target_relative = "shaders/" + relative
            target = os.path.join(package, target_relative)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(source, target)
            added.append((target_relative, os.path.getsize(target), sha256_file(target)))

    # Keep the original row order: the runtime recomputes the pack's content root by dropping
    # the shaders/ rows, so re-sorting the game rows would change the identity they name.
    rows.extend(added)
    index = "".join(f"{path}\t{size}\t{digest}\n" for path, size, digest in rows)
    write_atomic(os.path.join(package, INDEX), index.encode("utf-8"))
    index_sha = sha256_bytes(index.encode("utf-8"))

    manifest.update({"files": len(rows), "total": sum(size for _, size, _ in rows), "index_sha256": index_sha})
    write_atomic(os.path.join(package, MANIFEST),
                 (json.dumps(manifest, indent=1) + "\n").encode("utf-8"))

    artifact_path = os.path.join(package, ARTIFACT)
    with open(artifact_path, encoding="utf-8") as stream:
        artifact = json.load(stream)
    artifact["contentRoot"] = "sha256-" + index_sha
    artifact["package"] = {"manifest": MANIFEST, "indexSha256": index_sha, "files": len(rows),
                           "bytes": sum(size for _, size, _ in rows)}
    write_atomic(artifact_path, (json.dumps(artifact, ensure_ascii=False, indent=1) + "\n").encode("utf-8"))

    if DIRECT_FEATURE in (artifact.get("requiredFeatures") or []):
        # The rewritten index must still name exactly the library the descriptor lists, and the
        # identity fields must still derive from it (shaders/ rows are excluded, so they do).
        try:
            direct_library.verify_pack(package)
        except direct_library.LibraryError as error:
            sys.exit(f"{package}: {error}")

    print(f"attached {len(added)} pack files ({sum(s for _, s, _ in added) >> 20} MiB) to {package}; "
          f"revision content root sha256-{index_sha[:19]}..., pack content root {expected}")


if __name__ == "__main__":
    main()
