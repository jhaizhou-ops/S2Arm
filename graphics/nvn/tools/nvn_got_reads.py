"""Static slot-read heuristic adapted from the upstream reference implementation dm/tools/nvn_slots_got.py.

Source: , commit
7a029f66d92c951ae6a86e38bb34eeb0cb7527e3. The loader itself is checked separately.

MIT License
Copyright (c) 2026 seedds

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""


def writes(word, register):
    op0 = (word >> 25) & 0xf
    if word & 0xfc000000 == 0x94000000 or word & 0xfffffc1f == 0xd63f0000:
        return register <= 18
    if op0 in (0b1000, 0b1001, 0b0101, 0b1101):
        return (word & 31) == register
    if op0 & 0b0101 == 0b0100:
        load = (word >> 22) & 1
        if (word >> 27) & 7 == 0b101:
            writeback = (word >> 23) & 3 in (1, 3)
            return (load and ((word & 31) == register or ((word >> 10) & 31) == register)) or (writeback and ((word >> 5) & 31) == register)
        if (word >> 27) & 7 == 0b111 and (word >> 24) & 3 == 0:
            writeback = (word >> 21) & 1 == 0 and (word >> 10) & 3 in (1, 3)
            return (load and (word & 31) == register) or (writeback and ((word >> 5) & 31) == register)
        if (word >> 27) & 7 == 0b111:
            return bool(load) and (word & 31) == register
        if (word >> 27) & 7 == 0b011:
            return (word & 31) == register
    return False


def slot_reads(words, start, end, slots, decoder):
    """Keep upstream's backward ADRP trace and 4,000-instruction bound."""
    by_address = {}
    for row in slots:
        for address in (row['slot'], row['got']):
            if address is None:
                continue
            if address in by_address and by_address[address] != row['slot']:
                raise ValueError(f"Address {address:#x} aliases different NVN slots")
            by_address[address] = row['slot']
    uses = {row['slot']: [] for row in slots}
    offsets = {address & 0xfff for address in by_address}
    for i, word in enumerate(words):
        if start <= i * 4 < end or word & 0xffc00000 != 0xf9400000:
            continue
        offset, register = ((word >> 10) & 0xfff) * 8, (word >> 5) & 31
        if offset & 0xfff not in offsets or register == 31:
            continue
        for j in range(i - 1, max(i - 4000, -1), -1):
            previous = words[j]
            if previous == 0xd65f03c0:
                break
            if writes(previous, register):
                page = decoder.adrp(previous, j * 4)
                if page is not None and page[0] == register:
                    address = page[1] + offset
                    if address in by_address:
                        uses[by_address[address]].append(i * 4)
                break
    return uses
