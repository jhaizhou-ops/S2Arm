#!/usr/bin/env python3
"""Strict validation of a generic compile-event capture against a session and BOOTTIME window."""
import hashlib
import json
import re

MAX_BYTES = 16 * 1024 * 1024
KINDS = {'translation', 'graphics_pipeline', 'compute_pipeline'}
RESULTS = {'hit', 'miss', 'failure'}

def _object(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result: raise ValueError('duplicate JSON field')
            result[key] = value
        return result
    try:
        value = json.loads(raw, object_pairs_hook=unique)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError('invalid JSON') from exc
    if not isinstance(value, dict): raise ValueError('record is not an object')
    return value

def _integer(value):
    return type(value) is int and value >= 0

def parse(raw, *, pid, session, window):
    if not isinstance(raw, bytes) or not 0 < len(raw) <= MAX_BYTES or not raw.endswith(b'\n'):
        raise ValueError('missing, truncated or oversized event file')
    lines = raw.splitlines(keepends=True)
    if len(lines) < 2: raise ValueError('missing event header or footer')
    head, foot = _object(lines[0]), _object(lines[-1])
    if (head.get('schema') not in ('s2a-compile-events-v1', 's2a-compile-events-v2') or head.get('clock') != 'CLOCK_BOOTTIME'
            or not _integer(head.get('pid')) or not _integer(head.get('session'))
            or not _integer(pid) or not _integer(session) or head.get('pid') != pid or head.get('session') != session):
        raise ValueError('wrong schema, clock, process or session')
    begin, end = head.get('begin_us'), foot.get('end_us')
    if (not _integer(begin) or not _integer(end) or not begin or end < begin
            or not isinstance(window, (list, tuple)) or len(window) != 2
            or not all(_integer(x) for x in window) or window[0] > window[1]
            or begin > window[0] or end < window[1]):
        raise ValueError('capture does not cover requested BOOTTIME window')
    if (foot.get('status') != 'complete' or not _integer(foot.get('count'))
            or foot['count'] != len(lines)-2 or not _integer(foot.get('dropped')) or foot.get('dropped') != 0):
        raise ValueError('incomplete capture or dropped events')
    v2 = head['schema'] == 's2a-compile-events-v2'
    if v2 and (not _integer(head.get('capacity')) or not 1 <= head['capacity'] <= 65536
               or foot['count'] > head['capacity'] or not _integer(foot.get('hits'))):
        raise ValueError('invalid capacity or hit count')
    digest = foot.get('sha256')
    keys = ('status', 'count', 'dropped', 'hits', 'end_us') if v2 else ('status', 'count', 'dropped', 'end_us')
    core = {key: foot.get(key) for key in keys}
    signed_footer = json.dumps(core, separators=(',', ':')).encode('utf-8')
    if not isinstance(digest,str) or not re.fullmatch(r'[0-9a-f]{64}',digest) or digest != hashlib.sha256(b''.join(lines[:-1]) + signed_footer).hexdigest():
        raise ValueError('sha256 mismatch')
    events=[]
    for index,line in enumerate(lines[1:-1],1):
        event = _object(line)
        start, stop = event.get('start_us'), event.get('end_us')
        if (not _integer(event.get('id')) or event.get('id') != index or event.get('kind') not in KINDS or event.get('result') not in RESULTS
                or (v2 and event.get('result') == 'hit')
                or not _integer(start) or not _integer(stop) or not begin <= start <= stop <= end):
            raise ValueError('invalid event order, type, result or BOOTTIME')
        events.append(event)
    selected = [e for e in events if e['start_us'] <= window[1] and e['end_us'] >= window[0]]
    return {'records':len(events), 'dropped':0, 'misses':sum(e['kind']=='translation' and e['result']=='miss' for e in selected),
            'begin_us':begin, 'end_us':end, 'hits':foot['hits'] if v2 else None, 'events':events}
