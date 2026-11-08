"""Reconcile GCKind snapshots against exact collection counts and cumulative pauses."""
from collections import defaultdict


def canonical_collections(data):
    groups = defaultdict(list)
    for event in data["collections"]:
        if event["index"] <= 0:
            raise ValueError("nonpositive GC Index")
        groups[event["index"]].append(event)
    selected, collisions = [], 0
    for index, group in groups.items():
        if len(group) == 1:
            selected.append(group[0])
            continue
        # Observed .NET 10.0.9 on Mac: Background can expose an Index also
        # returned by FullBlocking, carrying startup/empty metadata. Preserve
        # both in raw JSON; use the full-blocking record only when unambiguous.
        full = [e for e in group if e["generation"] == 2 and not e["concurrent"]]
        if len(full) != 1:
            raise ValueError(f"ambiguous duplicate GC Index {index}")
        for event in group:
            if event is full[0]:
                continue
            empty = (event["before_bytes"] == event["after_bytes"] == 0
                     and event["pause0_ms"] == event["pause1_ms"] == 0)
            if not ((event["generation"] == 2 and event["concurrent"]) or empty):
                raise ValueError(f"incompatible duplicate GC Index {index}")
        selected.append(full[0])
        collisions += len(group) - 1
    for event in selected:
        if event["after_bytes"] <= 0:
            raise ValueError("empty GC snapshot")
    return selected, collisions
