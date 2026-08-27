#!/usr/bin/env bash
#  SPDX-License-Identifier: BSD-3-Clause
#  Copyright (C) 2026 Samsung Electronics Co., Ltd.
#
# QD1 latency comparison TARGET - run on the storage server with sudo.
# Brings up an NVMe-oF subsystem with ONE null bdev namespace: no media,
# no memcpy - a read against it measures pure NVMe-oF stack + fabric
# latency, which is exactly what the comparison against raw RDMA needs.
#
#   sudo HUGEMEM=1024 <spdk>/scripts/setup.sh          # once per boot
#   sudo env TRADDR=<this server RDMA IP> ./lat_target.sh
#   sudo ./lat_target.sh --teardown
#
# The raw-RDMA leg needs an ib_write_lat SERVER on this host as well;
# the initiator script starts it over ssh (TGT_SSH=...) or tells you
# the exact command to run here manually.
#
# Environment overrides:
#   TRADDR    (required)  RDMA-capable IP the initiator can reach
#   TRTYPE    (RDMA)      TCP allowed for smoke tests
#   TRSVCID   (4432)      disjoint from kvopt-bench 4430 / gpu 4431
#   NQN       (nqn.2026-07.io.spdk:kvopt-lat)
#   CORE_MASK (0x3)  TGT_MEM_MB (512)  SPDK_DIR (kvopt spdk submodule)
#   RPC_SOCK / PID_FILE / LOG_FILE (/var/tmp/kvopt_lat_tgt.*)

set -euo pipefail

expdir=$(readlink -f "$(dirname "$0")")
SPDK_DIR=${SPDK_DIR:-$(readlink -f "$expdir/../../spdk")}

TRTYPE=${TRTYPE:-RDMA}
TRSVCID=${TRSVCID:-4432}
NQN=${NQN:-nqn.2026-07.io.spdk:kvopt-lat}
CORE_MASK=${CORE_MASK:-0x3}
TGT_MEM_MB=${TGT_MEM_MB:-512}
RPC_SOCK=${RPC_SOCK:-/var/tmp/kvopt_lat_tgt.sock}
PID_FILE=${PID_FILE:-/var/tmp/kvopt_lat_tgt.pid}
LOG_FILE=${LOG_FILE:-/var/tmp/kvopt_lat_tgt.log}

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
	echo "kvopt latency target stopped"
	exit 0
fi

: "${TRADDR:?set TRADDR to the RDMA-capable IP of this server}"

if [[ ! -x "$SPDK_DIR/build/bin/nvmf_tgt" ]]; then
	echo "nvmf_tgt not built. On this server:" >&2
	echo "  cd $SPDK_DIR && ./configure --with-rdma && make -j"'$(nproc)' >&2
	exit 1
fi
hp=$(awk '/^HugePages_Total/ {print $2}' /proc/meminfo)
if ((hp == 0)); then
	echo "no hugepages configured. Run once per boot:" >&2
	echo "  sudo HUGEMEM=1024 $SPDK_DIR/scripts/setup.sh" >&2
	exit 1
fi

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2> /dev/null; then
	echo "latency target already running (pid $(cat "$PID_FILE")); --teardown first" >&2
	exit 1
fi

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

# default transport settings on purpose: 4 KiB QD1 needs nothing special
# and defaults are what any "stock NVMe-oF" latency claim should use
rpc nvmf_create_transport -t "$TRTYPE"
rpc bdev_null_create Lat0 1024 4096 > /dev/null
rpc nvmf_create_subsystem "$NQN" -a -s SPDKKVOPTLAT1 -m 8
rpc nvmf_subsystem_add_ns "$NQN" Lat0 -n 1 > /dev/null
rpc nvmf_subsystem_add_listener "$NQN" -t "$TRTYPE" -a "$TRADDR" -s "$TRSVCID" -f ipv4

echo "latency target ready: trtype:$TRTYPE traddr:$TRADDR trsvcid:$TRSVCID"
echo "  ns 1 = null bdev (no media, protocol-only)"
echo
echo "On the initiator:"
echo "  sudo env TRADDR=$TRADDR TRSVCID=$TRSVCID $expdir/lat_initiator.sh"
echo
echo "For the raw-RDMA leg, the initiator either starts the server here"
echo "via ssh (TGT_SSH=user@host) or asks you to run manually on this host:"
echo "  ib_write_lat -R -s 4096 -n 10000 -F"
