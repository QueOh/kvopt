#!/usr/bin/env bash
# kvopt benchmark PREPARATION step (follows repro/prepare_cluster.sh).
# Deploys kvopt@COMMIT into DEDICATED repos on both hosts and builds
# nvmf_tgt + kvopt_bench. The existing cpcs_paper/spdk trees are used only
# as read-only seeds (git history + offline submodule sources) — never
# modified.
#
# Run on the INITIATOR (builds locally, SSHes to the DPU):
#
#   BUNDLE=/path/kvopt-thin.bundle bash prepare_kvopt_cluster.sh
#
# kvopt-thin.bundle (KBs) works when the seed repos contain the fork base
# 15c7d7063 (origin/cpcs); otherwise use kvopt-full.bundle.
# Env overrides: COMMIT, DPU_SSH, INIT_REPO, DPU_REPO, INIT_SEED_REPO,
#                DPU_SEED_REPO, BUNDLE
set -uo pipefail
cd "$(dirname "$0")"
source ./cluster_kvopt.env

COMMIT="${COMMIT:-d567787986a4ce1392133239a86967def78f9d84}"
BUNDLE="${BUNDLE:-}"
[ -n "$BUNDLE" ] || { echo "ERR: BUNDLE=<path to kvopt bundle> is required (air-gapped)"; exit 1; }
[ -f "$BUNDLE" ] || { echo "ERR: bundle not found: $BUNDLE"; exit 1; }
BUNDLE_BASENAME=$(basename "$BUNDLE")

# Emits the per-host deploy+build script. $1 = repo, $2 = seed repo,
# $3 = bundle path on that host.
gen() {
cat <<EOS
set -uo pipefail
H=\$(hostname -s)
SEED="$2"
[ -d "\$SEED/.git" ] || { echo "host=\$H ERR=no_seed_repo(\$SEED)"; exit 0; }

# 1) dedicated repo, cloned locally from the read-only seed
if [ ! -d "$1/.git" ]; then
  mkdir -p "\$(dirname "$1")"
  git clone --no-checkout "\$SEED" "$1" >/tmp/kvopt_prep_clone.log 2>&1 \
    || { echo "host=\$H ERR=clone_failed"; exit 0; }
fi
cd "$1"

# 2) import the kvopt commits from the bundle and check out pinned commit
git fetch "$3" 'refs/heads/kvopt:refs/heads/_kvopt_import' >/tmp/kvopt_prep_fetch.log 2>&1 \
  || { echo "host=\$H ERR=bundle_fetch (seed missing base? use kvopt-full.bundle)"; exit 0; }
git checkout -q $COMMIT 2>/tmp/kvopt_prep_co.log \
  || { echo "host=\$H ERR=commit_absent($COMMIT)"; exit 0; }

# 3) submodule sources from the seed (offline; copied once, read-only source)
for sub in dpdk isa-l isa-l-crypto ocf xnvme libvfio-user intel-ipsec-mb; do
  if [ -d "\$SEED/\$sub" ] && [ ! -e "\$sub/Makefile" ] && [ ! -e "\$sub/meson.build" ]; then
    rm -rf "\$sub"; cp -a "\$SEED/\$sub" "\$sub"
    rm -rf "\$sub/build" 2>/dev/null || true
  fi
done

# 4) build (TCP-only benchmark; same hygiene flags as the harness)
echo "[\$H] ./configure + make -j\$(nproc) (takes several minutes)..."
if ./configure --without-crypto --disable-tests --without-vfio-user >/tmp/kvopt_prep_cfg.log 2>&1 \
   && make -j\$(nproc) >/tmp/kvopt_prep_make.log 2>&1; then build=OK; else build=FAIL; fi

tgt=no;   [ -x build/bin/nvmf_tgt ]    && tgt=yes
bench=no; [ -x build/bin/kvopt_bench ] && bench=yes
echo "host=\$H head=\$(git rev-parse --short HEAD) nvmf_tgt=\$tgt kvopt_bench=\$bench build=\$build"
[ "\$build" = FAIL ] && echo "host=\$H FAILtail: \$(tail -n 3 /tmp/kvopt_prep_make.log 2>/dev/null | tr '\n' '|')"
EOS
}

echo "================ kvopt CLUSTER PREP ================"
echo "commit=$COMMIT bundle=$BUNDLE"
echo "deploying + building on initiator(local) and DPU($DPU_SSH) in parallel..."

scp -o StrictHostKeyChecking=no "$BUNDLE" "$DPU_SSH:/tmp/$BUNDLE_BASENAME" \
  || { echo "ERR: scp bundle to DPU failed"; exit 1; }

gen "$INIT_REPO" "$INIT_SEED_REPO" "$BUNDLE" | bash > /tmp/kvopt_prep_init.out 2>&1 &
P1=$!
gen "$DPU_REPO" "$DPU_SEED_REPO" "/tmp/$BUNDLE_BASENAME" \
  | ssh -o StrictHostKeyChecking=no "$DPU_SSH" bash > /tmp/kvopt_prep_dpu.out 2>&1 &
P2=$!
wait $P1; wait $P2

echo
echo "================ PREP SUMMARY — type this back ================"
echo "initiator: $(grep -E '^host=|ERR' /tmp/kvopt_prep_init.out | tail -1)"
echo "dpu:       $(grep -E '^host=|ERR' /tmp/kvopt_prep_dpu.out | tail -1)"
grep -h 'FAILtail' /tmp/kvopt_prep_init.out /tmp/kvopt_prep_dpu.out 2>/dev/null || true
