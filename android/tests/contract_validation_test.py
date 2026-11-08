#!/usr/bin/env python3
"""Contract regressions through the sample and installed-game CLI entry points."""
import copy
import hashlib
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CONTRACTS = Path(__file__).resolve().parents[1] / "contracts"
FILES = {
    "input": "game-input-manifest.json",
    "artifact": "game-build-artifact.json",
    "current": "current.json",
    "boot": "boot-spec.json",
}


class ContractValidationTest(unittest.TestCase):
    def setUp(self):
        self.docs = {
            key: json.loads((CONTRACTS / "samples" / name).read_text())
            for key, name in FILES.items()
        }

    def test_package_schema_exact_suffix(self):
        schema = json.loads((CONTRACTS / 'game-build-artifact.v1.schema.json').read_text())
        pattern = schema['properties']['apk']['properties']['packageName']['pattern']
        base = 'org.s2arm.game.t0100000000abcdef'
        for suffix in ('', '.w2'):
            self.assertIsNotNone(re.search(pattern, base + suffix))
        for suffix in ('.foo', '.w2.extra', '.W2', '\n', '.w2\n'):
            self.assertIsNone(re.search(pattern, base + suffix), repr(suffix))

    def test_debug_suffix_structure_preserves_title(self):
        for game in (False, True):
            docs = copy.deepcopy(self.docs)
            docs['artifact']['apk']['packageName'] += '.w2'
            result = self.validate(docs, game)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for package in ('org.s2arm.game.t0100000000000001.w2',
                        'org.s2arm.game.t0100000000abcdef.foo',
                        'org.s2arm.game.t0100000000abcdef.w2.extra',
                        'org.s2arm.game.t0100000000abcdef.W2',
                        'org.s2arm.game.t0100000000abcdef..w2',
                        'org.s2arm.game.t0100000000abcdef.2w',
                        'org.s2arm.game.t0100000000abcdef.w2;bad'):
            docs = copy.deepcopy(self.docs)
            docs['artifact']['apk']['packageName'] = package
            self.assert_rejected(docs, 'packageName')

    def validate(self, docs, game=False, rebind=True):
        docs = copy.deepcopy(docs)
        with tempfile.TemporaryDirectory(prefix="s2arm-contract-test-") as tmp:
            root = Path(tmp)
            if game:
                root /= docs["current"]["titleId"]
                content = root / docs["current"]["revisionDir"]
            else:
                content = root
            content.mkdir(parents=True, exist_ok=True)
            manifest = content / FILES["input"]
            manifest.write_text(json.dumps(docs["input"]), encoding="utf-8")
            if rebind:
                docs["artifact"]["input"]["manifestSha256"] = hashlib.sha256(manifest.read_bytes()).hexdigest()
            artifact = content / FILES["artifact"]
            artifact.write_text(json.dumps(docs["artifact"]), encoding="utf-8")
            artifact_sha = hashlib.sha256(artifact.read_bytes()).hexdigest()
            docs["current"]["artifactSha256"] = artifact_sha
            docs["boot"]["artifactSha256"] = artifact_sha
            (root / FILES["current"]).write_text(json.dumps(docs["current"]), encoding="utf-8")
            (root / FILES["boot"]).write_text(json.dumps(docs["boot"]), encoding="utf-8")
            args = ["--game", str(root)] if game else [str(root)]
            return subprocess.run([sys.executable, str(CONTRACTS / "validate.py"), *args],
                                  capture_output=True, text=True)

    def assert_rejected(self, docs, message, rebind=True):
        for game in (False, True):
            with self.subTest(installed_game=game):
                result = self.validate(docs, game, rebind)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(message, result.stdout)

    def test_matching_static_modules(self):
        for game in (False, True):
            result = self.validate(self.docs, game)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_changed_input_without_rebinding_fails_sample_gate(self):
        self.docs["input"]["titleId"] = "0100000000000000"
        self.assert_rejected(self.docs, "manifestSha256", rebind=False)

    def test_rebound_input_title_still_must_match(self):
        self.docs["input"]["titleId"] = "0100000000000000"
        self.assert_rejected(self.docs, "titleId")

    def test_renamed_input_module(self):
        self.docs["input"]["modules"][0]["name"] = "other"
        self.assert_rejected(self.docs, "module names differ")

    def test_extra_artifact_module(self):
        module = copy.deepcopy(self.docs["artifact"]["modules"][0])
        module.update(name="other", image="other.patched.bin", fixups="other.fixups.tsv",
                      gates="other.gates.tsv")
        self.docs["artifact"]["modules"].insert(1, module)   # 「other」按 Horizon 序在 main 与 sdk 之间：走到名字比对
        self.assert_rejected(self.docs, "module names differ")

    def test_artifact_modules_out_of_load_order(self):
        self.docs["artifact"]["modules"].reverse()   # [sdk, main]：装载顺序错，名字集合不变
        self.assert_rejected(self.docs, "Horizon load order")

    def test_artifact_modules_sdk_before_subsdk_is_old_pack(self):
        for name in ("subsdk0", "subsdk10", "rtld"):
            with self.subTest(extra=name):
                docs = copy.deepcopy(self.docs)
                extra = copy.deepcopy(docs["artifact"]["modules"][0])
                extra.update(name=name, image=f"{name}.patched.bin", fixups=f"{name}.fixups.tsv",
                             gates=f"{name}.gates.tsv")
                docs["artifact"]["modules"].append(extra)
                src = copy.deepcopy(docs["input"]["modules"][1]); src["name"] = name
                docs["input"]["modules"].append(src)
                self.assert_rejected(docs, "Horizon load order")   # 旧字母序包 [main, sdk, subsdk*] 必须拒收

    def test_missing_artifact_build_id_does_not_disable_binding(self):
        self.docs["artifact"]["modules"][0].pop("buildId")
        self.docs["input"]["modules"][0]["buildId"] = "f" * 40
        self.assert_rejected(self.docs, "buildId")

    def test_changed_build_id(self):
        self.docs["input"]["modules"][0]["buildId"] = "f" * 40
        self.assert_rejected(self.docs, "buildId")

    def test_duplicate_module_names(self):
        for key in ("input", "artifact"):
            with self.subTest(document=key):
                docs = copy.deepcopy(self.docs)
                docs[key]["modules"].append(copy.deepcopy(docs[key]["modules"][0]))
                self.assert_rejected(docs, "duplicate module")

    def test_loader_sidecar_paths_must_match(self):
        for key, value in (("fixups", "approved.fixups.tsv"),
                           ("fixups", "nested/main.fixups.tsv"),
                           ("gates", "approved.gates.tsv")):
            with self.subTest(field=key, path=value):
                docs = copy.deepcopy(self.docs)
                docs["artifact"]["modules"][0][key] = value
                self.assert_rejected(docs, f"{key} must be")

    def test_unknown_optional_metadata_is_compatible(self):
        for doc in self.docs.values():
            doc["extensions"] = {"org.example.build": {"newField": {"anything": [1, True]}}}
            doc["requiredFeatures"] = []
        for game in (False, True):
            result = self.validate(self.docs, game)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unknown_required_features_are_rejected(self):
        for key in FILES:
            with self.subTest(document=key):
                docs = copy.deepcopy(self.docs)
                docs[key]["requiredFeatures"] = ["org.example.gpu.v1"]
                result = self.validate(docs)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("unsupported required feature", result.stdout)
                if key != "boot":
                    result = self.validate(docs, game=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("unsupported required feature", result.stdout)

    def test_invalid_extension_envelope(self):
        for value in ({"unqualified": {}}, {"org.example.build": 1}):
            docs = copy.deepcopy(self.docs)
            docs["artifact"]["extensions"] = value
            for game in (False, True):
                result = self.validate(docs, game)
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_features_are_unique_namespaced_strings(self):
        for features in (["plain"], [1], ["org.example.gpu.v1", "org.example.gpu.v1"]):
            docs = copy.deepcopy(self.docs)
            docs["artifact"]["requiredFeatures"] = features
            self.assert_rejected(docs, "FAILED")

    def test_core_fields_and_versions_remain_closed(self):
        for key in FILES:
            for field, value in (("unrecognizedCoreField", 1), ("version", 2)):
                with self.subTest(document=key, field=field):
                    docs = copy.deepcopy(self.docs)
                    docs[key][field] = value
                    result = self.validate(docs)
                    self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_runtime_library_is_a_closed_structured_record(self):
        dev = {"kind": "dev-override", "sha256": "1a" * 32, "baseApkSha256": "2b" * 32, "sourceCommit": "3c" * 20,
               "dirty": False, "diffSha256": "4d" * 32, "ilcConfig": "Release", "aotHost": "linux-arm64"}
        for value in ({"kind": "apk"}, dev):
            with self.subTest(accepted=value["kind"]):
                docs = copy.deepcopy(self.docs)
                docs["boot"].setdefault("diagnostics", {})["runtimeLibrary"] = value
                self.assertEqual(self.validate(docs).returncode, 0)
        missing = {k: v for k, v in dev.items() if k != "baseApkSha256"}
        for value in ("runtime-library: apk", {"kind": "dev"}, {"kind": "apk", "sha256": "1a" * 32}, missing,
                      {**dev, "dirty": "false"}, {**dev, "sha256": "1A" * 32}, {**dev, "aotHost": "osx-arm64"}):
            with self.subTest(rejected=value):
                docs = copy.deepcopy(self.docs)
                docs["boot"].setdefault("diagnostics", {})["runtimeLibrary"] = value
                self.assertNotEqual(self.validate(docs).returncode, 0)


if __name__ == "__main__":
    unittest.main()
