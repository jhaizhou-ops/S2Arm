"""Summarize complete aot_heap.py snapshots from one process as JSON.

python3 tools/aot_heap_summary.py /path/to/heap-001.json /path/to/heap-002.json
Rows are the final snapshot's largest dynamic types; frozen objects stay separate.
Ownership and leak diagnosis require source/reference evidence outside this tool.
GC reference slots include nulls and are not measured GC work. Schema 1 snapshots
lack this metadata; their slot counts remain null (unknown), never inferred zero.
"""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshots", type=Path, nargs="+")
    parser.add_argument("--top", type=int, default=20)
    args = parser.parse_args()
    if args.top < 1:
        parser.error("--top must be positive")
    snapshots = [json.loads(path.read_text(encoding="utf-8")) for path in args.snapshots]
    identity = None
    previous = -1
    samples = []
    indexes = []
    for data in snapshots:
        if data["schema"] not in (1, 2) or data["status"] != "complete" or data["generation"] != 2 or data["concurrent"] or data["backgroundRunning"]:
            raise ValueError("Only complete blocking gen2 snapshots are supported")
        current = (data["processId"], data["moduleUuid"], data["runtimeVersionAttestation"], data["layout"])
        if identity is not None and identity != current:
            raise ValueError("Snapshots must come from the same process and executable")
        identity = current
        if data["gcIndex"] <= previous:
            raise ValueError("Pass snapshots in strictly increasing GC order")
        previous = data["gcIndex"]
        rows = data["types"]
        indexes.append({row["methodTable"]: row for row in rows})
        samples.append(dict(gcIndex=data["gcIndex"], startedUnixSeconds=data["startedUnixSeconds"],
                            snapshotSeconds=data["snapshotSeconds"], dynamicCount=sum(row["count"] for row in rows),
                            dynamicShallowBytes=sum(row["shallowBytes"] for row in rows),
                            frozenShallowBytes=sum(row["shallowBytes"] for row in data["frozenTypes"]),
                            dynamicGcReferenceSlots=sum(row["gcReferenceSlots"] for row in rows) if data["schema"] == 2 else None,
                            frozenGcReferenceSlots=sum(row["gcReferenceSlots"] for row in data["frozenTypes"]) if data["schema"] == 2 else None))
    top = []
    for row in sorted(snapshots[-1]["types"], key=lambda item: item["shallowBytes"], reverse=True)[:args.top]:
        history = [index.get(row["methodTable"]) for index in indexes]
        counts = [item["count"] if item else 0 for item in history]
        sizes = [item["shallowBytes"] if item else 0 for item in history]
        slots = [(item["gcReferenceSlots"] if item else 0) if data["schema"] == 2 else None
                 for item, data in zip(history, snapshots)]
        top.append(dict(typeName=row["typeName"], typeNameConfirmed=row["typeNameConfirmed"],
                        methodTable=row["methodTable"], counts=counts, shallowBytes=sizes,
                        gcReferenceSlots=slots,
                        deltaGcReferenceSlots=slots[-1]-slots[0] if slots[0] is not None and slots[-1] is not None else None,
                        deltaCount=counts[-1]-counts[0], deltaShallowBytes=sizes[-1]-sizes[0]))
    source = dict(processId=identity[0], moduleUuid=identity[1],
                  runtimeVersionAttestation=identity[2], layout=identity[3])
    print(json.dumps(dict(schema=2, source=source, samples=samples, topTypes=top,
                          note="Shallow bytes and GC-described slots (including nulls); unknown slots are null. No measured scan work, ownership graph, retained-size or leak claim"), indent=2))


if __name__ == "__main__":
    main()
