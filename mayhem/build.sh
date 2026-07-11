#!/usr/bin/env bash
#
# cppitertools/mayhem/build.sh — build the OSS-Fuzz harness as a sanitized libFuzzer target
# (+ a standalone run-once reproducer), AND the project's own Catch2 unit-test suite for
# mayhem/test.sh.
#
# cppitertools is a HEADER-ONLY C++17 iterator library (iter::chain/zip/groupby/...). The fuzzed
# surface is those iterator adaptors driven on attacker-controlled bytes. fuzz_cppitertools.cpp
# (the OSS-Fuzz harness) parses raw input via FuzzedDataProvider into vectors/strings and drives:
#   chain(v,v,v) / groupby(v, length) / cycle(v) / combinations(s, k) / compress(ivec, bvec)
# materializing the results, so any out-of-bounds / UB inside the adaptors is caught by ASan+UBSan.
# The harness itself IS the instrumented code (there is no separate library object to build).
#
# Build contract comes from the org base ENV (CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/
# STANDALONE_FUZZ_MAIN/SRC). We compile the harness with $SANITIZER_FLAGS -std=c++17 against the
# headers, once as a libFuzzer target and once with the standalone main.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
# The harness includes adaptor headers bare (e.g. <chain.hpp>) AND via the package dir
# (<cppitertools/...>), matching upstream OSS-Fuzz build.sh: -I./ -I./cppitertools.
INC="-I$SRC -I$SRC/cppitertools"

# ── 1) libFuzzer target -> /mayhem/fuzz_cppitertools ───────────────────────────────────────────
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 $INC \
    "$HARNESS_DIR/fuzz_cppitertools.cpp" $LIB_FUZZING_ENGINE \
    -o "/mayhem/fuzz_cppitertools"

# ── 2) standalone run-once reproducer (no libFuzzer runtime) -> /mayhem/fuzz_cppitertools-standalone
# The base's StandaloneFuzzTargetMain.c provides main() that reads one input file and calls
# LLVMFuzzerTestOneInput once. It is C, so compile it to an object WITHOUT -std=c++17 (clang
# rejects a C++ standard on a C input), then link it with the C++ harness via clang++.
STANDALONE_OBJ="$SRC/mayhem-tests-tmp-standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$STANDALONE_OBJ"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 $INC \
    "$HARNESS_DIR/fuzz_cppitertools.cpp" "$STANDALONE_OBJ" \
    -o "/mayhem/fuzz_cppitertools-standalone"
rm -f "$STANDALONE_OBJ"

echo "built fuzz_cppitertools (+ standalone)"

# ── 3) Build cppitertools' OWN Catch2 unit-test suite with NORMAL flags (clean, separate dir) so
#       mayhem/test.sh only RUNS it. The suite is real per-feature unit tests (test/test_*.cpp)
#       that assert iterator semantics — a no-op/stub patch cannot pass.
#
# The upstream CMake build hard-requires Boost (only test_zip_longest.cpp actually uses
# boost::optional) and a network-fetched catch.hpp. We avoid the Boost dependency by compiling the
# test_*.cpp files directly (excluding the single Boost-dependent one) into one `test_all` binary,
# and fetch catch.hpp (the only external dependency) at build time. ──────────────────────────────
TESTBUILD="$SRC/mayhem-tests"
mkdir -p "$TESTBUILD"

CATCH="$TESTBUILD/catch.hpp"
if [ ! -f "$CATCH" ]; then
  echo "fetching catch.hpp (Catch2 v2.13.10, single-header) ..."
  wget -qO "$CATCH" https://github.com/catchorg/Catch2/releases/download/v2.13.10/catch.hpp \
    || curl -fsSL -o "$CATCH" https://github.com/catchorg/Catch2/releases/download/v2.13.10/catch.hpp \
    || { echo "WARNING: could not download catch.hpp — test suite will not build" >&2; }
fi

if [ -s "$CATCH" ]; then
  # Compile every test_*.cpp EXCEPT test_zip_longest.cpp (the only file that needs Boost) plus
  # test_main.cpp (defines Catch's main). Normal flags (no sanitizers) — honest test oracle.
  SRCS=()
  for f in "$SRC"/test/test_*.cpp; do
    case "$(basename "$f")" in
      test_zip_longest.cpp) continue ;;   # needs boost::optional, unavailable in the base image
    esac
    SRCS+=("$f")
  done
  # test_main.cpp #includes "catch.hpp" with CATCH_CONFIG_MAIN; -I$TESTBUILD finds the fetched header,
  # -I$SRC/test finds helpers.hpp, -I$SRC finds the cppitertools adaptor headers.
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    "$CXX" -std=c++17 -O1 -I"$TESTBUILD" -I"$SRC/test" -I"$SRC" \
      "${SRCS[@]}" -o "$TESTBUILD/test_all"
  echo "built cppitertools unit-test suite -> $TESTBUILD/test_all (${#SRCS[@]} test files)"
else
  echo "WARNING: catch.hpp missing — unit-test suite not built (mayhem/test.sh will fail loudly)" >&2
fi

echo "build.sh complete:"
ls -la /mayhem/fuzz_cppitertools /mayhem/fuzz_cppitertools-standalone 2>&1 || true
