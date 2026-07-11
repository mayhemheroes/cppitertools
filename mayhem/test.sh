#!/usr/bin/env bash
#
# cppitertools/mayhem/test.sh — RUN cppitertools' own Catch2 unit-test suite (built by
# mayhem/build.sh with normal flags) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: test/test_*.cpp are real per-feature unit tests that assert the exact
# semantics of each iterator adaptor (chain/zip/groupby/range/...). They check concrete output
# values, so a no-op / "return 0" patch (or any change that alters adaptor behaviour) makes
# assertions fail. This script only RUNS the pre-built `test_all` binary; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

BIN="$SRC/mayhem-tests/test_all"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$BIN" ]; then
  echo "missing $BIN — run mayhem/build.sh first" >&2
  emit_ctrf "catch2" 0 1 0; exit 2
fi

echo "=== running cppitertools unit tests ($BIN) ==="
# Catch2 reporter that lists each test case result, then a final summary line.
out="$("$BIN" --reporter console 2>&1)"; rc=$?
echo "$out"

# Catch's final summary lines look like one of:
#   All tests passed (12345 assertions in 250 test cases)
#   test cases: 250 | 248 passed | 2 failed
PASSED=0; FAILED=0
if printf '%s\n' "$out" | grep -qE '^All tests passed'; then
  # "All tests passed (... in N test cases)"
  PASSED=$(printf '%s\n' "$out" | sed -nE 's/.*in ([0-9]+) test case.*/\1/p' | tail -1)
  : "${PASSED:=0}"; FAILED=0
else
  # "test cases: T | P passed | F failed" — fields may be missing if zero.
  line="$(printf '%s\n' "$out" | grep -E '^test cases:' | tail -1)"
  PASSED=$(printf '%s\n' "$line" | sed -nE 's/.*[|[:space:]]([0-9]+) passed.*/\1/p')
  FAILED=$(printf '%s\n' "$line" | sed -nE 's/.*[|[:space:]]([0-9]+) failed.*/\1/p')
  : "${PASSED:=0}" "${FAILED:=0}"
fi

# If we could not parse any counts, fall back to the binary's exit code.
if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "could not parse Catch2 summary; using test_all exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "catch2" 1 0 0; exit 0; }
  emit_ctrf "catch2" 0 1 0; exit 1
fi

# Reconcile with the process exit code: a nonzero rc with no parsed failures still fails the suite.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

emit_ctrf "catch2" "$PASSED" "$FAILED" 0
