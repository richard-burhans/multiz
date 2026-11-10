#!/bin/sh
# make check's yama fuzz test: tests/yama_fuzz/check.sh [TREE]
# Builds yama from TREE (default: this source tree) twice, as a scalar reference (-DYAMA_SIMD=0) and as the
# normal run-time-dispatch build, and requires byte-identical output on random cases (gen.py):
#   plain       seeds 1-3, 300 cases
#   fits32      seeds 301-302 with YAMA_FUZZ_GOP=2^28, so row coefficients pass 32 bits and the AVX2 rows
#               must fall back to scalar
#   fits32 idx  seeds 401-402 with YAMA_FUZZ_GOP_IDX=2, 0 and 8: one FITS32 check at a time (the shipped
#               gap table makes the checks imply each other; see main.c). These are the only cases that
#               catch a removed range check (tests/simd_mutation).
#   override    one plain seed with YAMA_SIMD=0 in the environment, which must force the scalar path
# On a CPU without AVX2 both builds run scalar and the comparison is vacuous; it says so. Needs python3.
# Prints PASS/FAIL lines and exits 1 on any FAIL, 0 otherwise (77 = skipped, no python3).
set -u
H=$(cd "$(dirname "$0")" && pwd)
T=$(cd "${1:-$H/../..}" && pwd) || exit 2
command -v python3 > /dev/null 2>&1 || { echo "SKIP yama fuzz (no python3)"; exit 77; }
W=$(mktemp -d "${TMPDIR:-/tmp}/yama-fuzz.XXXXXX") || exit 2
trap 'rm -rf "$W"' EXIT
trap 'exit 2' HUP INT TERM
GOP=268435456
# YAMA_FUZZ_CC and YAMA_FUZZ_CFLAGS (default gcc, -O2) choose the compiler and flags for both builds, so the
# sanitizer and compiler-matrix runs (tests/validate.sh) cover this check too.
FCC=${YAMA_FUZZ_CC:-gcc}
FCFLAGS=${YAMA_FUZZ_CFLAGS:--O2}
build() {
	$FCC $FCFLAGS -Wno-free-nonheap-object $2 -I"$T" "$H/main.c" "$T/mz_yama.c" "$T/mz_scores.c" "$T/util.c" \
		-o "$W/$1" || { echo "FAIL yama fuzz: cannot build $1"; exit 1; }
}
build ref -DYAMA_SIMD=0
build simd ""
if grep -q -w avx2 /proc/cpuinfo 2> /dev/null; then :; else
	echo "NOTE yama fuzz: this CPU has no AVX2, so both builds take the scalar path"
fi
fail=0
# cmpcase LABEL SEED NCASES [ENV...]: run both builds on gen.py SEED NCASES 200 under ENV, compare
cmpcase() {
	label=$1 seed=$2 nc=$3; shift 3
	python3 "$H/gen.py" "$seed" "$nc" 200 > "$W/in" || { echo "FAIL $label seed $seed: gen.py"; fail=1; return; }
	env "$@" "$W/ref" < "$W/in" > "$W/ref.out" 2>&1
	env "$@" "$W/simd" < "$W/in" > "$W/simd.out" 2>&1
	if [ -s "$W/ref.out" ] && cmp -s "$W/ref.out" "$W/simd.out"; then
		echo "PASS $label seed $seed"
	else
		echo "FAIL $label seed $seed"; fail=1
	fi
}
for s in 1 2 3; do cmpcase "yama fuzz plain" $s 300; done
for s in 301 302; do cmpcase "yama fuzz fits32" $s 300 YAMA_FUZZ_GOP=$GOP; done
for ix in 2 0 8; do
	for s in 401 402; do cmpcase "yama fuzz fits32 idx $ix" $s 300 YAMA_FUZZ_GOP=$GOP YAMA_FUZZ_GOP_IDX=$ix; done
done
# the run-time override: the dispatch build with YAMA_SIMD=0 must equal the scalar reference too
python3 "$H/gen.py" 7 300 200 > "$W/in"
"$W/ref" < "$W/in" > "$W/ref.out" 2>&1
YAMA_SIMD=0 "$W/simd" < "$W/in" > "$W/ov.out" 2>&1
if [ -s "$W/ref.out" ] && cmp -s "$W/ref.out" "$W/ov.out"; then echo "PASS yama fuzz override YAMA_SIMD=0"; else echo "FAIL yama fuzz override YAMA_SIMD=0"; fail=1; fi
exit $fail
