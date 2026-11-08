#!/bin/bash
# 原创临时 Git 仓：只测已提交路径，不读取真实宏语料，不运行 regen / GPU。
set -eu
cd "$(dirname "$0")/.."
python3 - "$PWD/graphics/gate.sh" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_bytes()
checks = 0
with tempfile.TemporaryDirectory(prefix="s2a-corpus-gate-") as temp:
    root = Path(temp)
    (root / "graphics").mkdir()
    (root / "graphics/gate.sh").write_bytes(source)
    corpus = root / "graphics/tools/macrogen/corpus/synthetic"
    corpus.mkdir(parents=True)
    macro = corpus / "original.mme"
    macro.write_text("ORIGINAL SYNTHETIC FIXTURE\n")
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("GATE_") or key.startswith("GIT_"):
            env.pop(key)
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_AUTHOR_NAME="Synthetic", GIT_AUTHOR_EMAIL="synthetic@example.invalid",
               GIT_COMMITTER_NAME="Synthetic", GIT_COMMITTER_EMAIL="synthetic@example.invalid")
    def git(*args):
        return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", *args],
                                       cwd=root, env=env, text=True, stderr=subprocess.STDOUT).strip()
    git("init", "-q")
    git("add", ".")
    git("commit", "-qm", "synthetic baseline")
    base = git("rev-parse", "HEAD")
    git("update-ref", "refs/remotes/origin/main", base)
    # Any accidental continuation into the actual GPU/regen gate is a failed test.
    guards = root / "guards"
    guards.mkdir()
    marker = root / "forbidden-call"
    for name in ("timeout", "make", "python3"):
        p = guards / name
        p.write_text('#!/bin/sh\nprintf forbidden > "$S2A_TEST_FORBIDDEN"\nexit 97\n')
        p.chmod(0o755)
    run_env = dict(env, PATH=str(guards) + os.pathsep + env["PATH"], S2A_TEST_FORBIDDEN=str(marker))
    def check(label, expected, changed=None):
        global checks
        e = dict(run_env)
        if changed is not None:
            e["GATE_CHANGED"] = changed
        r = subprocess.run(["bash", "graphics/gate.sh", "--check-macro-corpus"], cwd=root,
                           env=e, text=True, encoding="utf-8", capture_output=True, timeout=10)
        assert not marker.exists(), (label, "executed non-path gate")
        assert r.returncode == expected, (label, expected, r.returncode, r.stdout, r.stderr)
        assert "语料" in r.stdout + r.stderr, (label, "missing checker result")
        assert "unbound variable" not in r.stdout + r.stderr, (label, "shell error is not a rejection")
        if expected == 1:
            assert "宏语料检查：禁止新增或修改 " in r.stderr, (label, "missing actual guard rejection")
            assert "；语料请放仓库外目录，用 S2A_MACRO_CORPUS 指定" in r.stderr, (label, "missing recovery instruction")
        checks += 1
    def reset():
        git("reset", "--hard", base)
    check("unchanged tracked corpus is allowed", 0)
    (corpus / "untracked.mme").write_text("SYNTHETIC UNTRACKED\n")
    check("untracked corpus is outside committed range", 0)
    (corpus / "untracked.mme").unlink()
    macro.write_text("SYNTHETIC UNCOMMITTED EDIT\n")
    check("unstaged changes are outside committed range", 0)
    git("add", str(macro.relative_to(root)))
    check("staged changes are outside committed range", 0)
    git("commit", "-qm", "synthetic modification")
    check("committed modified macro", 1)
    check("CI supplied changed macro", 1, str(macro.relative_to(root)))
    check("explicit empty changed set", 0, "")
    check("supplied base excludes older macro change", 0, "notes.txt")
    reset()
    new = corpus / "new.mme"
    new.write_text("SYNTHETIC NEW\n")
    git("add", str(new.relative_to(root)))
    git("commit", "-qm", "synthetic addition")
    check("committed new macro", 1)
    for name in ("space name.mme", "tab\tname.mme", 'quote"name.mme', "line\nname.mme"):
        reset()
        special = corpus / name
        special.write_text("SYNTHETIC SPECIAL NAME\n")
        git("add", str(special.relative_to(root)))
        git("commit", "-qm", "synthetic special name")
        check("special filename fallback: " + repr(name), 1)
        changed = git("-c", "core.quotepath=off", "diff", "--name-only", base, "HEAD").replace("\n", " ")
        check("special filename CI: " + repr(name), 1, changed)
    reset()
    git("rm", str(macro.relative_to(root)))
    git("commit", "-qm", "synthetic deletion")
    check("committed deletion", 0)
    check("CI deletion path still listed", 0, str(macro.relative_to(root)))
    reset()
    (root / "notes.txt").write_text("SYNTHETIC NON-MACRO\n")
    git("add", "notes.txt")
    git("commit", "-qm", "non macro change")
    check("non macro change", 0)
    # Another branch's already-merged addition must not contaminate this branch's diff.
    branch = git("symbolic-ref", "--short", "HEAD")
    git("checkout", "-qb", "other", base)
    (corpus / "upstream.mme").write_text("SYNTHETIC UPSTREAM\n")
    git("add", ".")
    git("commit", "-qm", "other upstream change")
    git("update-ref", "refs/remotes/origin/main", git("rev-parse", "HEAD"))
    git("checkout", "-q", branch)
    check("merge-base excludes unrelated upstream changes", 0)
    git("update-ref", "-d", "refs/remotes/origin/main")
    check("provided changed set needs no origin ref", 0, "notes.txt")
    check("missing fallback base cannot silently pass", 2)
print(f"扫描器阻止 .mme 进仓 → {checks} 项合成 Git 检查通过")
PY
