#!/usr/bin/env python3
"""公开仓薄壳：tianyan_lane.py 是维护方私仓工具（Windows 出包机（天眼）车道），不随公开仓发布。设 S2A_PRIVATE_TOOLS=<私仓 tools 目录> 就转给那一份；没设报红退 2。"""
import os, sys
p = os.path.join(os.environ.get('S2A_PRIVATE_TOOLS') or '', 'tianyan_lane.py')
if os.environ.get('S2A_PRIVATE_TOOLS') and os.path.isfile(p):
    os.execv(sys.executable, [sys.executable, p] + sys.argv[1:])
sys.exit('【红】tools/tianyan_lane.py 是维护方Windows 出包机（天眼）车道，不在公开仓（维护方设 S2A_PRIVATE_TOOLS）')
