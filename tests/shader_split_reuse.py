"""Gate for real NSO parsing reuse; the shell entry is shader_split_reuse_test.sh."""
import cProfile
import csv
import hashlib
import importlib
import os
from pathlib import Path
import pstats
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/shader_split_reuse"
SOURCE = Path(sys.argv[1]).resolve(strict=True)
assert hashlib.sha256((FIXTURE / "fixture.nso").read_bytes()).hexdigest() == "e9f6092a7b4ea5c02aff49100a8a121174a8f267612fd68baeaad12f9ce3bc78"
for key in ("DM_GLSLC_CAPTURE", "DM_UE_SHADERS", "DM_OODLE_JOB"):
    os.environ.pop(key, None)
os.environ["J"] = "1"
sys.path.insert(0, str(SOURCE.parent))


def arguments(output, romfs, mains):
    return [str(SOURCE), ",".join(map(str, romfs)), ",".join(map(str, mains)),
            str(output / "pkg"), *(str(output / f"{name}.tsv") for name in ("map", "facts", "pairs"))]


with tempfile.TemporaryDirectory(prefix="s2a-nso-reuse-") as temporary:
    root = Path(temporary)
    profile = root / "profile"
    profile.mkdir()
    shutil.copyfile(FIXTURE / "shader_split_reuse_profile.tsv", profile / "game.tsv")
    os.environ["DM_GAME"] = str(profile)
    split = importlib.import_module("shader_split")
    assert Path(split.__file__).resolve() == SOURCE
    main = root / "main"
    shutil.copyfile(FIXTURE / "fixture.nso", main)
    alias = root / "alias"
    alias.symlink_to(main)
    other = root / "other-main"
    shutil.copyfile(main, other)
    romfs = [root / name / "romfs" for name in ("first", "second", "third")]
    for path in romfs:
        path.mkdir(parents=True)

    for name, mains, expected in (("shared-and-alias", [main, main, alias], 1),
                                  ("distinct-file", [main, other, alias], 2)):
        output = root / name
        output.mkdir()
        sys.argv = arguments(output, romfs, mains)
        profiler = cProfile.Profile()
        profiler.runcall(split.main)
        calls = {}
        for (filename, _, function), (_, _, _, _, callers) in pstats.Stats(profiler).stats.items():
            if filename == str(SOURCE) and function in ("nso_image", "scan_blob", "glslc_shaders"):
                calls[function] = sum(value[1] for caller, value in callers.items()
                                      if caller[0] == str(SOURCE) and caller[2] == "main")
        assert calls == dict.fromkeys(("nso_image", "scan_blob", "glslc_shaders"), expected), calls
        # The C fixture contains ARM code and constants, with no GPU shader program.
        with (output / "map.tsv").open() as stream:
            rows = [row for row in csv.reader(stream, delimiter="\t") if row and not row[0].startswith("#")]
        assert rows == [["package", "index", "stage", "dm_ctl_sha16", "source"]], rows
        for table in ("facts", "pairs"):
            assert not [line for line in (output / f"{table}.tsv").read_text().splitlines()
                        if line and not line.startswith("#")]
        assert not list((output / "pkg").iterdir())
        print(f"PASS {name}: actual NSO/decode/scan calls {expected}")

    # A real C source placed in the wrong capture format must fail in the later root.
    capture = romfs[1].parent / "glslc_capture"
    capture.mkdir()
    (capture / "wrong-format.glslc").symlink_to(FIXTURE / "fixture.c")
    output = root / "bad-capture"
    output.mkdir()
    result = subprocess.run([sys.executable, *arguments(output, romfs, [main, main, alias])],
                            capture_output=True, text=True)
    assert result.returncode == 1, result
    assert result.stderr.strip() == "[RED] /glslc_capture/wrong-format.glslc: no GLSLC output", result.stderr
    assert not (output / "map.tsv").exists()
    print("PASS later-root invalid capture keeps its failure")

print("shader_split_reuse：真实 NSO 复用 / 别名 / 独立文件 / 后根错误全过")
