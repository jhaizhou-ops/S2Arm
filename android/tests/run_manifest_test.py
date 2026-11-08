#!/usr/bin/env python3
"""Negative checks for run-manifest v1: missing identity, bad paths, capabilities."""
import copy
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONTRACTS = HERE.parent / "contracts"
sys.path.insert(0, str(CONTRACTS))
import validate  # noqa: E402


class RunManifestTest(unittest.TestCase):
    def setUp(self):
        self.schema = json.loads((CONTRACTS / "run-manifest.v1.schema.json").read_text())
        self.sample = json.loads((CONTRACTS / "samples" / "run-manifest.json").read_text())

    def rejected(self, mutate, message):
        doc = copy.deepcopy(self.sample)
        mutate(doc)
        with self.assertRaises(validate.Invalid) as caught:
            validate.check_document(doc, self.schema, "run-manifest.json")
        self.assertIn(message, str(caught.exception))

    def test_valid_sample(self):
        validate.check_document(self.sample, self.schema, "run-manifest.json")

    def test_missing_artifact(self):
        self.rejected(lambda d: d.pop("artifact"), "required")

    def test_bad_build_id(self):
        self.rejected(lambda d: d["modules"][0].update(buildId="not-hex"), "does not match")

    def test_reference_traversal(self):
        self.rejected(lambda d: d["references"].update(shots="../outside"), "does not match")

    def test_duplicate_module(self):
        self.rejected(lambda d: d["modules"].append(dict(d["modules"][0])), "duplicate")

    def test_unknown_required_feature(self):
        self.rejected(lambda d: d.update(requiredFeatures=["org.example.gpu.v1"]),
                      "unsupported required feature")

    def test_bad_page_size(self):
        self.rejected(lambda d: d["device"].update(pageSize=4096 + 1), "not in")


if __name__ == "__main__":
    unittest.main()
