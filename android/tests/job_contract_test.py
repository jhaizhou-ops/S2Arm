#!/usr/bin/env python3
"""Negative checks for the local job request/event v1 protocol."""
import copy
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONTRACTS = HERE.parent / "contracts"
sys.path.insert(0, str(CONTRACTS))
import validate  # noqa: E402


class JobContractTest(unittest.TestCase):
    def setUp(self):
        self.request_schema = json.loads((CONTRACTS / "job-request.v1.schema.json").read_text())
        self.event_schema = json.loads((CONTRACTS / "job-event.v1.schema.json").read_text())
        self.request = json.loads((CONTRACTS / "samples" / "job-request.json").read_text())
        self.event = json.loads((CONTRACTS / "samples" / "job-event.json").read_text())

    def rejected(self, schema, doc, message):
        with self.assertRaises(validate.Invalid) as caught:
            validate.check_document(doc, schema, "job")
        self.assertIn(message, str(caught.exception))

    def test_valid_samples(self):
        validate.check_document(self.request, self.request_schema, "job-request")
        validate.check_document(self.event, self.event_schema, "job-event")

    def test_missing_operation(self):
        doc = copy.deepcopy(self.request)
        doc.pop("operation")
        self.rejected(self.request_schema, doc, "required")

    def test_unknown_operation(self):
        doc = copy.deepcopy(self.request)
        doc["operation"] = "run-everything"
        self.rejected(self.request_schema, doc, "not in")

    def test_relative_private_root(self):
        doc = copy.deepcopy(self.request)
        doc["privateRoot"] = "relative/path"
        self.rejected(self.request_schema, doc, "does not match")

    def test_unknown_event_type(self):
        doc = copy.deepcopy(self.event)
        doc["type"] = "telemetry"
        self.rejected(self.event_schema, doc, "not in")

    def test_bad_sequence(self):
        doc = copy.deepcopy(self.event)
        doc["seq"] = 0
        self.rejected(self.event_schema, doc, "minimum")

    def test_bad_timestamp(self):
        doc = copy.deepcopy(self.event)
        doc["timestamp"] = "2026-10-23 09:00:00"
        self.rejected(self.event_schema, doc, "does not match")

    def test_job_id_alias_must_match(self):
        request = copy.deepcopy(self.request)
        request["jobId"] = "different-job"
        with self.assertRaises(validate.Invalid):
            validate.check_job_pair(request, self.event)


if __name__ == "__main__":
    unittest.main()
