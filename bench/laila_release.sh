#!/usr/bin/env bash
# Release-11.10 timing of scalar (11.9) against the AVX2 build, on laila under hardware counters
# (cannabis-genome scripts/laila_perf.py runs each `run` command under pcount).
#
#   laila_release.sh pack OUT.tar.gz          (local) tar the three workloads' inputs, symlinks resolved
#   laila_release.sh build                    (in the job, from the bundle root) build base/ and simd/, unpack $DATA
#   laila_release.sh run KIND BUILD ROUND     (in the job) one timed run; KIND deep | piece03 | cannabis
#   laila_release.sh compare                  (in the job) every KIND must have one digest across builds and rounds
#
# Workloads:
#   deep      the cannabis deep merge, multiz M=1 left.maf right.maf (bench/data/wfi_profile/in)
#   piece03   hg38 100-way piece 03, roast as UCSC's autoMultiz.csh runs it (ucsc100way run03/inputs-v3, tree.nh)
#   cannabis  WF-I piece NW_022060449.1.00: all 216 species, the real tree, run by the multiz_roast UDT's own script
#             (bench/data/wfi_step4/NW_022060449.1), a second workload of a different kind from the human pieces
# Each run prints: RESULT kind build round wall_s user_s sys_s digest (sha256 of the output, '#' lines dropped).
set -euo pipefail
B=/home/rcb112/project/claude/bench/data
# bash's own `time` (the gcc image has no /usr/bin/time): wall user sys, written to a file by tm()
TIMEFORMAT='%R %U %S'
tm() { local f=$1; shift; { time "$@"; } 2> "$f"; }
# a failed run shows its stderr instead of dying silently under set -e
failrun() { echo "RUN FAILED rc=$1 $kind $build $round" >&2; cat "$d"/err "$d"/*/err 2> /dev/null | tail -20 >&2; exit 1; }
cmd=$1; shift
case $cmd in
pack)
	out=$1 st=$(mktemp -d)
	mkdir -p "$st/deep" "$st/piece03" "$st/cannabis/inputs"
	cp "$B/wfi_profile/in/left.maf" "$B/wfi_profile/in/right.maf" "$st/deep/"
	cp -L "$B"/ucsc100way/run03/inputs-v3/hg38.*.sing.maf "$st/piece03/"
	cp "$B/ucsc100way/tree.nh" "$st/piece03/tree.nh"
	P=$B/wfi_step4/NW_022060449.1
	cp -L "$P"/pieces/NW_022060449.1.00/*.maf "$st/cannabis/inputs/"
	cp "$P/roast/NW_022060449.1.00/tree.nh" "$P/roast/NW_022060449.1.00/multiz_roast.sh" "$st/cannabis/"
	tar -C "$st" -cf - deep piece03 cannabis | gzip -1 > "$out"
	rm -rf "$st"
	ls -l "$out"
	;;
build)
	for t in base simd; do make -s -C "$t" multiz roast maf_project > "build_$t.log" 2>&1 || { tail "build_$t.log"; exit 1; }; done
	mkdir -p data && tar -C data -xzf "$DATA"
	ls data/*
	;;
run)
	kind=$1 build=$2 round=$3 bin=$PWD/$build
	d=$PWD/runs/$kind.$build.$round
	rm -rf "$d"; mkdir -p "$d"
	case $kind in
	deep)
		tm "$d/time" sh -c '"$0" M=1 data/deep/left.maf data/deep/right.maf 0 "$1/U1.maf" "$1/U2.maf" > "$1/out.maf" 2> "$1/err"' \
			"$bin/multiz" "$d" || failrun $?
		dig=$(cat "$d/out.maf" "$d/U1.maf" "$d/U2.maf" | grep -v '^#' | sha256sum | cut -c1-64) ;;
	piece03)
		mkdir -p "$d/tmp"
		for f in "$PWD"/data/piece03/hg38.*.sing.maf; do ln -s "$f" "$d/"; done
		tree=$(cat data/piece03/tree.nh)
		(cd "$d" && PATH="$bin:$PATH" tm time sh -c 'roast + T="$0/tmp" E=hg38 "$1" hg38.*.sing.maf out.maf > /dev/null 2> err' "$d" "$tree") || failrun $?
		dig=$(grep -v '^#' "$d/out.maf" | sha256sum | cut -c1-64) ;;
	cannabis)
		files=$(ls "$PWD"/data/cannabis/inputs/*.maf | paste -sd, -)
		top=$PWD
		(cd "$d" && PATH="$bin:$PATH" tm time sh "$top/data/cannabis/multiz_roast.sh" cs10_NCBI_RefSeq_softmasked \
			"$top/data/cannabis/tree.nh" "$d/out.maf" "$files") > "$d/stdout" 2> "$d/err" || failrun $?
		dig=$(grep -v '^#' "$d/out.maf" | sha256sum | cut -c1-64) ;;
	*) echo "unknown kind $kind" >&2; exit 2 ;;
	esac
	read -r wall user sys < <(tail -1 "$d/time") # the last line is time's; any earlier ones are the command's stderr
	echo "RESULT $kind $build $round $wall $user $sys $dig" | tee -a runs/results.txt
	rm -rf "$d"
	;;
compare)
	rc=0
	for kind in $(awk '{print $2}' runs/results.txt | sort -u); do
		n=$(awk -v k="$kind" '$2 == k {print $8}' runs/results.txt | sort -u | wc -l)
		if [ "$n" = 1 ]; then echo "IDENTICAL $kind $(awk -v k="$kind" '$2 == k' runs/results.txt | wc -l) runs"
		else echo "DIFFER $kind: $n digests"; rc=1; fi
	done
	exit $rc
	;;
*) echo "usage: see the header" >&2; exit 2 ;;
esac
