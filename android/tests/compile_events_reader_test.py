#!/usr/bin/env python3
"""Compile-event file contract, using fixed synthetic records and independent SHA checks."""
import hashlib
import json
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compile_events

META = b'{"schema":"s2a-compile-events-v1","clock":"CLOCK_BOOTTIME","pid":7,"session":42,"begin_us":100}\n'
EV = b'{"id":1,"kind":"translation","result":"miss","start_us":125,"end_us":150}\n'
def fixture(meta=META, events=(EV,), **overrides):
    payload = meta + b''.join(events)
    footer = {'status':'complete','count':len(events),'dropped':0,'end_us':200}
    footer.update(overrides)
    signed = json.dumps(footer,separators=(',',':')).encode()
    footer['sha256'] = hashlib.sha256(payload + signed).hexdigest()
    return payload + (json.dumps(footer,separators=(',',':'))+'\n').encode()

class ReaderContract(unittest.TestCase):
    def test_v2_hit_summary_is_signed_and_capacity_checked(self):
        head = META.replace(b's2a-compile-events-v1',b's2a-compile-events-v2').replace(b'"begin_us":100}', b'"begin_us":100,"capacity":1}')
        payload = head + EV
        core = {'status':'complete','count':1,'dropped':0,'hits':100000,'end_us':200}
        raw = payload + (json.dumps({**core,'sha256':hashlib.sha256(payload+json.dumps(core,separators=(',',':')).encode()).hexdigest()},separators=(',',':'))+'\n').encode()
        parsed=compile_events.parse(raw,pid=7,session=42,window=(110,190))
        self.assertEqual((parsed['hits'],parsed['misses']),(100000,1))
        for corrupted in (raw.replace(b'"hits":100000', b'"hits":0'),
                          raw.replace(b'"capacity":1',b'"capacity":0'),
                          raw.replace(b'"hits":100000',b'"hits":true')):
            with self.assertRaises(ValueError):
                compile_events.parse(corrupted,pid=7,session=42,window=(110,190))

    def test_complete_same_session_and_window(self):
        result=compile_events.parse(fixture(), pid=7, session=42, window=(110,190))
        self.assertEqual((result['records'],result['misses'],result['dropped']), (1,1,0))

    def test_corruption_including_header_rejected(self):
        with self.assertRaisesRegex(ValueError,'sha256'):
            compile_events.parse(fixture().replace(b'begin_us":100',b'begin_us":101'),pid=7,session=42,window=(110,190))
        with self.assertRaisesRegex(ValueError,'sha256'):
            compile_events.parse(fixture().replace(b'end_us":150',b'end_us":151'),pid=7,session=42,window=(110,190))

    def test_lost_count_cannot_be_changed_to_zero(self):
        raw=fixture(dropped=1).replace(b'"dropped":1', b'"dropped":0')
        with self.assertRaisesRegex(ValueError,'sha256'):
            compile_events.parse(raw,pid=7,session=42,window=(110,190))

    def test_boolean_values_never_impersonate_integer_identity_or_loss(self):
        bogus_pid = META.replace(b'"pid":7', b'"pid":true')
        with self.assertRaises(ValueError):
            compile_events.parse(fixture(meta=bogus_pid), pid=1, session=42, window=(110,190))
        with self.assertRaises(ValueError):
            compile_events.parse(fixture(dropped=False), pid=7, session=42, window=(110,190))

    def test_missing_dropped_wrong_clock_and_window_rejected(self):
        for blob in (fixture()[:-1], fixture(dropped=1), fixture(count=2),
                     fixture(meta=META.replace(b'CLOCK_BOOTTIME', b'CLOCK_MONOTONIC'))):
            with self.subTest(blob=blob[:80]), self.assertRaises(ValueError):
                compile_events.parse(blob,pid=7,session=42,window=(110,190))
        for pid,session,window in ((8,42,(110,190)),(7,43,(110,190)),(7,42,(99,190)),(7,42,(110,201))):
            with self.subTest(pid=pid,session=session,window=window), self.assertRaises(ValueError):
                compile_events.parse(fixture(),pid=pid,session=session,window=window)

if __name__=='__main__': unittest.main()
