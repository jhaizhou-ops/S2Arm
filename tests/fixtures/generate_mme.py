#!/usr/bin/env python3
"""Original MME examples assembled from instruction fields, never game dumps.

All examples set a method address then send a small literal. They are temporary
test data only and must never replace the production macro registry.
"""
import argparse
from pathlib import Path
import struct

def immediate(value, assignment, register=0, source=0, end=False):
    if not -(1 << 17) <= value < (1 << 17):
        raise ValueError("18-bit signed immediate required")
    return ((value & 0x3ffff) << 14 | source << 11 | register << 8
            | int(end) << 7 | assignment << 4 | 1)

def programs():
    # Assignment 2 moves ALU output to method address; 4 sends ALU output.
    # Each exit executes exactly one trailing instruction (move zero).
    return {
        "send_7": [immediate(0x20, 2), immediate(7, 4, end=True), immediate(0, 1)],
        "send_minus_3": [immediate(0x24, 2), immediate(-3, 4, end=True), immediate(0, 1)],
        "send_arg_plus_5": [immediate(0x28, 2), immediate(5, 4, source=1, end=True), immediate(0, 1)],
    }

def generate(out):
    out=Path(out)
    out.mkdir(parents=True, exist_ok=False)
    for name, words in programs().items():
        (out / (name + ".mme")).write_bytes(struct.pack("<"+"I"*len(words), *words))

if __name__ == "__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("output", help="new temporary directory; existing directory rejected")
    generate(p.parse_args().output)
