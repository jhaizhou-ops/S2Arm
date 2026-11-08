#!/usr/bin/env python3
"""公开仓薄壳：device_ledger.py 是维护方私仓工具（真机账本），不随公开仓发布。设 S2A_PRIVATE_TOOLS=<私仓 tools 目录> 就转给那一份；没设报红退 2。"""
import os, sys
p = os.path.join(os.environ.get('S2A_PRIVATE_TOOLS') or '', 'device_ledger.py')
if os.environ.get('S2A_PRIVATE_TOOLS') and os.path.isfile(p):
    os.execv(sys.executable, [sys.executable, p] + sys.argv[1:])
sys.exit('【红】tools/device_ledger.py 是维护方真机账本，不在公开仓（维护方设 S2A_PRIVATE_TOOLS）')
