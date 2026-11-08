#!/usr/bin/env python3
"""Validate S2Arm's JSON Schema subset using only the Python standard library."""
from __future__ import annotations

import argparse
import datetime
from functools import lru_cache
import json
import math
from pathlib import Path
import re
import sys
from urllib.parse import unquote

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))


SCHEMAS = {
    "request": "job-request.v1.schema.json",
    "event": "job-event.v1.schema.json",
    "artifact": "artifact.v2.schema.json",
    "target": "target.v1.schema.json",
}


class ContractError(ValueError):
    """A contract mismatch; messages identify fields and never echo their values."""


class _Mismatch(ContractError):
    pass


KEYWORDS = {
    "$schema", "$id", "$ref", "$defs", "title", "description", "$comment",
    "type", "required", "properties", "additionalProperties", "enum", "const",
    "pattern", "minLength", "minimum", "minItems", "items", "format", "allOf", "if", "then",
}


def _audit(schema):
    # Schema changes must not silently add constraints this validator ignores.
    if isinstance(schema, bool):
        return
    if not isinstance(schema, dict) or set(schema) - KEYWORDS:
        raise ContractError("契约 schema 含不支持的校验关键字。")
    if "format" in schema and schema["format"] != "date-time":
        raise ContractError("契约 schema 含不支持的 format。")
    for key in ("properties", "$defs"):
        for child in schema.get(key, {}).values():
            _audit(child)
    for key in ("items", "additionalProperties", "if", "then"):
        if key in schema:
            _audit(schema[key])
    for child in schema.get("allOf", []):
        _audit(child)


@lru_cache(maxsize=1)
def validators():
    documents = {kind: json.loads(Path(__file__).with_name(name).read_text()) for kind, name in SCHEMAS.items()}
    for schema in documents.values():
        _audit(schema)
    return documents


def _resolve(reference, root, documents):
    # Only registered local IDs and JSON Pointer fragments; never fetch a URI.
    identifier, _, fragment = reference.partition("#")
    target = next((s for s in documents.values() if s.get("$id") == identifier), None) if identifier else root
    if target is None or (fragment and not fragment.startswith("/")):
        raise ContractError("契约 $ref 不是已登记的本地 schema。")
    try:
        for part in unquote(fragment).split("/")[1:]:
            target = target[part.replace("~1", "/").replace("~0", "~")]
    except (KeyError, TypeError) as error:
        raise ContractError("契约 $ref 指向不存在的 schema。") from error
    new_root = next((s for s in documents.values() if s.get("$id") == identifier), root) if identifier else root
    return target, new_root


def _is_type(value, name):
    number = isinstance(value, (int, float)) and not isinstance(value, bool)
    finite = number and (isinstance(value, int) or math.isfinite(value))
    return {"object": isinstance(value, dict), "array": isinstance(value, list),
            "string": isinstance(value, str), "boolean": isinstance(value, bool), "null": value is None,
            "number": finite, "integer": finite and (isinstance(value, int) or value.is_integer())}.get(name, False)


def _equal(left, right):
    # JSON booleans are distinct from numbers (Python's True == 1 is not).
    if isinstance(left, bool) or isinstance(right, bool):
        return type(left) is type(right) and left == right
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(_equal(left[k], right[k]) for k in left)
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(_equal(a, b) for a, b in zip(left, right))
    return left == right


def _check(value, schema, root, documents, kind, path=(), depth=0):
    def fail(keyword):
        location = "/".join(str(p).replace("~", "~0").replace("/", "~1") for p in path)
        raise _Mismatch(f"{kind}: /{location} 未通过 {keyword} 校验。")

    if depth > 80:
        raise ContractError("契约嵌套或 $ref 递归超过上限。")
    if schema is False:
        fail("false")
    if schema is True:
        return
    if "$ref" in schema:
        referenced, referenced_root = _resolve(schema["$ref"], root, documents)
        _check(value, referenced, referenced_root, documents, kind, path, depth + 1)
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(value, t) for t in types):
            fail("type")
    if "const" in schema and not _equal(value, schema["const"]):
        fail("const")
    if "enum" in schema and not any(_equal(value, item) for item in schema["enum"]):
        fail("enum")
    if isinstance(value, dict):
        if any(key not in value for key in schema.get("required", [])):
            fail("required")
        properties = schema.get("properties", {})
        for key, item in value.items():
            child = properties.get(key, schema.get("additionalProperties", True))
            _check(item, child, root, documents, kind, path + (key,), depth + 1)
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            fail("minItems")
        for index, item in enumerate(value):
            _check(item, schema.get("items", True), root, documents, kind, path + (index,), depth + 1)
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            fail("minLength")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            fail("pattern")
        if schema.get("format") == "date-time":
            if re.fullmatch(r"\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})", value) is None:
                fail("format")
            try:
                datetime.datetime.fromisoformat(value.upper().replace("Z", "+00:00"))
            except ValueError:
                fail("format")
    if _is_type(value, "number") and "minimum" in schema and value < schema["minimum"]:
        fail("minimum")
    for child in schema.get("allOf", []):
        _check(value, child, root, documents, kind, path, depth + 1)
    if "if" in schema:
        try:
            _check(value, schema["if"], root, documents, kind, path, depth + 1)
        except _Mismatch:
            pass
        else:
            _check(value, schema.get("then", True), root, documents, kind, path, depth + 1)


def validate(kind, document):
    if kind not in SCHEMAS:
        raise ContractError("不支持的契约类型。")
    documents = validators()
    _check(document, documents[kind], documents[kind], documents, kind)
    if kind == "event":
        try:
            timestamp = datetime.datetime.fromisoformat(document["timestamp"].upper().replace("Z", "+00:00"))
            if timestamp.utcoffset() != datetime.timedelta(0):
                raise ValueError("not UTC")
        except ValueError as error:
            raise ContractError("event: /timestamp 必须是有效的 UTC 时间。") from error
    if kind == "artifact":
        if "fingerprint" in document:
            # Shape is already checked by the schema. Verify the canonical
            # digest too; this does not assert hashes match files on disk.
            from pack.contracts.fingerprint import content_fingerprint

            fingerprint = document["fingerprint"]
            parts = fingerprint["components"]
            try:
                expected = content_fingerprint(parts["executableSha256"], parts["resourceIndexSha256"],
                                               parts["pipelineArchives"])
            except ValueError as error:
                raise ContractError("artifact: /fingerprint 管线归档路径重复。") from error
            if fingerprint["value"] != expected["value"]:
                raise ContractError("artifact: /fingerprint/value 与内容分量不符。")
        paths = [entry["path"] for entry in document["files"]]
        if len(paths) != len(set(paths)):
            raise ContractError("artifact: /files 含重复路径。")
        if document["target"] == "ios":
            details = document["details"]
            if details["ipa"] not in paths or not any(p.startswith(details["resourcePack"] + "/") for p in paths):
                raise ContractError("artifact: /details 引用的 iOS 交付不在 files 中。")
    if kind == "target":
        stages = [stage["id"] for stage in document["stages"]]
        recipes = [recipe["id"] for recipe in document["recipes"]]
        if len(stages) != len(set(stages)) or len(recipes) != len(set(recipes)):
            raise ContractError("target: 阶段或配方标识重复。")
        for stage in document["stages"]:
            if "parentStage" in stage and (stage["parentStage"] not in stages or stage["parentStage"] == stage["id"]):
                raise ContractError("target: 子阶段引用无效。")
        for recipe in document["recipes"]:
            if set(recipe["stages"]) - set(stages):
                raise ContractError("target: /recipes 引用了未声明的阶段。")
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=SCHEMAS)
    parser.add_argument("path", help="JSON 文件；event 支持 --ndjson")
    parser.add_argument("--ndjson", action="store_true")
    args = parser.parse_args()
    try:
        with Path(args.path).open(encoding="utf-8") as source:
            if args.ndjson:
                if args.kind != "event":
                    raise ContractError("--ndjson 仅适用于 event。")
                count = 0
                for count, line in enumerate(source, 1):
                    try:
                        validate(args.kind, json.loads(line))
                    except (ValueError, TypeError) as error:
                        raise ContractError(f"第 {count} 行不符合事件契约。") from error
                if not count:
                    raise ContractError("事件流为空，不能当作校验通过。")
            else:
                validate(args.kind, json.load(source))
    except (ContractError, OSError, ValueError) as error:
        # Do not print the document or raw parser/I/O error (which can embed input).
        print(str(error) if isinstance(error, ContractError) else "契约文件无法读取或不是合法 JSON。", file=sys.stderr)
        return 1
    print("契约校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
