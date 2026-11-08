#!/bin/bash
# ipc_diff.py 自测（造两份调用流，六类差异 + 尾部 + 整种只一边有）
python3 "$(dirname "$0")/../tools/ipc_diff.py" --selftest
