#!/usr/bin/env bash
# kvopt gather-scheme benchmark — REAL CLUSTER runner.
#
# Run on the INITIATOR (mode: local, per the platform contract). Drives the
# nvmf target on the DPU over SSH, runs kvopt_bench locally against
# TCP <TRADDR>:<TRSVCID>, keeps raw results on the initiator (air-gap), and
# prints a compact summary to type back.
#
#   bash run_kvopt_cluster.sh                       # SUITE=quick (verify + baseline xREPS)
#   SUITE=full bash run_kvopt_cluster.sh            # + chunk sweep + saturated QD sweeps
#   REPS, TIME_SEC, TRSVCID, TGT_CORE_MASK, ...     # see cluster_kvopt.env
set -uo pipefail
cd "$(dirname "$0")"
source ./cluster_kvopt.env

SSH=(ssh -o StrictHostKeyChecking=no -p "$DPU_SSH_PORT" "$DPU_SSH")
KV_REMOTE="$DPU_REPO/test/kvopt"
KV_LOCAL="$INIT_REPO/test/kvopt"
BENCH="$INIT_REPO/build/bin/kvopt_bench"
TRID="trtype:TCP adrfam:IPv4 traddr:$TRADDR trsvcid:$TRSVCID subnqn:$NQN"
MODES="partial copy-read slm-copy-read fused vector"
OUT="$RESULT_ROOT/$(date +%Y%m%d_%H%M%S)"

# environment for setup_target.sh on the DPU (sudo env: no -E/sudoers issues)
tgt_env="TRADDR=$TRADDR TRSVCID=$TRSVCID NQN=$NQN RPC_SOCK=$RPC_SOCK"
tgt_env="$tgt_env CORE_MASK=$TGT_CORE_MASK TGT_MEM_MB=$TGT_MEM_MB"
tgt_env="$tgt_env PID_FILE=/var/tmp/kvopt_tgt.pid LOG_FILE=/var/tmp/kvopt_tgt.log"

target_up() { # $1 = null|malloc
	"${SSH[@]}" "sudo rm -f /var/tmp/kvopt_tgt.log /var/tmp/kvopt_tgt.pid;
		sudo env $tgt_env SRC_BDEV=$1 bash '$KV_REMOTE/setup_target.sh'"
}
target_down() {
	"${SSH[@]}" "sudo env $tgt_env bash '$KV_REMOTE/setup_target.sh' --teardown" \
		> /dev/null 2>&1 || true
}
trap target_down EXIT

# ---------------- preflight ----------------
fail=0
[ -x "$BENCH" ] || { echo "preflight FAIL: $BENCH missing (run prepare)"; fail=1; }
"${SSH[@]}" "test -x '$DPU_REPO/build/bin/nvmf_tgt'" \
	|| { echo "preflight FAIL: DPU nvmf_tgt missing (run prepare)"; fail=1; }
if "${SSH[@]}" "ss -ltn 2>/dev/null | grep -q ':$TRSVCID '"; then
	echo "preflight FAIL: port $TRSVCID already listening on the DPU"; fail=1
fi
hp=$("${SSH[@]}" "awk '/HugePages_Free/ {print \$2}' /proc/meminfo" 2>/dev/null || echo 0)
if [ "${hp:-0}" -lt $((TGT_MEM_MB / 2)) ]; then
	echo "preflight WARN: DPU HugePages_Free=$hp may be short of TGT_MEM_MB=$TGT_MEM_MB"
fi
[ "$fail" -eq 0 ] || exit 1
mkdir -p "$OUT"
echo "[kvopt] provenance=$PROVENANCE suite=$SUITE results=$OUT"
echo "[kvopt] target: $DPU_SSH cores=$TGT_CORE_MASK mem=${TGT_MEM_MB}M -> $TRADDR:$TRSVCID"

# ---------------- phase 1: data verify (malloc sources) ----------------
echo "[kvopt] phase 1: data verify"
target_up malloc > "$OUT/target_verify.log"
for mode in $MODES; do
	if $BENCH -r "$TRID" -M "$mode" -V $APP_ARGS > "$OUT/verify_$mode.log" 2>&1; then
		echo "[kvopt] verify $mode PASS"
	else
		echo "[kvopt] verify $mode FAIL (see $OUT/verify_$mode.log)"; exit 1
	fi
done
target_down

# ---------------- phase 2: baseline x REPS (null sources) ----------------
echo "[kvopt] phase 2: baseline x$REPS (null sources, R=2 Q=1, C=128KiB)"
target_up null > "$OUT/target_bench.log"
for rep in $(seq 1 "$REPS"); do
	for mode in $MODES; do
		$BENCH -r "$TRID" -M "$mode" -t "$TIME_SEC" -w "$WARMUP_SEC" -R 2 -Q 1 \
			-c "$OUT/baseline.csv" $APP_ARGS > /dev/null
	done
	echo "[kvopt] baseline rep $rep/$REPS done"
done

# ---------------- phase 3 (SUITE=full): sweeps ----------------
if [ "$SUITE" = full ]; then
	export TRADDR TRSVCID NQN APP_ARGS
	echo "[kvopt] phase 3: chunk sweep (E1)"
	OUT="$OUT/chunk_sweep.csv" R=2 TIME=$TIME_SEC bash "$KV_LOCAL/sweep_chunk.sh" \
		> "$OUT/sweep_chunk.log" 2>&1
	echo "[kvopt] phase 4: saturated QD sweeps (E4/E5)"
	OUT="$OUT/qdsat_c128k.csv" C=32 K=8 R=8 QSLOTS=8 QDS="2 4 8 16 32 64" \
		TIME=$TIME_SEC bash "$KV_LOCAL/sweep_qd.sh" > "$OUT/sweep_qd_c128k.log" 2>&1
	OUT="$OUT/qdsat_c8k.csv" C=2 K=128 R=8 QSLOTS=8 QDS="2 4 8 16 32 64" \
		TIME=$TIME_SEC bash "$KV_LOCAL/sweep_qd.sh" > "$OUT/sweep_qd_c8k.log" 2>&1
fi

# ---------------- summary (type this back) ----------------
echo
echo "================ kvopt SUMMARY — type this back ================"
echo "provenance=$PROVENANCE fabric=TCP:$TRADDR:$TRSVCID reps=$REPS suite=$SUITE"
echo "workload: N=8 obj x 1MiB, C=128KiB, K=8, R=2, Q=1 (1 request = 8 MiB)"
awk -F, 'NR>1 && $8>0 { v[$1] = v[$1] " " $9/$8; n[$1]++ }
	END {
		for (m in v) {
			c = split(v[m], b, " ")
			for (i = 1; i <= c; i++) for (j = i+1; j <= c; j++)
				if (b[j]+0 < b[i]+0) { t = b[i]; b[i] = b[j]; b[j] = t }
			med = (c % 2) ? b[int((c+1)/2)] : (b[c/2] + b[c/2+1]) / 2
			printf "%-14s median %.0f req/s (%.0f MB/s) over %d reps\n", m, med, med*8, c
		}
	}' "$OUT/baseline.csv" | sort
echo "raw results stay on this host: $OUT"
echo "[kvopt] PASS"
