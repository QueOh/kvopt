#!/usr/bin/env bash
#  SPDX-License-Identifier: BSD-3-Clause
#  Copyright (C) 2026 Samsung Electronics Co., Ltd.
#
# GPU-direct verification TARGET - run on the storage server (the JBOF
# stand-in; no GPU needed) with sudo. Brings up one NVMe-oF/RDMA
# subsystem with one malloc namespace: real backing store, so the
# deterministic pattern written by spdk_fixed_lba_read -W persists for
# the GPU node to read back.
#
#   sudo HUGEMEM=2048 <spdk>/scripts/setup.sh          # once per boot
#   sudo env TRADDR=<this server's RDMA IP> ./gpu_target.sh
#   sudo ./gpu_target.sh --teardown
#
# Environment overrides:
#   TRADDR    (required) RDMA-capable IP the GPU node can reach (RoCE)
#   TRTYPE    (RDMA)     spdk_gpu_read refuses anything else
#   TRSVCID   (4431)     disjoint from kvopt-bench (4430) and vslm (4420)
#   NQN       (nqn.2026-07.io.spdk:kvopt-gpu)
#   MALLOC_MB (256)      ns 1 backing store, 4 KiB blocks
#   CORE_MASK (0x3)      TGT_MEM_MB (1024)
#   SPDK_DIR  (kvopt spdk submodule next to this kit)
#   RPC_SOCK / PID_FILE / LOG_FILE (/var/tmp/kvopt_gpu_tgt.*)

set -euo pipefail

kitdir=$(readlink -f "$(dirname "$0")/..")
SPDK_DIR=${SPDK_DIR:-$(readlink -f "$kitdir/../../spdk")}

TRTYPE=${TRTYPE:-RDMA}
TRSVCID=${TRSVCID:-4431}
NQN=${NQN:-nqn.2026-07.io.spdk:kvopt-gpu}
MALLOC_MB=${MALLOC_MB:-256}
CORE_MASK=${CORE_MASK:-0x3}
TGT_MEM_MB=${TGT_MEM_MB:-1024}
RPC_SOCK=${RPC_SOCK:-/var/tmp/kvopt_gpu_tgt.sock}
PID_FILE=${PID_FILE:-/var/tmp/kvopt_gpu_tgt.pid}
LOG_FILE=${LOG_FILE:-/var/tmp/kvopt_gpu_tgt.log}

rpc() {
	"$SPDK_DIR/scripts/rpc.py" -s "$RPC_SOCK" "$@"
}

teardown() {
	if [[ -f "$PID_FILE" ]]; then
		local pid
		pid=$(cat "$PID_FILE")
		if kill -0 "$pid" 2> /dev/null; then
			kill "$pid"
			for _ in $(seq 1 50); do
				kill -0 "$pid" 2> /dev/null || break
				sleep 0.2
			done
			kill -9 "$pid" 2> /dev/null || true
		fi
		rm -f "$PID_FILE"
	fi
}

if [[ "${1:-}" == "--teardown" ]]; then
	teardown
	echo "kvopt GPU-direct target stopped"
	exit 0
fi

: "${TRADDR:?set TRADDR to the RDMA-capable IP of this server}"

# --- preflight -------------------------------------------------------
if [[ ! -x "$SPDK_DIR/build/bin/nvmf_tgt" ]]; then
	echo "nvmf_tgt not built. On this server:" >&2
	echo "  cd $SPDK_DIR && ./configure --with-rdma && make -j"'$(nproc)' >&2
	exit 1
fi
hp=$(awk '/^HugePages_Total/ {print $2}' /proc/meminfo)
if ((hp == 0)); then
	echo "no hugepages configured. Run once per boot:" >&2
	echo "  sudo HUGEMEM=2048 $SPDK_DIR/scripts/setup.sh" >&2
	exit 1
fi
if [[ "$TRTYPE" == "RDMA" ]] && command -v ibv_devinfo > /dev/null 2>&1; then
	if ! ibv_devinfo 2> /dev/null | grep -q "PORT_ACTIVE"; then
		echo "WARN: no RDMA port in PORT_ACTIVE state (link down?)" >&2
	fi
fi

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2> /dev/null; then
	echo "target already running (pid $(cat "$PID_FILE")); --teardown first" >&2
	exit 1
fi

# stale root-vs-user files break restarts under fs.protected_regular
rm -f "$LOG_FILE" "$PID_FILE"

"$SPDK_DIR/build/bin/nvmf_tgt" -m "$CORE_MASK" -r "$RPC_SOCK" -s "$TGT_MEM_MB" \
	> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

for _ in $(seq 1 100); do
	if rpc rpc_get_methods > /dev/null 2>&1; then
		break
	fi
	if ! kill -0 "$(cat "$PID_FILE")" 2> /dev/null; then
		echo "nvmf_tgt died during startup; see $LOG_FILE" >&2
		exit 1
	fi
	sleep 0.2
done

# same transport shape as the kvopt bench target: 1 MiB max I/O,
# 128 KiB io_unit; never pass -o
rpc nvmf_create_transport -t "$TRTYPE" -i 1048576 -u 131072
rpc bdev_malloc_create -b GpuData "$MALLOC_MB" 4096 > /dev/null
rpc nvmf_create_subsystem "$NQN" -a -s SPDKKVOPTGPU1 -m 8
rpc nvmf_subsystem_add_ns "$NQN" GpuData -n 1 > /dev/null
rpc nvmf_subsystem_add_listener "$NQN" -t "$TRTYPE" -a "$TRADDR" -s "$TRSVCID" -f ipv4

TRID="trtype:$TRTYPE adrfam:IPv4 traddr:$TRADDR trsvcid:$TRSVCID subnqn:$NQN"
echo "GPU-direct target ready:"
echo "  ns 1 = malloc ${MALLOC_MB} MiB @ 4 KiB blocks (pattern-capable)"
echo "  TRID: $TRID"
echo
echo "On the GPU node:"
echo "  sudo env TRADDR=$TRADDR TRSVCID=$TRSVCID $kitdir/setup/gpu_initiator.sh"
