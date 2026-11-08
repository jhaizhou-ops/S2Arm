#!/bin/bash
# 门禁覆盖：tools/redact.py tools/diagnostic_report.py tools/beta_intake.py tests/diagnostic_report_test.py tests/redact_cases_test.py tests/fixtures/redact_cases.tsv
# Synthetic diagnostics; tools/score_cells.py and pack/jobs/library.py compatibility.
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 -B "$H/tests/diagnostic_report_test.py" -v
cd "$H"
python3 -B "$H/tests/redact_cases_test.py" -v
