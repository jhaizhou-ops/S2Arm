"""Canonical content fingerprint shared by future artifact producers/consumers.

Callers supply hashes of verified delivered bytes, never source/stage keys.
This module does not read artifacts, normalize signatures, or schedule jobs.
"""
from __future__ import annotations

import hashlib
import json


def content_fingerprint(executable_sha256, resource_index_sha256, pipeline_archives):
    archives = sorted((dict(item) for item in pipeline_archives), key=lambda item: item["path"])
    if len({item["path"] for item in archives}) != len(archives):
        raise ValueError("fingerprint: 管线归档路径重复。")
    components = dict(executableSha256=executable_sha256, resourceIndexSha256=resource_index_sha256,
                      pipelineArchives=archives)
    payload = dict(schema="s2a.content-fingerprint.v1", components=components)
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return payload | {"value": hashlib.sha256(raw).hexdigest()}
