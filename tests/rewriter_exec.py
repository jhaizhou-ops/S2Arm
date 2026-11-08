#!/usr/bin/env python3
"""Keep REW=<Python script or native executable> usable by the existing tests."""
import os
import sys
from pathlib import Path

rew, *args = sys.argv[1:]
command = [sys.executable, rew, *args] if Path(rew).suffix == '.py' else [rew, *args]
os.execv(command[0], command)
