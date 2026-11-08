#!/usr/bin/env python3
"""Validate planned log contracts without reading logs or launching the runtime.

Source and consumer references are repository-relative paths with an optional
``#symbol`` suffix. The suffix must occur in the referenced UTF-8 source; this
is a reference check, not language-specific symbol resolution.
With --staged, schemas, catalog, and referenced sources all come from Git index.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path, PurePosixPath

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
EVENT_PATTERN = r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$"
TEXT = {"type": "string", "minLength": 1}
TEXT_LIST = {"type": "array", "minItems": 1, "items": TEXT, "uniqueItems": True}
REFERENCES = {
    "type": "array",
    "minItems": 1,
    "uniqueItems": True,
    "items": {"type": "string", "pattern": r"^[^#:\s]+(?:#[A-Za-z_][A-Za-z0-9_]*)?$"},
}
CATALOG_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "required": ["schema_version", "description", "events"],
    "properties": {
        "schema_version": {"const": 1},
        "description": TEXT,
        "events": {
            "type": "array",
            "minItems": 1,
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": [
                    "event",
                    "event_version",
                    "status",
                    "description",
                    "source",
                    "consumers",
                    "acceptance",
                    "selection",
                    "data_schema",
                ],
                "properties": {
                    "event": {"type": "string", "pattern": EVENT_PATTERN},
                    "event_version": {"type": "integer", "const": 1},
                    "status": {"const": "planned"},
                    "description": TEXT,
                    "source": REFERENCES,
                    "consumers": REFERENCES,
                    "acceptance": {
                        "type": "object",
                        "additionalProperties": False,
                        "required": ["cells", "rule", "evidence"],
                        "properties": {"cells": TEXT_LIST, "rule": TEXT, "evidence": TEXT_LIST},
                    },
                    "selection": TEXT,
                    "data_schema": {
                        "type": "object",
                        "required": ["$schema", "type"],
                        "properties": {
                            "$schema": {"const": "https://json-schema.org/draft/2020-12/schema"},
                            "type": {"const": "object"},
                        },
                    },
                },
            },
        },
    },
}


def read_source(relative: str, *, staged: bool) -> str:
    relative_path = PurePosixPath(relative)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValueError(f"Reference must stay within the repository: {relative}")
    if staged:
        return subprocess.run(
            ["git", "show", f":{relative_path.as_posix()}"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
        ).stdout.decode("utf-8")
    path = (ROOT / relative_path).resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError(f"Reference must stay within the repository: {relative}")
    if not path.is_file():
        raise ValueError(f"Reference does not name an existing file: {relative}")
    return path.read_text(encoding="utf-8")


def check_reference(reference: str, *, staged: bool) -> None:
    relative, _, symbol = reference.partition("#")
    source = read_source(relative, staged=staged)
    if symbol and symbol not in source:
        raise ValueError(f"Reference symbol does not occur in its source: {reference}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--staged", action="store_true", help="Read all contract inputs from Git index"
    )
    args = parser.parse_args()
    envelope = json.loads(read_source("docs/standards/log-event.schema.json", staged=args.staged))
    catalog = json.loads(read_source("docs/standards/log-events.json", staged=args.staged))
    Draft202012Validator.check_schema(envelope)
    Draft202012Validator.check_schema(CATALOG_SCHEMA)
    Draft202012Validator(CATALOG_SCHEMA, format_checker=FormatChecker()).validate(catalog)

    identities: set[tuple[str, int]] = set()
    reference_count = 0
    for event in catalog["events"]:
        identity = (event["event"], event["event_version"])
        if identity in identities:
            raise ValueError(f"Duplicate event/version: {identity}")
        identities.add(identity)
        Draft202012Validator.check_schema(event["data_schema"])
        for reference in event["source"] + event["consumers"]:
            check_reference(reference, staged=args.staged)
            reference_count += 1

    print(
        f"Log contracts valid: 1 envelope schema, {len(identities)} planned events, "
        f"{reference_count} source/consumer references "
        f"({'Git index' if args.staged else 'working tree'}). "
        "Runtime producers are not implemented."
    )


if __name__ == "__main__":
    main()
