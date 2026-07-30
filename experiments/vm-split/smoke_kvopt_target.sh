#!/usr/bin/env bash
# kvopt gather-scheme benchmark, loopback on the split-env target VM.
#
# Uses a namespace fully disjoint from the vslm/cpcs work:
#   SPDK tree   /home/vagrant/kvopt-spdk        (NOT ~/spdk)
#   RPC sock    /var/tmp/kvopt_tgt.sock
#   listener    127.0.0.1:4430                  (4420 stays with vslm/cpcs)
#   NQN         nqn.2026-07.io.spdk:kvopt-bench
#   cores       target 0x4, bench app 0x8 (hugepage-free)
#   results     ~/kvopt_results/<stamp>/
#
# Host usage (from experiments/vagrant_split_env, like `manage.sh smoke`):
#   cat smoke_kvopt_target.sh | vagrant ssh target -c \
#     'cat > /tmp/smoke_kvopt_target.sh && SUITE=quick bash /tmp/smoke_kvopt_target.sh'
# SUITE=quick (default): data-verify all modes + 5-mode baseline (~4 min)
# SUITE=full : adds chunk sweep + saturated QD sweeps (~30 min)

set -euo pipefail

SPDK="${KVOPT_SPDK:-$HOME/kvopt-spdk}"
KV="$SPDK/test/kvopt"
SUITE="${SUITE:-quick}"
OUT="$HOME/kvopt_results/$(date +%Y%m%d_%H%M%S)"

export TRADDR=127.0.0.1
export TRSVCID=4430
export NQN="nqn.2026-07.io.spdk:kvopt-bench"
export RPC_SOCK=/var/tmp/kvopt_tgt.sock
export PID_FILE=/var/tmp/kvopt_tgt.pid
export LOG_FILE=/tmp/kvopt_tgt.log
export CORE_MASK=0x4
export TGT_MEM_MB=1024
APP_ARGS="-m 0x8 -H -s 512"
export APP_ARGS

MODES="partial copy-read slm-copy-read fused vector"
TRID="trtype:TCP adrfam:IPv4 traddr:$TRADDR trsvcid:$TRSVCID subnqn:$NQN"
BENCH="$SPDK/build/bin/kvopt_bench"

[[ -x "$BENCH" && -x "$SPDK/build/bin/nvmf_tgt" ]] || {
	echo "[kvopt] FAIL: $SPDK not built (need build/bin/{nvmf_tgt,kvopt_bench})"
	exit 1
}

cleanup() { sudo -E "$KV/setup_target.sh" --teardown > /dev/null 2>&1 || true; }
trap cleanup EXIT

# Never shrink the provisioned hugepage pool (vslm work owns 2048 pages);
# only top up if the pool is unexpectedly tiny.
total=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
if [[ "${total:-0}" -lt 512 ]]; then
	sudo sysctl -w vm.nr_hugepages=512
fi

mkdir -p "$OUT"
echo "[kvopt] results dir: $OUT (suite: $SUITE)"

# fs.protected_regular: root cannot reopen a stale vagrant-owned log in
# sticky /tmp — always start from a fresh file
sudo rm -f "$LOG_FILE" "$PID_FILE"

echo "[kvopt] phase 1: data verify (malloc sources)"
sudo -E SRC_BDEV=malloc "$KV/setup_target.sh" > "$OUT/target_verify.log"
for mode in $MODES; do
	if $BENCH -r "$TRID" -M "$mode" -V $APP_ARGS > "$OUT/verify_$mode.log" 2>&1; then
		echo "[kvopt] verify $mode PASS"
	else
		echo "[kvopt] verify $mode FAIL (see $OUT/verify_$mode.log)"
		exit 1
	fi
done
sudo -E "$KV/setup_target.sh" --teardown > /dev/null

echo "[kvopt] phase 2: baseline benchmark (null sources, R=2 Q=1)"
sudo -E SRC_BDEV=null "$KV/setup_target.sh" > "$OUT/target_bench.log"
for mode in $MODES; do
	$BENCH -r "$TRID" -M "$mode" -t 10 -w 2 -R 2 -Q 1 \
		-c "$OUT/baseline.csv" $APP_ARGS > /dev/null
	echo "[kvopt] baseline $mode done"
done

if [[ "$SUITE" == "full" ]]; then
	echo "[kvopt] phase 3: chunk sweep (E1)"
	OUT="$OUT/chunk_sweep.csv" R=2 "$KV/sweep_chunk.sh" > "$OUT/sweep_chunk.log" 2>&1
	echo "[kvopt] phase 4: saturated QD sweeps (E4/E5)"
	OUT="$OUT/qdsat_c128k.csv" C=32 K=8 R=8 QSLOTS=8 QDS="2 4 8 16 32 64" \
		"$KV/sweep_qd.sh" > "$OUT/sweep_qd_c128k.log" 2>&1
	OUT="$OUT/qdsat_c8k.csv" C=2 K=128 R=8 QSLOTS=8 QDS="2 4 8 16 32 64" \
		"$KV/sweep_qd.sh" > "$OUT/sweep_qd_c8k.log" 2>&1
fi

echo "[kvopt] PASS  results: $OUT"
ls -la "$OUT"
