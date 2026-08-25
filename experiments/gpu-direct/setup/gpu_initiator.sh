#!/usr/bin/env bash
#  SPDX-License-Identifier: BSD-3-Clause
#  Copyright (C) 2026 Samsung Electronics Co., Ltd.
#
# GPU-direct verification INITIATOR - run on the GPU node (e.g. DGX
# Spark) with sudo, against a server running setup/gpu_target.sh.
# Builds the tools, then runs the Milestone-1 gates in order:
#
#   [0] gpu_rdma_memory_test    DMA-BUF MR on the NIC's PD (go/no-go;
#                               fails here => GPU/NIC combo can't do it)
#   [1] spdk_fixed_lba_read -W  pattern -> target, host-memory readback
#                               (proves target + fabric, no GPU involved)
#   [2] spdk_gpu_read           the direct read: JBOF -> GPU memory,
#                               in-GPU checksum, digest-only readback
#   [3] spdk_gpu_read -X        poisoned registration MUST fail the I/O
#                               (a success = hidden fallback = hard FAIL)
#
#   sudo HUGEMEM=1024 <spdk>/scripts/setup.sh          # once per boot
#   sudo env TRADDR=<target's RDMA IP> ./gpu_initiator.sh
#
# Environment overrides:
#   TRADDR  (required)  TRSVCID (4431)  NQN (nqn.2026-07.io.spdk:kvopt-gpu)
#   NSID (1)  LBA (0)  BLOCKS (256 = 1 MiB)  GPU_ID (0)
#   IBDEV   ('' = first RDMA device) for the stage-8 test
#   SPDK_DIR (kvopt spdk submodule)  OUT (results/gpu-direct-<timestamp>)
#   SKIP_BUILD=1  SKIP_STAGE8=1

set -euo pipefail

kitdir=$(readlink -f "$(dirname "$0")/..")
SPDK_DIR=${SPDK_DIR:-$(readlink -f "$kitdir/../../spdk")}

: "${TRADDR:?set TRADDR to the RDMA IP of the target server}"
TRSVCID=${TRSVCID:-4431}
NQN=${NQN:-nqn.2026-07.io.spdk:kvopt-gpu}
NSID=${NSID:-1}
LBA=${LBA:-0}
BLOCKS=${BLOCKS:-256}
GPU_ID=${GPU_ID:-0}
IBDEV=${IBDEV:-}
OUT=${OUT:-$(readlink -f "$kitdir/../..")/results/gpu-direct-$(date +%Y%m%d-%H%M%S)}

TRID="trtype:RDMA adrfam:IPv4 traddr:$TRADDR trsvcid:$TRSVCID subnqn:$NQN"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# --- preflight -------------------------------------------------------
command -v nvcc > /dev/null 2>&1 || fail "nvcc not found - CUDA toolkit required on the GPU node"
command -v ibv_devinfo > /dev/null 2>&1 || fail "ibv_devinfo not found (install rdma-core)"
if ! ibv_devinfo 2> /dev/null | grep -q "PORT_ACTIVE"; then
	echo "WARN: no RDMA port in PORT_ACTIVE state (link down / no cable?)" >&2
fi
if ! ping -c 1 -W 2 "$TRADDR" > /dev/null 2>&1; then
	echo "WARN: $TRADDR does not answer ping (may still be reachable via RDMA)" >&2
fi
hp=$(awk '/^HugePages_Total/ {print $2}' /proc/meminfo)
if ((hp == 0)); then
	fail "no hugepages configured; run: sudo HUGEMEM=1024 $SPDK_DIR/scripts/setup.sh"
fi
if [[ ! -x "$SPDK_DIR/build/bin/spdk_fixed_lba_read" ]]; then
	fail "SPDK not built; run: cd $SPDK_DIR && ./configure --with-rdma && make -j"'$(nproc)'
fi

# --- build the GPU-node tools ---------------------------------------
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
	make -C "$kitdir/src" gpu_rdma_memory_test spdk_gpu_read
fi

mkdir -p "$OUT"
echo "results -> $OUT"
echo "TRID: $TRID"

# --- [0] stage-8 go/no-go: DMA-BUF MR on this NIC -------------------
if [[ "${SKIP_STAGE8:-0}" != 1 ]]; then
	echo "== [0] GPU RDMA registration (gpu_rdma_memory_test) =="
	"$kitdir/src/gpu_rdma_memory_test" ${IBDEV:+-d "$IBDEV"} -g "$GPU_ID" 2>&1 \
		| tee "$OUT/stage8_rdma_registration.log" \
		|| fail "DMA-BUF registration failed - this GPU/NIC pair cannot do GPUDirect (nothing downstream can pass)"
fi

# --- [1] pattern write + host-memory verify (target/fabric proof) ---
echo "== [1] write pattern via host memory (spdk_fixed_lba_read -W) =="
"$SPDK_DIR/build/bin/spdk_fixed_lba_read" -r "$TRID" -n "$NSID" -L "$LBA" -c "$BLOCKS" -W -J \
	| tee "$OUT/write_pattern.json" \
	|| fail "pattern write/readback failed - fix target/fabric before involving the GPU"
grep -q '"result":"PASS"' "$OUT/write_pattern.json" || fail "write_pattern.json is not a PASS"

# --- [2] the direct read: JBOF -> GPU memory ------------------------
echo "== [2] direct read -> GPU memory (spdk_gpu_read) =="
"$kitdir/src/spdk_gpu_read" -r "$TRID" -n "$NSID" -L "$LBA" -c "$BLOCKS" -g "$GPU_ID" -J \
	| tee "$OUT/gpu_read.json" \
	|| fail "direct GPU read failed (see stderr above and $OUT/gpu_read.json)"
grep -q '"result":"PASS"' "$OUT/gpu_read.json" || fail "gpu_read.json is not a PASS"

# --- [3] mandatory negative test (plan section 15) ------------------
echo "== [3] negative test: poisoned registration must FAIL the I/O =="
"$kitdir/src/spdk_gpu_read" -r "$TRID" -n "$NSID" -L "$LBA" -c "$BLOCKS" -g "$GPU_ID" -X -J \
	| tee "$OUT/negative_test.json" \
	|| fail "negative test: the I/O SUCCEEDED with a poisoned registration - hidden fallback, hard FAIL"
grep -q '"result":"PASS"' "$OUT/negative_test.json" || fail "negative_test.json is not a PASS"

echo
echo "ALL GATES PASS - direct NVMe-oF -> GPU memory path verified"
echo "JSON verdicts: $OUT/{write_pattern,gpu_read,negative_test}.json"
