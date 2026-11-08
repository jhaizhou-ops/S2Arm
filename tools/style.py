#!/usr/bin/env python3
"""Format and lint first-party changes; historical debt stays visible but non-blocking."""

import argparse
import difflib
import importlib.metadata
import json
import os
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path
from urllib.parse import unquote, urlsplit

from markdown_it import MarkdownIt

ROOT = Path(__file__).resolve().parents[1]
TOOLS = json.loads((ROOT / "tools/style-tools.json").read_text(encoding="utf-8"))
EXCLUDED = ("compat/tree/", "compat/packages/", "graphics/third_party/")
GENERATED = {".git", "build", "bin", "obj", "__pycache__", ".venv", ".ruff_cache"}
C_EXTENSIONS = {".c", ".h", ".cc", ".cpp", ".hpp", ".m", ".mm"}


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, check=True, stdout=subprocess.PIPE).stdout


def run(command, source=None, cwd=ROOT, allowed=(0,)):
    result = subprocess.run(command, input=source, cwd=cwd, capture_output=True)
    if result.returncode not in allowed:
        sys.stderr.write(result.stderr.decode("utf-8"))
        sys.stderr.write(result.stdout.decode("utf-8"))
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(map(str, command))}")
    return result.stdout


def executable(name):
    path = Path(sys.executable).parent / name
    if not path.is_file():
        raise FileNotFoundError(f"missing {path}; run make style-setup")
    return str(path)


def check_tools():
    minimum = tuple(map(int, TOOLS["python_min"].split(".")))
    if sys.version_info[:2] < minimum:
        raise RuntimeError(f"Python >= {TOOLS['python_min']} required")
    for package, expected in TOOLS["python_packages"].items():
        actual = importlib.metadata.version(package)
        if actual != expected:
            raise RuntimeError(
                f"{package}: expected {expected}, got {actual}; run make style-setup"
            )


def eligible(path):
    return (
        not path.startswith(EXCLUDED)
        and not (set(Path(path).parts) & GENERATED)
        and not path.endswith((".g.cs", ".generated.cs"))
    )


def names(data):
    return [os.fsdecode(part) for part in data.split(b"\0") if part]


def select_files(args):
    base = "HEAD" if args.staged else git("merge-base", args.base, "HEAD").decode().strip()
    if args.staged:
        selected = names(git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"))
    elif args.all:
        selected = names(git("ls-files", "--cached", "--others", "--exclude-standard", "-z"))
    else:
        selected = names(git("diff", base, "--name-only", "--diff-filter=ACMR", "-z"))
        selected += names(git("ls-files", "--others", "--exclude-standard", "-z"))
    if args.files:
        selected = args.files
    result = []
    for name in sorted(set(selected)):
        path = Path(os.path.abspath(ROOT / name))
        if not path.is_relative_to(ROOT):
            raise ValueError(f"path is outside repository: {name}")
        relative = path.relative_to(ROOT).as_posix()
        if not eligible(relative):
            continue
        if args.staged:
            mode = git("ls-files", "--format=%(objectmode)", "--", relative).decode().strip()
            if mode in {"100644", "100755"}:
                result.append(relative)
        elif path.is_file() and path.resolve().is_relative_to(ROOT) and not path.is_symlink():
            if eligible(path.resolve().relative_to(ROOT).as_posix()):
                result.append(relative)
        elif args.files:
            raise ValueError(f"not a regular first-party file: {name}")
    return base, result


def check_staged_policy():
    paths = [
        ".editorconfig",
        ".clang-format",
        "ruff.toml",
        "tools/style.py",
        "tools/style-tools.json",
        "tools/style-requirements.in",
        "tools/style-requirements.txt",
        "tools/check_log_schema.py",
        "docs/standards/log-events.json",
        "docs/standards/log-event.schema.json",
    ]
    for path in paths:
        indexed = bool(git("ls-files", "-z", "--", path))
        working = (ROOT / path).is_file()
        if indexed != working or (
            indexed and git("show", f":{path}") != (ROOT / path).read_bytes()
        ):
            raise RuntimeError(f"{path}: stage policy changes before checking --staged")


def baseline(path, ref):
    entry = git("ls-tree", "-z", ref, "--", path)
    if not entry:
        return None
    return git("show", f"{ref}:{path}")


def renamed_paths(ref, staged):
    options = ["--cached"] if staged else [ref]
    fields = iter(
        names(git("diff", *options, "--find-renames", "--name-status", "-z", "--diff-filter=R"))
    )
    result = {}
    for _status in fields:
        old, new = next(fields), next(fields)
        if Path(old).suffix == Path(new).suffix:
            result[new] = old
    return result


def reference_exists(path, ref):
    if not path.is_relative_to(ROOT):
        return False
    relative = path.relative_to(ROOT).as_posix()
    if ref == ":":
        return bool(git("ls-files", "-z", "--", relative))
    if ref is not None:
        return bool(git("ls-tree", "-z", ref, "--", relative))
    return path.exists()


def changed_lines(before, after):
    if before is None:
        return None
    old = before.decode("utf-8").splitlines(keepends=True)
    new = after.decode("utf-8").splitlines(keepends=True)
    touched = set()
    for tag, _, _, start, end in difflib.SequenceMatcher(
        None, old, new, autojunk=False
    ).get_opcodes():
        if tag != "equal":
            touched.update(range(start + 1, end + 1))
            if start == end:
                touched.update((max(1, start), start + 1))
    return touched


def touches(start, end, changed):
    return changed is None or bool(set(range(start, end + 1)) & changed)


def format_source(path, source):
    suffix = Path(path).suffix
    if suffix in C_EXTENSIONS:
        return run(
            [
                executable("clang-format"),
                f"--style=file:{ROOT / '.clang-format'}",
                f"--assume-filename={ROOT / path}",
            ],
            source,
        )
    if suffix == ".py":
        return run(
            [
                executable("ruff"),
                "format",
                "--config",
                str(ROOT / "ruff.toml"),
                "--stdin-filename",
                path,
                "-",
            ],
            source,
        )
    if suffix == ".sh":
        return run([executable("shfmt"), "-i", "2", "-ci", "-bn", "-filename", path], source)
    if suffix == ".cs":
        with tempfile.TemporaryDirectory(prefix="s2arm-csharp-") as directory:
            workspace = Path(directory)
            target = workspace / path
            target.parent.mkdir(parents=True)
            target.write_bytes(source)
            (workspace / ".editorconfig").write_bytes((ROOT / ".editorconfig").read_bytes())
            (workspace / "global.json").write_text(
                json.dumps({"sdk": {"version": TOOLS["dotnet_sdk"], "rollForward": "disable"}}),
                encoding="utf-8",
            )
            actual = run(["dotnet", "--version"], cwd=workspace).decode().strip()
            if actual != TOOLS["dotnet_sdk"]:
                raise RuntimeError(f"expected .NET SDK {TOOLS['dotnet_sdk']}, got {actual}")
            run(
                [
                    "dotnet",
                    "format",
                    "whitespace",
                    str(workspace),
                    "--folder",
                    "--include",
                    path,
                    "--verbosity",
                    "quiet",
                ],
                cwd=workspace,
            )
            return target.read_bytes()
    return source


def format_errors(path, source, formatted, changed):
    original = source.decode("utf-8").splitlines(keepends=True)
    result = formatted.decode("utf-8").splitlines(keepends=True)
    errors = []
    for tag, start, end, _, _ in difflib.SequenceMatcher(
        None, original, result, autojunk=False
    ).get_opcodes():
        if tag != "equal" and touches(start + 1, max(start + 1, end), changed):
            errors.append(f"{path}:{start + 1}: formatting differs; run make format")
    return errors


def diagnostics(path, source, ref=None):
    suffix = Path(path).suffix
    if suffix == ".py":
        result = json.loads(
            run(
                [
                    executable("ruff"),
                    "check",
                    "--no-cache",
                    "--config",
                    str(ROOT / "ruff.toml"),
                    "--output-format",
                    "json",
                    "--stdin-filename",
                    path,
                    "-",
                ],
                source,
                allowed=(0, 1),
            )
        )
        return [
            (item["location"]["row"], item["end_location"]["row"], item["code"], item["message"])
            for item in result
        ]
    if suffix == ".sh":
        result = json.loads(
            run(
                [executable("shellcheck"), "--norc", "--format=json", "-"],
                source,
                allowed=(0, 1),
            )
        )
        return [
            (item["line"], item["endLine"], f"SC{item['code']}", item["message"]) for item in result
        ]
    if suffix == ".md":
        errors = []
        for token in MarkdownIt().parse(source.decode("utf-8")):
            for child in token.children or []:
                if child.type not in {"link_open", "image"}:
                    continue
                href = child.attrGet("href" if child.type == "link_open" else "src")
                link = urlsplit(href)
                if link.scheme or link.netloc or not link.path:
                    continue
                target = Path(os.path.abspath(ROOT / Path(path).parent / unquote(link.path)))
                if ref is None:
                    target = target.resolve()
                if not reference_exists(target, ref):
                    row = token.map[0] + 1
                    errors.append((row, token.map[1], "MDLINK", f"missing local target: {href}"))
        return errors
    return []


def lint_errors(path, source, before, changed, old_path=None, old_ref=None, ref=None):
    lines = source.decode("utf-8").splitlines()

    def signature(item, content):
        start, end, code, message = item
        return code, message, tuple(line.strip() for line in content[start - 1 : end])

    previous = Counter()
    if before is not None:
        old_lines = before.decode("utf-8").splitlines()
        previous.update(
            signature(item, old_lines) for item in diagnostics(old_path or path, before, old_ref)
        )
    errors = []
    for item in diagnostics(path, source, ref):
        start, end, code, message = item
        key = signature(item, lines)
        inherited = previous[key] > 0
        previous[key] -= 1
        if not inherited or touches(start, end, changed):
            errors.append(f"{path}:{start}: {code}: {message}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("format", "check", "lint"))
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument(
        "--base", default="origin/main", help="compare with merge-base (default: origin/main)"
    )
    selection.add_argument("--staged", action="store_true", help="check index content against HEAD")
    parser.add_argument("--files", nargs="+", help="limit to these repository-relative files")
    parser.add_argument(
        "--all", action="store_true", help="check whole selected files, including historical debt"
    )
    args = parser.parse_args()
    if args.mode == "format" and args.staged:
        parser.error("format writes working files; --staged is only supported by check and lint")
    check_tools()
    if args.staged:
        check_staged_policy()
    base, files = select_files(args)
    renamed = renamed_paths(base, args.staged)
    if args.mode == "lint" and not args.files:
        # A removed target can break an unchanged Markdown link.
        candidates = names(git("ls-files", "-z"))
        files += [
            path
            for path in candidates
            if path.endswith(".md")
            and eligible(path)
            and path not in files
            and (args.staged or (ROOT / path).is_file())
        ]
    errors = []
    for path in files:
        source = git("show", f":{path}") if args.staged else (ROOT / path).read_bytes()
        suffix = Path(path).suffix
        if suffix not in C_EXTENSIONS | {".cs", ".py", ".sh", ".md"}:
            continue
        old_path = renamed.get(path, path)
        before = baseline(old_path, base)
        changed = None if args.all else changed_lines(before, source)
        if args.mode in {"format", "check"}:
            formatted = format_source(path, source)
            if args.mode == "format" and formatted != source:
                (ROOT / path).write_bytes(formatted)
                print(f"formatted {path}")
            else:
                errors.extend(format_errors(path, source, formatted, changed))
        else:
            errors.extend(
                lint_errors(
                    path, source, before, changed, old_path, base, ":" if args.staged else None
                )
            )
    for error in errors:
        print(error, file=sys.stderr)
    if args.mode == "lint":
        command = [sys.executable, str(ROOT / "tools/check_log_schema.py")]
        if args.staged:
            command.append("--staged")
        print(run(command).decode("utf-8").strip())
    print(f"style {args.mode}: {len(files)} selected files, {len(errors)} violations")
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
