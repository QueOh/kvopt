# kvopt — KV-cache gather offload for NVMe-oF

Design, implementation and benchmark of four schemes for gathering
N KV-cache objects per application request from an NVMe-oF JBoF:
parallel-partial reads (prior art), cross-namespace Copy + Read, a fused
Copy+Read pair, and a single-command **Vector Read** — plus the SLM copy
path as a comparison mode.

| | |
|---|---|
| `docs/design/` | §1 background, §2 proposed design, §3 evaluation setup — with PlantUML diagrams (rendered in `docs/design/diagrams/`) |
| `docs/RUNNING.md` | **how to run** every experiment (E1–E5) in each environment |
| `docs/ANALYSIS.md` | **how to analyze**: CSV schema, sanity invariants, method, reading guide, figure regeneration |
| `spdk/` | submodule — QueOh/spdk branch `kvopt`: nvmf target features, `kvopt_bench`, `test/kvopt/` scripts |
| `cpcs_paper/` | submodule — the paper repo; its `real_cluster.yaml` inventory is the default cluster setup |
| `experiments/cluster/` | air-gapped real-cluster kit (prepare + run, inventory-driven) |
| `experiments/vm-split/` | driver for the paper vagrant split env |
| `results/` | benchmark CSVs and figures (VM provenance) |
| `vm/` | dedicated build/bench VM (Vagrant) |

Quickstart: clone with `--recurse-submodules`, then follow
`docs/RUNNING.md`. Headline result so far (VM, protocol overhead):
Vector Read matches parallel-partial's throughput with 8x fewer
commands, leads it 1.76x at 4 KiB chunks, and is the only aggregated
scheme unaffected by small SQ depths (fused needs >= 2 usable slots;
at depth 2 it cannot run at all).
