#!/usr/bin/env bash
# Release validation of the AVX2 yama: sanitizers, valgrind, and a compiler/optimization matrix.
#
#   tests/validate.sh build NAME CC "CFLAGS"     build this tree (HEAD plus the working tree) into $VW/NAME
#   tests/validate.sh suite NAME [ENV...]        tests/run.sh and tests/yama_fuzz/check.sh against NAME, under ENV
#   tests/validate.sh deep NAME [ENV...]         the cannabis deep merge; prints the digest of its three outputs
#   tests/validate.sh fuzzdig NAME [ENV...]      digest of the yama fuzz driver's output on fixed seeds (built with NAME's CC/CFLAGS)
#   tests/validate.sh valgrind NAME              memcheck on tests/run.sh (every program wrapped) and on the deep merge
#   tests/validate.sh matrix                     every CC x CFLAGS build: suite, fuzz digest, deep digest, all equal
#   tests/validate.sh sanitize                   gcc and clang ASan+UBSan builds: suite and deep merge, both dispatch paths
#   tests/validate.sh sanitize-recover           the same, logging every report and continuing; zero reports from mz_yama.c required
#
# VW (default bench/data/tmp/simd_validate) holds the builds and logs. A sanitizer report makes the program exit
# nonzero (halt_on_error, -fno-sanitize-recover), so a clean suite means zero reports. Leak detection is OFF under
# ASan: multiz has always freed little at exit; `valgrind` compares leak totals of the scalar and AVX2 paths instead.
# The piece-03 workload is too big for this host under ASan; bench/laila_release.sh covers it on laila.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
T=$(cd "$H/.." && pwd)
VW=${VW:-/home/rcb112/project/claude/bench/data/tmp/simd_validate}
DEEP=${DEEP:-/home/rcb112/project/claude/bench/data/wfi_profile/in}
PROGS="all_bz lav2maf pair2tb single_cov2 blastzWrapper maf_project maf2lav maf2fasta maf_order mafFind get_standard_headers maf_checkThread tba roast multic multiz maf_sort get_covered"
export TMPDIR=$VW/tmp
mkdir -p "$TMPDIR"
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1:abort_on_error=0:exitcode=86}
export UBSAN_OPTIONS=${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1:exitcode=87}
SAN="-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g"
# the matrix: name, compiler, flags
MATRIX=(
	"gcc-O0 gcc -O0" "gcc-O2 gcc -O2" "gcc-O3 gcc -O3" "gcc-O3n gcc -O3 -march=native"
	"clang-O0 clang -O0" "clang-O2 clang -O2" "clang-O3 clang -O3" "clang-O3n clang -O3 -march=native"
)

cfg() { cat "$VW/$1/.cfg"; } # "CC|CFLAGS"

build() {
	local name=$1 cc=$2 cf=$3 d=$VW/$1
	rm -rf "$d"; mkdir -p "$d"
	# the tree as it is now: tracked files at their working-tree state
	(cd "$T" && git ls-files -z | xargs -0 tar -cf - --no-recursion) | tar -C "$d" -xf -
	make -s -C "$d" -j8 CC="$cc" CFLAGS="-Wall -Wextra $cf" $PROGS > "$d/.build.log" 2>&1 \
		|| { echo "BUILD FAILED $name"; tail -20 "$d/.build.log"; exit 1; }
	printf '%s|%s\n' "$cc" "$cf" > "$d/.cfg"
	echo "BUILT $name ($cc $cf)"
}

suite() {
	local name=$1; shift
	local c; c=$(cfg "$name")
	local r1=0 r2=0
	env "$@" sh "$T/tests/run.sh" "$VW/$name" > "$VW/$name/.suite.log" 2>&1 || r1=$?
	env "$@" YAMA_FUZZ_CC="${c%%|*}" YAMA_FUZZ_CFLAGS="${c#*|}" sh "$T/tests/yama_fuzz/check.sh" "$VW/$name" \
		> "$VW/$name/.fuzz.log" 2>&1 || r2=$?
	echo "SUITE $name $* run.sh=$(tail -1 "$VW/$name/.suite.log") rc=$r1 fuzz_rc=$r2 fuzz_fail=$(grep -c '^FAIL' "$VW/$name/.fuzz.log" || true)"
	[ $r1 = 0 ] && { [ $r2 = 0 ] || [ $r2 = 77 ]; }
}

deep() {
	local name=$1; shift
	local o=$VW/$name/.deep; rm -rf "$o"; mkdir -p "$o"
	env "$@" "$VW/$name/multiz" M=1 "$DEEP/left.maf" "$DEEP/right.maf" 0 "$o/U1.maf" "$o/U2.maf" > "$o/out.maf" 2> "$o/err" \
		|| { echo "DEEP FAILED $name rc=$?"; tail -20 "$o/err"; return 1; }
	echo "DEEP $name $* $(cat "$o/out.maf" "$o/U1.maf" "$o/U2.maf" | grep -v '^#' | sha256sum | cut -c1-16)"
	rm -f "$o"/*.maf
}

fuzzdig() {
	local name=$1; shift
	local c; c=$(cfg "$name")
	local cc=${c%%|*} cf=${c#*|} f=$VW/$name/.yama_fuzz
	$cc $cf -Wno-free-nonheap-object -I"$VW/$name" "$T/tests/yama_fuzz/main.c" "$VW/$name/mz_yama.c" \
		"$VW/$name/mz_scores.c" "$VW/$name/util.c" -o "$f" 2> /dev/null
	local dig
	dig=$(for s in 11 12 13; do python3 "$T/tests/yama_fuzz/gen.py" $s 300 200 | env "$@" "$f"; done | sha256sum | cut -c1-16)
	echo "FUZZ $name $* $dig"
}

valgrind_run() {
	local name=$1 v=$VW/$1.vg
	rm -rf "$v"; mkdir -p "$v/bin" "$v/logs"
	for p in $PROGS; do
		printf '#!/bin/sh\nexec valgrind -q --error-exitcode=99 --leak-check=no --log-file=%s/logs/%s.%%p "%s/%s" "$@"\n' \
			"$v" "$p" "$VW/$name" "$p" > "$v/bin/$p"
		chmod +x "$v/bin/$p"
	done
	sh "$T/tests/run.sh" "$v/bin" > "$v/suite.log" 2>&1 || true
	local errs; errs=$(cat "$v"/logs/* 2> /dev/null | grep -c 'ERROR SUMMARY\|Invalid\|uninitialised' || true)
	echo "VALGRIND suite $name: $(tail -1 "$v/suite.log"); memcheck error lines: $errs"
	for mode in simd scalar; do
		local envs=(); [ $mode = scalar ] && envs=(YAMA_SIMD=0)
		local rc=0
		env "${envs[@]}" valgrind --error-exitcode=99 --leak-check=summary --log-file="$v/deep.$mode.log" \
			"$VW/$name/multiz" M=1 "$DEEP/left.maf" "$DEEP/right.maf" 0 "$v/U1.maf" "$v/U2.maf" > "$v/out.maf" 2> /dev/null || rc=$?
		echo "VALGRIND deep $name $mode rc=$rc $(grep 'ERROR SUMMARY' "$v/deep.$mode.log" | sed 's/==[0-9]*==//') $(grep -E 'definitely lost|indirectly lost' "$v/deep.$mode.log" | sed 's/==[0-9]*==//' | tr -s ' ' | paste -sd';')"
		rm -f "$v"/*.maf
	done
}

cmd=${1:?usage: see the header}; shift
case $cmd in
build) build "$@" ;;
suite) suite "$@" ;;
deep) deep "$@" ;;
fuzzdig) fuzzdig "$@" ;;
valgrind) valgrind_run "$@" ;;
matrix)
	rc=0
	for m in "${MATRIX[@]}"; do set -- $m; n=$1 cc=$2; shift 2; build "$n" "$cc" "$*"; done
	for m in "${MATRIX[@]}"; do
		n=${m%% *}
		suite "$n" || rc=1
		fuzzdig "$n"; fuzzdig "$n" YAMA_SIMD=0
		deep "$n"
	done | tee "$VW/matrix.log"
	# every build and both paths must agree on the fuzz digest, and every build on the deep digest
	for k in FUZZ DEEP; do
		u=$(awk -v k=$k '$1 == k {print $NF}' "$VW/matrix.log" | sort -u | wc -l)
		echo "MATRIX $k distinct digests: $u"; [ "$u" = 1 ] || rc=1
	done
	grep -q '^SUITE.*rc=0 fuzz_rc=0' "$VW/matrix.log" || rc=1
	[ "$(grep -c '^SUITE' "$VW/matrix.log")" = "$(grep -c '^SUITE.*rc=0 fuzz_rc=0' "$VW/matrix.log")" ] || rc=1
	exit $rc
	;;
sanitize)
	rc=0
	for c in gcc clang; do
		build "san-$c" "$c" "-O1 $SAN"
		suite "san-$c" || rc=1
		suite "san-$c" YAMA_SIMD=0 || rc=1
		deep "san-$c" || rc=1
		deep "san-$c" YAMA_SIMD=0 || rc=1
	done 2>&1 | tee "$VW/sanitize.log"
	grep -q 'FAILED\|rc=[1-9]\|fuzz_rc=[1-9]' "$VW/sanitize.log" && rc=1
	exit $rc
	;;
sanitize-recover)
	# Like `sanitize`, but every report is logged and execution continues, so one pre-existing error elsewhere
	# (mz_preyama.c reads map4[-1]; see simd_row_prototype.md) cannot hide later ones. Each report is attributed to
	# its first frame in this tree; the requirement is ZERO reports from mz_yama.c, on both dispatch paths.
	rc=0
	command -v llvm-symbolizer > /dev/null && export ASAN_SYMBOLIZER_PATH=$(command -v llvm-symbolizer)
	for c in gcc clang; do
		n=sanr-$c
		build "$n" "$c" "-O1 -fsanitize=address,undefined -fsanitize-recover=all -fno-omit-frame-pointer -g"
		for mode in simd scalar; do
			envs=(); [ $mode = scalar ] && envs=(YAMA_SIMD=0)
			L=$VW/$n/.san.$mode; rm -rf "$L"; mkdir -p "$L"
			export ASAN_OPTIONS="detect_leaks=0:halt_on_error=0:log_path=$L/asan"
			export UBSAN_OPTIONS="halt_on_error=0:print_stacktrace=1:log_path=$L/ubsan"
			suite "$n" "${envs[@]}" || true
			deep "$n" "${envs[@]}" || true
			# tally: the first "#k ... in FUNC FILE:LINE" frame whose FILE is in the build tree, per report
			awk -v root="$VW/$n/" '
				/ERROR: AddressSanitizer|runtime error/ { want = 1; kind = ($0 ~ /runtime error/) ? "ubsan" : "asan"
					if (kind == "ubsan") { split($1, a, ":"); f = a[1]; sub(root, "", f); if (f != "") { print kind, f ":" a[2]; want = 0 } } next }
				want && /^ *#[0-9]+ / && index($0, root) { for (i = 1; i <= NF; i++) if (index($i, root)) { f = $i; sub(root, "", f); sub(/:[0-9]+$/, "", f); print kind, f; want = 0; break } }
			' "$L"/* 2> /dev/null | sort | uniq -c | sort -rn > "$L/tally"
			echo "TALLY $n $mode: $(awk '{printf "%s %s x%d; ", $2, $3, $1}' "$L/tally")"
			grep -q 'mz_yama\.c' "$L/tally" && { echo "FAIL $n $mode: a report from mz_yama.c"; rc=1; }
		done
	done 2>&1 | tee "$VW/sanitize_recover.log"
	grep -q '^FAIL' "$VW/sanitize_recover.log" && rc=1
	exit $rc
	;;
*) echo "unknown command $cmd" >&2; exit 2 ;;
esac
