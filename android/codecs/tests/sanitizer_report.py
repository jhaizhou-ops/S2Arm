"""Do not suppress diagnostics. Classify only exact pinned upstream sites."""
import hashlib
import json
from pathlib import Path
import re

PIN='d380d04a78c6c08702e36aca86d0fd4baee390f9'

def inspect(text,source,allow_upstream=False):
    if 'ERROR: AddressSanitizer' in text or 'ERROR: LeakSanitizer' in text:
        raise AssertionError('ASan/LSan error (never allowed)')
    table=json.loads(Path(__file__).with_name('upstream-ubsan.json').read_text())
    assert table['commit']==PIN
    known=[]
    for line in text.splitlines():
        if 'runtime error:' not in line: continue
        match=re.search(r'([^\s]+):(\d+):(\d+): runtime error: (.*)',line)
        if not allow_upstream or not match: raise AssertionError('strict sanitizer error: '+line)
        path=Path(match[1]).resolve()
        try: relative=path.relative_to(source.resolve()).as_posix()
        except ValueError: raise AssertionError('non-upstream diagnostic: '+line)
        found=next((row for row in table['findings'] if row['file']==relative and row['line']==int(match[2]) and
                    re.fullmatch(row['message_regex'],match[4])),None)
        if not found: raise AssertionError('new upstream diagnostic: '+line)
        assert hashlib.sha256(path.read_bytes()).hexdigest()==found['source_sha256'], 'upstream source drift'
        known.append((relative,int(match[2]),found['kind']))
    return known
