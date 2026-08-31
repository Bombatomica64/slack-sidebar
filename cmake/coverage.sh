#!/bin/sh
# SPDX-License-Identifier: MIT
#
# What is tested, and - more usefully - what is not. Prints llvm-cov's table for
# the code the tests reach, then names every module they do not reach at all,
# because a module with no test binary linking it never appears in a coverage
# report and its absence is easy to miss.
#
# Not a gate - nothing fails for being under the floor. It is the line between
# "has some tests" and "has tests in name only", so the report can say which.
#
#   coverage.sh <build-dir> <parser-test> <agent-test>
set -eu

builddir=$1
parser=$2
agent=$3

: "${LLVM_PROFDATA:=llvm-profdata}"
: "${LLVM_COV:=llvm-cov}"
: "${COVERAGE_FLOOR:=25}"

mkdir -p "$builddir"

LLVM_PROFILE_FILE="$builddir/parser.profraw" "$parser" >/dev/null
LLVM_PROFILE_FILE="$builddir/agent.profraw" "$agent" >/dev/null

"$LLVM_PROFDATA" merge -sparse -o "$builddir/test.profdata" \
  "$builddir/parser.profraw" "$builddir/agent.profraw"

report() {
  "$LLVM_COV" report "$parser" -object "$agent" \
    -instr-profile="$builddir/test.profdata" \
    -ignore-filename-regex='(tests/|/usr/)'
}

echo
report

"$LLVM_COV" show "$parser" -object "$agent" \
  -instr-profile="$builddir/test.profdata" \
  -ignore-filename-regex='(tests/|/usr/)' \
  -format=html -output-dir="$builddir/html" >/dev/null 2>&1 || true

echo
report | awk -v floor="$COVERAGE_FLOOR" \
  '/\.cppm/ { pct = $10 + 0; if (pct < floor) print "  " $1 "  " $10 }' \
  > "$builddir/thin.txt"

if [ -s "$builddir/thin.txt" ]; then
  echo "Effectively untested (line coverage under ${COVERAGE_FLOOR}%):"
  cat "$builddir/thin.txt"
else
  echo "Every module is above ${COVERAGE_FLOOR}% line coverage."
fi

echo
echo "line-by-line html: $builddir/html/index.html"
