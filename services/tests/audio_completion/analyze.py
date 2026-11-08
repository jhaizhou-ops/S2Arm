# 门禁手动：辅助模块，由 services/tests/audio_completion/test.py 导入分析 run 产物（单跑要传 run 输出目录），本身不是单测
"""Verify real public completion reads against production AudioQueue q/c events."""
import argparse
import csv
import json
from pathlib import Path


class Incomplete(Exception):
    """The real trace does not provide the required positive observation."""


def analyze(directory: Path) -> dict:
    observations = [json.loads(line) for line in (directory / "events.jsonl").read_text().splitlines()]
    begin = next(row for row in observations if row["kind"] == "begin")
    mode = begin["data"]["cushion"]
    if mode not in ("on", "off"):
        raise ValueError("Unknown cushion mode")
    anchor = begin["clock"]
    offset = anchor["us"] - anchor["legacyDiagUs"]
    trace = Path(begin["data"]["wav_prefix"] + ".0.tsv")
    native = []
    with trace.open(newline="") as stream:
        for columns in csv.reader(stream, delimiter="\t"):
            if len(columns) != 6 or columns[0] not in ("q", "c"):
                raise ValueError(f"Unexpected production event: {columns!r}")
            legacy, frames, flight, gc, pause = map(int, columns[1:])
            if not -1_000_000 <= legacy - anchor["legacyDiagUs"] <= 5_000_000:
                raise Incomplete("Legacy timestamp wrapped or trace escaped the bounded run")
            native.append(dict(kind=columns[0], us=legacy + offset, frames=frames, flight=flight))
    # The production writer drains c and q separately; file order is not chronology.
    submitted = sorted((row for row in native if row["kind"] == "q"), key=lambda row: row["us"])
    returned = sorted((row for row in native if row["kind"] == "c"), key=lambda row: row["us"])
    expected = [2400, 1696] + ([2400] if mode == "on" else []) + [1024]
    if [row["frames"] for row in submitted] != expected:
        raise Incomplete(f"Expected actual q sequence {expected}; got {submitted}")
    if sorted(row["frames"] for row in returned) != sorted(expected):
        raise Incomplete("Missing, duplicated, or unexpected real c rows")
    target_return = next(row for row in returned if row["frames"] == 1024)
    target_submit = submitted[-1]
    queue_call = next(row["data"] for row in observations if row["kind"] == "target_queue_return")
    if not queue_call["call_begin"]["us"] - 2 <= target_submit["us"] <= queue_call["call_end"]["us"] + 2:
        raise ValueError("Target q lies outside its public QueueBuffer bracket")
    if not 0 <= queue_call["since_public_drain_us"] < 1_000_000:
        raise Incomplete("Target was not appended within the observed <1-second drain window")
    public = [row["data"] for row in observations if row["kind"] == "public_sample" and row["data"]["phase"] == "target"]
    for row in public:
        if row["read_begin"]["ticks"] > row["read_end"]["ticks"]:
            raise ValueError("Reversed public read interval")
    # A c timestamp is emitted inside Returned, before ProcessPlayedSamples.
    # Require the whole public read strictly on the relevant side, with 2us
    # allowance for integer legacy conversion. No speaker timing is inferred.
    before_target = [row for row in public if row["read_end"]["us"] + 2 < target_return["us"]]
    early = [row for row in before_target if row["target_consumed"] or
             row["played_before"] > 4096 or row["played_after"] > 4096]
    cushion_return = None
    window_start = target_submit["us"]
    if mode == "on":
        candidates = [row for row in returned if row["frames"] == 2400 and row["us"] >= submitted[-2]["us"] - 2]
        if len(candidates) != 1:
            raise Incomplete("Cannot uniquely identify the actual cushion c")
        cushion_return = candidates[0]
        window_start = cushion_return["us"]
    pending = [row for row in before_target if row["read_begin"]["us"] > window_start + 2 and
               row["played_before"] == 4096 and row["played_after"] == 4096 and row["target_consumed"] is False]
    completed = [row for row in public if row["read_begin"]["us"] > target_return["us"] + 2 and
                 row["played_before"] == 5120 and row["played_after"] == 5120 and row["target_consumed"] is True]
    sequence_complete = any(row["kind"] == "sequence_complete" for row in observations)
    code = 1 if early else (0 if pending and completed and sequence_complete else 2)
    return dict(mode=mode, exit=code, verdict=("early_completion" if code == 1 else "positive_window_verified" if code == 0 else "incomplete_observation"),
                actual_submitted_frames=[row["frames"] for row in submitted],
                actual_returned_frames=[row["frames"] for row in returned],
                target_native_return_us=target_return["us"],
                cushion_native_return_us=None if cushion_return is None else cushion_return["us"],
                pending_window_reads=len(pending), completed_after_callback_reads=len(completed),
                early_read=None if not early else early[0],
                pending_read=None if not pending else pending[0],
                completed_read=None if not completed else completed[0],
                callback_lead_us=None if not early else target_return["us"] - early[0]["read_end"]["us"],
                boundary="Real AudioQueue hand-back accounting only; no ReclaimAll/recovery, physical playback, iOS or game acceptance")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        result = analyze(args.directory.resolve())
    except Incomplete as error:
        result = dict(exit=2, verdict="incomplete_observation", reason=str(error))
    print(json.dumps(result, indent=2, ensure_ascii=False))
    raise SystemExit(result["exit"])
