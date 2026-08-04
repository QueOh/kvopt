#!/usr/bin/env bash
# One-shot fabric comparison: run the kvopt suite over RDMA and over TCP
# back-to-back on the cluster and print one combined type-back table.
#
# Run on the INITIATOR:
#
#   bash compare_fabrics.sh                 # SUITE=quick per leg (verify + baseline xREPS)
#   REPS=3 TIME_SEC=10 bash compare_fabrics.sh
#   SUITE=full bash compare_fabrics.sh      # adds the sweeps to each leg
#
# Leg addresses (override with RDMA_TRADDR / TCP_TRADDR):
#   RDMA -> nvmeof.traddr from the inventory (the data path)
#   TCP  -> hosts.target.ssh_host (the mgmt address TCP is known to reach)
# A failing leg (e.g. the RoCE fabric not establishing) is reported as
# FAILED and the other leg still runs — that outcome is itself data.
set -uo pipefail
cd "$(dirname "$0")"
source ./cluster_kvopt.env

STAMP=$(date +%Y%m%d_%H%M%S)
ROOT="$RESULT_ROOT/fabric_cmp_$STAMP"
RDMA_TRADDR="${RDMA_TRADDR:-${_INV_TRADDR:-10.10.100.1}}"
TCP_TRADDR="${TCP_TRADDR:-${_INV_DPU_HOST:-10.1.10.37}}"
mkdir -p "$ROOT"

declare -A leg_rc
run_leg() { # $1 = fabric, $2 = traddr
	echo
	echo "########## leg: $1 @ $2 ##########"
	TRTYPE="$1" TRADDR="$2" OUT="$ROOT/$1" bash ./run_kvopt_cluster.sh
	leg_rc[$1]=$?
	echo "########## leg $1 finished rc=${leg_rc[$1]} ##########"
}

run_leg RDMA "$RDMA_TRADDR"
run_leg TCP "$TCP_TRADDR"

echo
echo "================ FABRIC COMPARISON — type this back ================"
echo "provenance=$PROVENANCE reps=$REPS suite=$SUITE"
echo "RDMA @ $RDMA_TRADDR:$TRSVCID rc=${leg_rc[RDMA]}   TCP @ $TCP_TRADDR:$TRSVCID rc=${leg_rc[TCP]}"
echo "workload: N=8 obj x 1MiB, C=128KiB, K=8, R=2, Q=1 (1 request = 8 MiB)"

awk -F, '
function median(s,	n, a, i, j, t) {
	n = split(s, a, " ")
	for (i = 1; i <= n; i++)
		for (j = i + 1; j <= n; j++)
			if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
	return (n % 2) ? a[int((n + 1) / 2)] : (a[n / 2] + a[n / 2 + 1]) / 2
}
FNR == 1 { fab = (FILENAME ~ /RDMA/) ? "RDMA" : "TCP"; next }
$8 > 0 && $9 / $8 >= 10 { v[fab "," $1] = v[fab "," $1] " " $9 / $8 }
END {
	nm = split("partial copy-read slm-copy-read fused vector", M, " ")
	printf "%-14s %12s %12s %10s\n", "mode", "RDMA req/s", "TCP req/s", "RDMA/TCP"
	for (i = 1; i <= nm; i++) {
		m = M[i]
		kr = "RDMA," m; kc = "TCP," m
		r = (kr in v) ? median(v[kr]) : 0
		c = (kc in v) ? median(v[kc]) : 0
		printf "%-14s %12s %12s %10s\n", m, \
			(r ? sprintf("%.0f", r) : "FAILED"), \
			(c ? sprintf("%.0f", c) : "FAILED"), \
			((r && c) ? sprintf("%.2fx", r / c) : "-")
	}
}' "$ROOT/RDMA/baseline.csv" "$ROOT/TCP/baseline.csv" 2> /dev/null \
	|| echo "(no baseline data to compare — check the leg logs under $ROOT)"

echo "raw results stay on this host: $ROOT"
