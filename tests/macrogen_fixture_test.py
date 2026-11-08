#!/usr/bin/env python3
"""Literal MME encoding checks independent of the assembler implementation."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
p=Path(__file__).parent/"fixtures/generate_mme.py"
spec=importlib.util.spec_from_file_location("generate_mme",p)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class Fixture(unittest.TestCase):
    def test_literal_words(self):
        expected={
            "send_7": [0x80021,0x1c0c1,0x11],
            "send_minus_3": [0x90021,0xffff40c1,0x11],
            "send_arg_plus_5": [0xa0021,0x148c1,0x11],
        }
        self.assertEqual(m.programs(),expected)
        with tempfile.TemporaryDirectory() as d:
            a=Path(d)/"a";b=Path(d)/"b"
            m.generate(a);m.generate(b)
            self.assertEqual({p.name for p in a.iterdir()},{n+".mme" for n in expected})
            for name,words in expected.items():
                raw=(a/(name+".mme")).read_bytes()
                self.assertEqual(raw,struct.pack("<III",*words))
                self.assertEqual(raw,(b/(name+".mme")).read_bytes())
            with self.assertRaises(FileExistsError): m.generate(a)

    def test_immediate_bounds(self):
        for n in [-131073,131072]:
            with self.assertRaises(ValueError): m.immediate(n,1)
        self.assertEqual(m.immediate(-131072,1),0x80000011)
        self.assertEqual(m.immediate(131071,1),0x7fffc011)

if __name__=="__main__": unittest.main()
