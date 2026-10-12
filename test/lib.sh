# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared helpers for the test suites. Source it from a test script:
#   . "$(dirname "$0")/lib.sh"
#
# Provides: HERE (this directory), PFX (project root), the log_* helpers, the pass/fail counters,
# `t DESCRIPTION CONDITION` (evaluates CONDITION and records the result), `section` and `summary`.

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PFX=$(dirname "$HERE")
# shellcheck source=../lib/log.sh
. "$PFX/lib/log.sh"

pass=0
fail=0

ok() { log_ok "$1"; ((pass++)); }
ko() { log_err "$1" 2>&1; ((fail++)); }   # keep the report on one stream
t() { if eval "$2"; then ok "$1"; else ko "$1"; fi; }

section() { log_info "$*"; }

# summary LABEL -> prints the totals and succeeds only if nothing failed
summary() {
    if ((fail == 0)); then
        log_ok "$1: $pass passed, $fail failed"
    else
        log_err "$1: $pass passed, $fail failed" 2>&1
    fi
    ((fail == 0))
}
