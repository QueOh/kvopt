# kvopt — High-Level Design

## §3 Evaluation Setup (VM protocol-overhead benchmark)

All experiments run on a single VM (protocol overhead only — null-bdev
sources, TCP loopback), using `app/kvopt_bench` from the `kvopt` branch.
This section records how each experiment was executed.

### 3.1 Harness topology

One initiator process and one target process share the VM, pinned to
separate cores. The benchmark app uses a single thread and a single I/O
qpair whose size (`-D`) models the device submission-queue depth limit.

```plantuml
@startuml eval-harness
skinparam componentStyle rectangle
skinparam shadowing false

node "kvopt-bench VM — VirtualBox, Ubuntu 22.04 arm64, 4 vCPU / 4 GB" {
  node "core 1 — kvopt_bench (initiator, --no-huge -s 512)" {
    component "workload engine\n(single thread)\nQ request slots ×\nR rounds in flight" as ENG
    queue "I/O SQ — one qpair\n**depth = QD** (-D)\nexcess commands wait\nFIFO in the initiator" as SQ
  }
  node "core 0 — nvmf_tgt (target, HUGEMEM=1024)" {
    component "NVMe-oF/TCP transport\nmax_io_size = 1 MiB\nio_unit = 128 KiB" as TR
    database "ns 1..8\nnull bdevs (sources)\n4 KiB blocks, obj i on ns i" as SRC
    database "ns 9: Staging\nmalloc 64 MiB" as STG
    database "ns 10: SLM\n64 MiB, byte-addressed" as SLM
  }
}

ENG -right-> SQ
SQ -right-> TR : TCP loopback\n127.0.0.1:4420
TR -down-> SRC
TR -down-> STG
TR -down-> SLM

note bottom of SRC
  data-verify runs swap the sources to
  malloc bdevs (8 MiB) + written pattern
end note
@enduml
```

### 3.2 Workload decomposition

One *application request* fetches N = 8 objects of S = 1 MiB each
(8 MiB per request, all modes, all experiments). A request is served as
K = S / C *chunk rounds* ("batches"); batch `c` fetches chunk `c`
(C bytes) of all 8 objects — payload N × C per batch.

```plantuml
@startuml eval-workload
skinparam shadowing false

rectangle "**Q request slots** (concurrent requests, independent)" as SLOTS
rectangle "application request\n= N = 8 objects × S = 1 MiB = **8 MiB**" as REQ
rectangle "chunk round (batch) c\n= chunk c of all 8 objects\npayload **N × C** (32 KiB .. 1 MiB)\nobject i, chunk c → ns i, LBA c·C" as ROUND

SLOTS --> REQ : per slot: one request\nat a time, back-to-back
REQ --> ROUND : **K = S / C** batches,\nissued in order,\n**≤ R in flight** per slot

note right of ROUND
  commands per batch on the one SQ
  |= mode          |= commands                     |= SQEs |
  | partial        | 8 chunk READs                 | 8     |
  | copy-read      | Copy (fmt 2h) → READ          | 2     |
  | slm-copy-read  | SLM Copy → SLM Read           | 2     |
  | fused          | Copy + READ fused pair        | 2     |
  | vector         | Vector Read 0x86              | 1     |
end note
@enduml
```

### 3.3 Command-issue rules

```plantuml
@startuml eval-issue-model
skinparam shadowing false
participant "request slot\n(engine)" as ENG
participant "I/O SQ\n(depth QD)" as SQ
participant "target" as TGT

group batch c — intra-batch issue rule
  ENG -> SQ : partial: 8 READs back-to-back, no waits\nfused: Copy + READ submitted adjacently\nvector: single command
  ENG -> SQ : copy-read / slm-copy-read only:\nCopy first — READ submitted\n**after the Copy completion** arrives
  SQ -> TGT : ≤ QD commands on the wire;\nthe rest queue FIFO at the initiator
end

group batch c+1 — pipelining rule
  ENG -> SQ : issued while batch c is still in flight,\nin order, up to **R** batches per slot
end

TGT --> ENG : batch done = last completion of its batch
note over ENG, TGT
  request done = all K batches done; the slot immediately starts
  the next request (Q slots independent). Latency stamps: batch =
  first submit → last completion; request = first batch submit →
  last batch completion. Stats reset after the warmup window.
end note
@enduml
```

### 3.4 Experiment matrix

Common: N = 8 objects, 4 KiB blocks, request = 8 MiB, single qpair,
10 s measurement + 2 s warmup per point, target 1 core / initiator
1 core, zero data errors accepted.

```plantuml
@startuml eval-matrix
skinparam shadowing false
note as M
  |= experiment |= chunk C |= K = S/C |= R |= Q |= SQ depth (QD) |= swept axis |
  | baseline, pipelined      | 128 KiB       | 8       | 2 | 1 | default (256) | — |
  | baseline, isolated batch | 128 KiB       | 8       | 1 | 1 | default       | — |
  | E1: chunk-size sweep     | 4..128 KiB    | 256..8  | 2 | 1 | default       | C ∈ {4,8,16,32,64,128} KiB |
  | E2: SQ-depth sweep       | 128 KiB       | 8       | 4 | 4 | 2..64         | QD ∈ {2,4,8,16,32,64} |
  | E3: SQ × small chunk     | 8 KiB         | 128     | 4 | 4 | 2..32         | QD ∈ {2,4,8,16,32} |
  | E4: saturated SQ, byte-bound    | 128 KiB | 8   | 8 | 8 | 2..64 | QD; all modes offer ≥ 64 outstanding |
  | E5: saturated SQ, command-bound | 8 KiB   | 128 | 8 | 8 | 2..64 | QD; all modes offer ≥ 64 outstanding |
end note

note as N2
  offered SQ load (max outstanding commands wanted):
  partial = 8 × R × Q  (E2/E3: **128**)   fused = 2 × R × Q (32)
  copy modes = 1 × R × Q per phase (16)   vector = R × Q (**16**)
  E1 stresses command amplification (partial: 8 × S/C up to 2048
  commands per request); E2/E3 stress the SQ limit — E3 in the
  command-bound regime where partial must serialize through the queue.
end note

M -[hidden]down- N2
@enduml
```

Result CSVs: `results/kvopt-vm-loopback-*.csv` (baselines),
`results/kvopt-vm-chunk-sweep-*.csv` (E1), `results/kvopt-vm-qd-sweep-*.csv`
(E2), `results/kvopt-vm-qd-c8k-sweep-*.csv` (E3), `results/kvopt-vm-qdsat-*.csv` (E4/E5). Scripts:
`test/kvopt/run_benchmark.sh`, `sweep_chunk.sh`, `sweep_qd.sh` in the
`kvopt` SPDK branch.
