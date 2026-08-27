#!/usr/bin/env bash
#  SPDX-License-Identifier: BSD-3-Clause
#  Copyright (C) 2026 Samsung Electronics Co., Ltd.
#
# Runs lat_initiator.sh across a size sweep (default 4 KiB -> 1 MiB,
# x2 per step) and merges the results into one CSV plus a pivot table
# of the NVMe-oF stack tax per size.
#
#   sudo env TRADDR=<target RDMA IP> TGT_SSH=user@host ./lat_sweep.sh
#
# Takes every lat_initiator.sh variable, plus:
#   SIZES     ("4096 8192 ... 1048576")  space-separated bytes
#   SWEEP_OUT (results/rdma-latency-sweep-<timestamp>)
#   TIME      (10) seconds per size for the NVMe-oF leg
#
# Without TGT_SSH you will be prompted once per size to start the
# ib_write_lat server on the target - set TGT_SSH to avoid 9 prompts.

set -euo pipefail

expdir=$(readlink -f "$(dirname "$0")")

: "${TRADDR:?set TRADDR to the RDMA IP of the target server}"
SIZES=${SIZES:-4096 8192 16384 32768 65536 131072 262144 524288 1048576}
TIME=${TIME:-10}
SWEEP_OUT=${SWEEP_OUT:-$(readlink -f "$expdir/../..")/results/rdma-latency-sweep-$(date +%Y%m%d-%H%M%S)}

mkdir -p "$SWEEP_OUT"
csv="$SWEEP_OUT/sweep.csv"
echo "test,trtype,size_bytes,qd,avg_us,p50_us,p99_us,p999_us,min_us,max_us" > "$csv"

failed=""
for s in $SIZES; do
	echo
	echo "######## SIZE $s B ########"
	if OUT="$SWEEP_OUT/size-$s" SIZE="$s" TIME="$TIME" "$expdir/lat_initiator.sh"; then
		tail -n +2 "$SWEEP_OUT/size-$s/summary.csv" >> "$csv"
	else
		echo "size $s FAILED - continuing with the rest" >&2
		failed="$failed $s"
	fi
done

echo
echo "==================== stack tax by size ===================="
awk -F, -v sizes="$SIZES" '
	NR > 1 && $1 == "nvmf_read"      { n[$3] = $5 }
	NR > 1 && $1 == "raw_rdma_write" { r[$3] = $5 }
	END {
		printf "%10s %13s %13s %10s %8s\n", "size_B", "nvmf_avg_us", "raw_avg_us", "tax_us", "ratio"
		split(sizes, order, " ")
		for (i = 1; i in order; i++) {
			s = order[i]
			if (s in n && s in r) {
				printf "%10d %13.2f %13.2f %10.2f %8.2f\n", s, n[s], r[s], n[s] - r[s], n[s] / r[s]
			} else if (s in n) {
				printf "%10d %13.2f %13s %10s %8s\n", s, n[s], "n/a", "n/a", "n/a"
			}
		}
	}' "$csv"
if [[ -n "$failed" ]]; then
	echo "FAILED sizes:$failed" >&2
fi
echo "CSV: $csv"
