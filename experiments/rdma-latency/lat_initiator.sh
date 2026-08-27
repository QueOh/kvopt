#!/usr/bin/env bash
#  SPDX-License-Identifier: BSD-3-Clause
#  Copyright (C) 2026 Samsung Electronics Co., Ltd.
#
# QD1 latency comparison INITIATOR - run with sudo against lat_target.sh.
# Two legs, same NICs, same 4 KiB payload:
#
#   [A] NVMe-oF read, QD1, null bdev   (spdk_nvme_perf -q 1 -o 4096 -L)
#       = SEND(cmd) + target sw + RDMA WRITE(4 KiB) + SEND(cpl)
#   [B] raw RDMA write, ping-pong/2    (ib_write_lat -R -s 4096)
#       = one one-sided 4 KiB RDMA WRITE, no storage stack at all
#
# [A] minus [B] is the NVMe-oF stack cost on top of the fabric floor.
#
#   sudo HUGEMEM=1024 <spdk>/scripts/setup.sh          # once per boot
#   sudo env TRADDR=<target RDMA IP> TGT_SSH=user@host ./lat_initiator.sh
#
# Environment overrides:
#   TRADDR  (required)   TRSVCID (4432)   NQN (nqn.2026-07.io.spdk:kvopt-lat)
#   TRTYPE  (RDMA)       TCP allowed for smoke tests (raw leg auto-skipped)
#   SIZE    (4096)       IO size in bytes for BOTH legs
#   TIME    (20)         seconds for the NVMe-oF leg   WARMUP (2)
#   ITERS   (10000)      iterations for the raw leg
#   WORKLOAD (randread)  spdk_nvme_perf -w value
#   TGT_SSH ('')         user@host of the TARGET; if set, the raw-leg
#                        server is started there over ssh; if empty you
#                        are prompted to start it manually
#   RAW_EXTRA ('')       extra args for both ib_write_lat sides (e.g. -d mlx5_1)
#   SKIP_RAW=1 / SKIP_NVMF=1   run only one leg
#   SPDK_DIR (kvopt spdk submodule)  OUT (results/rdma-latency-<timestamp>)

set -euo pipefail

expdir=$(readlink -f "$(dirname "$0")")
SPDK_DIR=${SPDK_DIR:-$(readlink -f "$expdir/../../spdk")}

: "${TRADDR:?set TRADDR to the RDMA IP of the target server}"
TRSVCID=${TRSVCID:-4432}
NQN=${NQN:-nqn.2026-07.io.spdk:kvopt-lat}
TRTYPE=${TRTYPE:-RDMA}
SIZE=${SIZE:-4096}
TIME=${TIME:-20}
WARMUP=${WARMUP:-2}
ITERS=${ITERS:-10000}
WORKLOAD=${WORKLOAD:-randread}
TGT_SSH=${TGT_SSH:-}
RAW_EXTRA=${RAW_EXTRA:-}
OUT=${OUT:-$(readlink -f "$expdir/../..")/results/rdma-latency-$(date +%Y%m%d-%H%M%S)}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

mkdir -p "$OUT"
csv="$OUT/summary.csv"
echo "test,trtype,size_bytes,qd,avg_us,p50_us,p99_us,p999_us,min_us,max_us" > "$csv"
echo "results -> $OUT"

nvmf_avg="" raw_avg=""

# ---------- leg A: NVMe-oF read, QD1 --------------------------------
if [[ "${SKIP_NVMF:-0}" != 1 ]]; then
	[[ -x "$SPDK_DIR/build/bin/spdk_nvme_perf" ]] \
		|| fail "spdk_nvme_perf not built; run: cd $SPDK_DIR && ./configure --with-rdma && make -j"'$(nproc)'
	trid="trtype:$TRTYPE adrfam:IPv4 traddr:$TRADDR trsvcid:$TRSVCID subnqn:$NQN"
	echo "== [A] NVMe-oF $WORKLOAD, QD1, $SIZE B, ${TIME}s (trtype $TRTYPE) =="
	"$SPDK_DIR/build/bin/spdk_nvme_perf" -r "$trid" \
		-q 1 -o "$SIZE" -w "$WORKLOAD" -t "$TIME" -a "$WARMUP" -L -c 0x1 \
		2> "$OUT/nvmf_read_qd1.err" | tee "$OUT/nvmf_read_qd1.log" \
		|| fail "spdk_nvme_perf failed; see $OUT/nvmf_read_qd1.err"

	# 'Total   :  iops  MBps  avg  min  max' (all usec)
	read -r nvmf_avg nvmf_min nvmf_max <<< "$(awk '/^Total/ {print $(NF-2), $(NF-1), $NF}' "$OUT/nvmf_read_qd1.log")"
	# '-L' cutoff lines: ' 50.00000% :    12.345us'
	nvmf_p50=$(awk '/^ *50\.00000%/  {gsub("us","",$3); print $3; exit}' "$OUT/nvmf_read_qd1.log")
	nvmf_p99=$(awk '/^ *99\.00000%/  {gsub("us","",$3); print $3; exit}' "$OUT/nvmf_read_qd1.log")
	nvmf_p999=$(awk '/^ *99\.90000%/ {gsub("us","",$3); print $3; exit}' "$OUT/nvmf_read_qd1.log")
	[[ -n "$nvmf_avg" ]] || fail "could not parse spdk_nvme_perf output ($OUT/nvmf_read_qd1.log)"
	echo "nvmf_read,$TRTYPE,$SIZE,1,$nvmf_avg,${nvmf_p50:-},${nvmf_p99:-},${nvmf_p999:-},$nvmf_min,$nvmf_max" >> "$csv"
fi

# ---------- leg B: raw RDMA write ping-pong -------------------------
if [[ "${SKIP_RAW:-0}" == 1 ]]; then
	echo "== [B] raw RDMA write: skipped (SKIP_RAW=1) =="
elif [[ "$TRTYPE" != "RDMA" ]]; then
	echo "== [B] raw RDMA write: skipped (TRTYPE=$TRTYPE has no raw-RDMA equivalent) =="
else
	command -v ib_write_lat > /dev/null 2>&1 \
		|| fail "ib_write_lat not found; install perftest (apt install perftest) on BOTH hosts"
	echo "== [B] raw RDMA write, $SIZE B, $ITERS iters (ib_write_lat -R) =="
	if [[ -n "$TGT_SSH" ]]; then
		ssh "$TGT_SSH" "ib_write_lat -R -s $SIZE -n $ITERS -F $RAW_EXTRA" \
			> "$OUT/raw_write_lat.server.log" 2>&1 &
		server_pid=$!
		sleep 2
	else
		echo "start the server on the TARGET host now:"
		echo "  ib_write_lat -R -s $SIZE -n $ITERS -F $RAW_EXTRA"
		if [[ -t 0 ]]; then
			read -r -p "press ENTER when it is running... "
		else
			fail "no tty to wait on; set TGT_SSH=user@host so the server can be started over ssh"
		fi
	fi
	ib_write_lat -R -s "$SIZE" -n "$ITERS" -F $RAW_EXTRA "$TRADDR" \
		2>&1 | tee "$OUT/raw_write_lat.log" \
		|| fail "ib_write_lat client failed; is the server running on the target?"
	if [[ -n "${server_pid:-}" ]]; then
		wait "$server_pid" 2> /dev/null || true
	fi

	# data row: '#bytes #iter t_min t_max t_typical t_avg t_stdev [99% 99.9%]'
	read -r raw_min raw_max raw_p50 raw_avg raw_p99 raw_p999 <<< "$(awk -v s="$SIZE" \
		'$1 == s && NF >= 7 {print $3, $4, $5, $6, (NF >= 9 ? $8 : ""), (NF >= 9 ? $9 : "")}' \
		"$OUT/raw_write_lat.log")"
	[[ -n "$raw_avg" ]] || fail "could not parse ib_write_lat output ($OUT/raw_write_lat.log)"
	echo "raw_rdma_write,RDMA,$SIZE,1,$raw_avg,${raw_p50:-},${raw_p99:-},${raw_p999:-},$raw_min,$raw_max" >> "$csv"
fi

# ---------- summary --------------------------------------------------
echo
echo "==================== QD1 latency, $SIZE B ===================="
printf '%-16s %10s %10s %10s %10s\n' "test" "avg_us" "p50_us" "p99_us" "min_us"
if [[ -n "$nvmf_avg" ]]; then
	printf '%-16s %10s %10s %10s %10s\n' "nvmf_read" "$nvmf_avg" "${nvmf_p50:-n/a}" "${nvmf_p99:-n/a}" "$nvmf_min"
fi
if [[ -n "$raw_avg" ]]; then
	printf '%-16s %10s %10s %10s %10s\n' "raw_rdma_write" "$raw_avg" "${raw_p50:-n/a}" "${raw_p99:-n/a}" "$raw_min"
fi
if [[ -n "$nvmf_avg" && -n "$raw_avg" ]]; then
	awk -v n="$nvmf_avg" -v r="$raw_avg" 'BEGIN {
		printf "\nNVMe-oF stack cost over the fabric floor: %.2f us (%.2fx of raw)\n", n - r, n / r
	}'
fi
echo "CSV: $csv"
