#!/usr/bin/env python3
"""Check that Android composition registers video before booting services."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[4]
source = (root / 'android/core-runtime/AndroidGameRuntime.cs').read_text()
register = list(re.finditer(r'^\s*S2A\.Android\.Video\.AndroidVideo\.Register\(\);', source, re.M))
boot = list(re.finditer(r'^\s*Exports\.Initialize\(configuration\);', source, re.M))
if len(register) != 1 or len(boot) != 1 or register[0].start() >= boot[0].start():
    sys.exit('FAIL: AndroidVideo.Register must occur once before Exports.Initialize(configuration)')
print('PASS Android video registration precedes service initialization')
