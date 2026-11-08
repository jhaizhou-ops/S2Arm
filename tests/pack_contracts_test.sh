#!/bin/bash
# 门禁覆盖：pack/contracts/* pack/targets/* pack/jobs/main.py pack/jobs/target_main.py tools/clonedir.py
# Offline, standard library only; -S excludes all site-packages.
set -eu
cd "$(dirname "$0")/.."
"${S2A_CONTRACT_PY:-python3}" -I -S -B tests/pack_contracts_test.py
"${S2A_CONTRACT_PY:-python3}" -I -S -B tests/t_android_oneclick.py
"${S2A_CONTRACT_PY:-python3}" -I -S -B tests/t_android_nacp.py
"${S2A_CONTRACT_PY:-python3}" -I -S -B tests/clonedir_portable_test.py
