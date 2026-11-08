#!/usr/bin/env python3
"""ELF start/stop-section red/green fixture; no Android runtime or guest execution."""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from audit import startup_roots, symbols


def run(command, *, success=True):
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if success is not None and (result.returncode == 0) != success:
        raise RuntimeError(f"unexpected exit {result.returncode}: {command}\n{result.stdout}\n{result.stderr}")
    return result


def check(cc, linker, nm, readelf, ar, target=None, lld_flavor_gnu=False):
    with tempfile.TemporaryDirectory(prefix="s2a-startup-roots-") as directory:
        root = Path(directory)
        modules = root / "modules.c"
        modules.write_text('__attribute__((used, section("__modules"), visibility("hidden")))\n'
                           'const void *module_pointer = (void *)1234;\n', encoding="utf-8")
        consumer = root / "bootstrap.c"
        consumer.write_text('extern char __start___modules[], __stop___modules[];\n'
                            'extern int s2a_handle_new(void);\n'
                            'unsigned long module_bytes(void) {\n'
                            ' return __stop___modules - __start___modules + s2a_handle_new();\n}\n', encoding="utf-8")
        provider = root / "s2a_native_stub.c"
        provider.write_text("int s2a_handle_new(void) { return 0; }\n", encoding="utf-8")
        compiler = [cc] + ([f"--target={target}"] if target else [])
        for source in (modules, consumer, provider):
            run(compiler + ["-fPIC", "-ffunction-sections", "-fdata-sections", "-c",
                            str(source), "-o", str(source.with_suffix(".o"))])
        inputs = root / "link.txt"
        inputs.write_text(str(consumer.with_suffix(".o")) + "\n", encoding="utf-8")
        link = [linker] + (["-flavor", "gnu"] if lld_flavor_gnu else [])
        link += ["-shared", "--gc-sections", str(modules.with_suffix(".o")),
                 str(consumer.with_suffix(".o")), str(provider.with_suffix(".o"))]
        # GNU ld may retain the first input section through its synthesized
        # roots, while LLD can discard it. Observe natural GC without assuming
        # that -z start-stop-gc guarantees an entirely missing output section.
        natural = root / "natural-gc.so"
        run(link + ["-z", "start-stop-gc", "-o", str(natural)])
        defined, undefined = symbols(nm, natural, include_local=True, include_all=True)
        natural_gc = startup_roots(nm, readelf, inputs, natural, defined, undefined)

        # Force the same real missing-section defect on both linkers. GNU ld's
        # default protected start/stop symbols otherwise prevent even the
        # non-strict negative artifact from being emitted. Default visibility
        # permits unresolved roots; it does not satisfy them or bypass audit.
        discard = root / "discard-modules.ld"
        discard.write_text("SECTIONS { /DISCARD/ : { *(__modules) } } INSERT AFTER .text;\n",
                           encoding="utf-8")
        bad_link = link + ["-T", str(discard), "-z", "start-stop-gc",
                           "-z", "start-stop-visibility=default"]
        strict = run(bad_link + ["-z", "defs", "-o", str(root / "strict.so")], success=False)
        required_roots = {"__start___modules", "__stop___modules"}
        if not all(name in strict.stdout + strict.stderr for name in required_roots):
            raise RuntimeError("strict link failed without identifying the missing startup roots")
        red = root / "red.so"
        run(bad_link + ["-o", str(red)])
        defined, undefined = symbols(nm, red, include_local=True, include_all=True)
        rejected = startup_roots(nm, readelf, inputs, red, defined, undefined)
        if (not required_roots <= undefined or required_roots & defined
                or rejected["sections"].get("__modules") is not None
                or not rejected["failures"]):
            raise RuntimeError("negative ELF must have no module section and unresolved startup roots")
        green = root / "green.so"
        run(link + ["-z", "nostart-stop-gc", "-z", "defs", "-o", str(green)])
        defined, undefined = symbols(nm, green, include_local=True, include_all=True)
        accepted = startup_roots(nm, readelf, inputs, green, defined, undefined)
        if accepted["failures"] or accepted["sections"]["__modules"]["bytes"] == 0:
            raise RuntimeError(f"retained section rejected: {accepted}")
        archive = root / "synthetic-managed.a"
        run([ar, "rcs", str(archive), str(consumer.with_suffix(".o"))])
        source_list = root / "sources.txt"
        source_list.write_text(str(provider) + "\n", encoding="utf-8")
        consumers = root / "managed-source"
        consumers.mkdir()
        (consumers / "Native.cs").write_text(
            'NativeLibrary.TryGetExport(program, "s2a_guest_tick", out nint tick);\n',
            encoding="utf-8")
        report = root / "audit.json"
        cli = [sys.executable, str(Path(__file__).with_name("audit.py")),
               "--archive", str(archive), "--source-list", str(source_list),
               "--source-root", str(root), "--consumer-root", str(consumers),
               "--nm", nm, "--link-input-list", str(inputs), "--readelf", readelf,
               "--report", str(report)]
        run(cli + ["--library", str(red)], success=False)
        red_result = json.loads(report.read_text(encoding="utf-8"))
        if (red_result["missing_direct_definitions"] or red_result["unresolved_direct_symbols"]
                or red_result["nativeaot_startup"]["failures"] != rejected["failures"]):
            raise RuntimeError(f"discarded-section ELF rejected for an unrelated failure: {red_result}")
        run(cli + ["--library", str(green)])
        result = json.loads(report.read_text(encoding="utf-8"))
        if not result["diagnostic_link_complete"] or result["game_ready"]:
            raise RuntimeError("CLI audit result did not preserve diagnostic-only scope")
        regressions = []
        rejected_cases = {}
        # Keep the real section but provide the wrong boundary values. Symbol
        # presence and a nonempty allocated section alone must not certify it.
        for name, start, stop in (("zero-roots", "0", "0"),
                                  ("reversed-roots", "module_pointer+8", "module_pointer"),
                                  ("short-roots", "module_pointer", "module_pointer+7")):
            library = root / f"{name}.so"
            run(link + ["-z", "defs", "-u", "module_pointer",
                        f"--defsym=__start___modules={start}",
                        f"--defsym=__stop___modules={stop}", "-o", str(library)])
            actual = run(cli + ["--library", str(library)], success=None)
            if actual.returncode == 0:
                regressions.append(f"audit accepted {name} despite incorrect section boundaries")
            else:
                failure = json.loads(report.read_text())
                rejected_cases[name] = failure["nativeaot_startup"]["failures"]
                if (failure["missing_direct_definitions"] or failure["unresolved_direct_symbols"]
                        or not any("boundary mismatch" in item for item in rejected_cases[name])):
                    raise RuntimeError(f"{name} rejected for an unrelated failure: {failure}")
        # Explicit absolute roots can be legitimate linker-script definitions;
        # exact section bounds, not a particular symbol binding, are the rule.
        absolute = root / "absolute-correct-roots.so"
        run(link + ["-z", "defs", "-u", "module_pointer",
                    "--section-start=__modules=0x50000",
                    "--defsym=__start___modules=0x50000",
                    "--defsym=__stop___modules=0x50008", "-o", str(absolute)])
        run(cli + ["--library", str(absolute)])
        wrong_name = root / "wrong-provider.c"
        wrong_name.write_text("int _s2a_handle_new(void) { return 0; }\n", encoding="utf-8")
        run(compiler + ["-fPIC", "-c", str(wrong_name), "-o", str(wrong_name.with_suffix(".o"))])
        library = root / "wrong-symbol-name.so"
        # This independently supplied library has only the wrong ELF spelling.
        # The audit must reject it for the archive's exact s2a_handle_new import.
        run([linker] + (["-flavor", "gnu"] if lld_flavor_gnu else []) +
            ["-shared", str(modules.with_suffix(".o")), str(wrong_name.with_suffix(".o")),
             "-u", "__start___modules", "-u", "__stop___modules", "-o", str(library)])
        actual = run(cli + ["--library", str(library)], success=None)
        if actual.returncode == 0:
            regressions.append("audit accepted _s2a_handle_new as the distinct ELF s2a_handle_new import")
        else:
            failure = json.loads(report.read_text())
            rejected_cases["wrong-symbol-name"] = failure["missing_direct_definitions"]
            if (rejected_cases["wrong-symbol-name"] != ["s2a_handle_new"]
                    or failure["nativeaot_startup"]["failures"] or failure["unresolved_direct_symbols"]):
                raise RuntimeError(f"wrong-symbol-name rejected for an unrelated failure: {failure}")
        if regressions:
            raise RuntimeError("\n".join(regressions))
        print(json.dumps({"fixture": "ELF start/stop section retention", "red": rejected["failures"],
                          "red_construction": "explicit module-section discard",
                          "natural_gc": {"sections": natural_gc["sections"],
                                         "failures": natural_gc["failures"]},
                          "green": accepted["sections"], "rejected_cases": rejected_cases,
                          "game_ready": False}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("cc", "linker", "nm", "readelf", "ar"):
        parser.add_argument(f"--{flag}", required=True)
    parser.add_argument("--target")
    parser.add_argument("--lld-flavor-gnu", action="store_true")
    check(**vars(parser.parse_args()))


if __name__ == "__main__":
    main()
