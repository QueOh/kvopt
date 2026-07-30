# kvopt — High-Level Design

## §1 Background

### 1.1 System context

Three participants cooperate to serve data to an AI workload:

- **Application** — the AI workload running on GPU (e.g., LLM inference). It consumes
  *objects* (e.g., KV cache entries). Because the workload is highly parallel
  (batched requests, many concurrent sequences), a single application request
  typically names **multiple objects at once**.
- **KV cache layer (KVCache / LMCache)** — manages data movement on behalf of the
  application. Today it locates the data blocks that make up each requested object,
  reads them from the JBoF over NVMe-oF, assembles complete objects, and returns
  them to the application.
- **NVMe-oF JBoF** — a disaggregated flash enclosure holding the actual data
  blocks, reached over an NVMe-oF fabric (RDMA or TCP).

```plantuml
@startuml system-context
skinparam componentStyle rectangle
skinparam shadowing false

node "GPU server" {
  component "Application\n(AI workload on GPU)" as APP
  component "KV cache layer\n(KVCache / LMCache)" as CACHE
}

node "NVMe-oF JBoF" {
  component "NVMe-oF target" as TGT
  database "SSD 1" as S1
  database "SSD 2" as S2
  database "SSD m" as SM
}

APP -down-> CACHE : get(obj_1 .. obj_N)\n(one request, N objects)
CACHE -right-> TGT : NVMe-oF read commands\n(RDMA / TCP fabric)
TGT -down-> S1 : block reads
TGT -down-> S2
TGT -down-> SM
@enduml
```

### 1.2 Terminology and working parameters

| Symbol | Meaning | Running example |
|--------|---------|-----------------|
| `N` | objects named in one application request | 8 |
| `S` | object size | 1 MiB |
| `C` | chunk size — the amount of data one computation step consumes | 128 KiB |
| `K = S / C` | chunks per object | 8 |
| block | unit in which object data is stored on / read from the JBoF SSDs | — |

One computation *step* in the application operates on one chunk (`C`) of each
object. A *chunk round* `c` means "chunk index `c` of every requested object",
i.e., `N × C` bytes in total.

### 1.3 The problem: serialized gathering stalls the GPU

When the cache layer's gathering process is serialized, the application cannot
start computing until objects have been fully assembled. The fabric transfer and
the GPU computation run back-to-back instead of overlapping, and the GPU idles
for the entire transfer phase.

```plantuml
@startuml baseline-serialized
skinparam shadowing false
participant "Application\n(GPU)" as APP
participant "KV cache layer" as CACHE
participant "NVMe-oF JBoF" as JBOF

APP -> CACHE : get(obj_1 .. obj_N)
loop objects i = 1 .. N, gathered one after another
  loop blocks of obj_i
    CACHE -> JBOF : read(block)
    JBOF --> CACHE : data
  end
  note right of CACHE : assemble obj_i
end
CACHE --> APP : obj_1 .. obj_N (complete objects)
note over APP
  computation starts only after
  **all** gathering completes
  → GPU idle during transfer
end note
@enduml
```

### 1.4 Prior art: parallel-partial read

A previous study addresses the stall by pipelining transfer and computation at
**chunk granularity**. Since one computation step needs only `C = 128 KiB` of
each `S = 1 MiB` object, the cache layer does not wait for complete objects.
Instead, per chunk round it collects chunk `c` of **every** requested object and
returns those `N` partial objects to the application in a row. The application
runs computation step `c` while the cache layer is already transferring chunk
round `c + 1`.

```plantuml
@startuml prior-art-parallel-partial
skinparam shadowing false
participant "Application\n(GPU)" as APP
participant "KV cache layer" as CACHE
participant "NVMe-oF JBoF" as JBOF

APP -> CACHE : get(obj_1 .. obj_N)
loop chunk round c = 1 .. K
  par N chunk reads issued concurrently
    CACHE -> JBOF : read(obj_1, chunk c)
  else
    CACHE -> JBOF : read(obj_2, chunk c)
  else
    CACHE -> JBOF : read(obj_N, chunk c)
  end
  JBOF --> CACHE : N completions, one per chunk
  CACHE --> APP : chunk c of obj_1 .. obj_N
  note right of APP : compute step c overlaps\nwith transfer of round c+1
end
note over CACHE, JBOF
  NVMe-oF commands per application request:
  **N × K = N × S / C** (example: 8 × 8 = **64**)
end note
@enduml
```

With transfer time and compute time per round roughly balanced, pipelining hides
most of the transfer behind computation:

```plantuml
@startuml pipeline-timing
skinparam shadowing false
scale 1 as 60 pixels
concise "Serialized: fabric transfer" as ST
concise "Serialized: GPU compute" as SG
concise "Pipelined: fabric transfer" as PT
concise "Pipelined: GPU compute" as PG

@0
ST is "transfer obj_1..obj_N (K rounds back-to-back)"
SG is idle
PT is c1
PG is idle
@1
PT is c2
PG is s1
@2
PT is c3
PG is s2
@3
PT is c4
PG is s3
@4
PT is c5
PG is s4
@5
PT is c6
PG is s5
@6
PT is c7
PG is s6
@7
PT is c8
PG is s7
@8
ST is idle
SG is "compute s1 .. s8"
PT is idle
PG is s8
@9
PG is idle
@16
SG is idle

highlight 9 to 16 #LightGray;line:Gray : time saved by pipelining
@enduml
```

(Time axis in units of one chunk round; `sX` = computation step `X` on chunk
round `X`. Idealized: transfer of one round ≈ compute of one step.)

#### Remaining cost: command amplification at the cache layer

The pipelining win is paid for in NVMe-oF command count. Reading in `C`-sized
pieces means the cache layer issues

> `N × S / C` read commands per application request — **64** in the running
> example, versus 8 full-object reads.

This amplification hurts in several ways:

- **Per-command overhead on the cache-layer CPU** — submission, completion
  handling, and the gathering/assembly bookkeeping all scale with command count.
- **Fabric round trips** — each 128 KiB read is a separate NVMe-oF exchange;
  per-command overheads are a larger fraction of small transfers.
- **Queue pressure** — sustaining the pipeline across many concurrent
  application requests multiplies outstanding commands.
- The gathering logic itself — deciding which blocks form chunk `c` of each
  object and stitching completions together — still runs entirely on the cache
  layer, on the critical path of every round.

### 1.5 This work: offload the gather to the JBoF

The core idea of this design is to **move the gathering process into the
NVMe-oF JBoF**. Instead of issuing `N` separate chunk reads per round, the cache
layer issues **one gather-read command per chunk round** that names chunk `c` of
all `N` objects. The JBoF resolves the underlying blocks itself, reads them in
parallel across its SSDs, and returns a single aggregated payload of `N × C`
bytes.

```plantuml
@startuml offloaded-gather
skinparam shadowing false
participant "Application\n(GPU)" as APP
participant "KV cache layer" as CACHE
participant "NVMe-oF target\n(gather offload)" as TGT
collections "SSDs" as SSD

APP -> CACHE : get(obj_1 .. obj_N)
loop chunk round c = 1 .. K
  CACHE -> TGT : gather-read(chunk c of obj_1 .. obj_N)\n**one command**
  par internal block reads, parallel across SSDs
    TGT -> SSD : read blocks of chunk c (all N objects)
    SSD --> TGT : blocks
  end
  TGT --> CACHE : aggregated payload (N × C bytes)
  CACHE --> APP : chunk c of obj_1 .. obj_N
  note right of APP : pipeline with computation\nunchanged from §1.4
end
note over CACHE, TGT
  NVMe-oF commands per application request:
  **K = S / C** (example: **8**) → reduced by factor **N** (8×)
end note
@enduml
```

The application-facing behavior — partial objects delivered per chunk round,
computation pipelined against transfer — is unchanged from the prior art. What
changes is where the gather runs and how much command traffic crosses the
fabric:

| Approach | NVMe-oF commands per request | Example (`N=8, S=1 MiB, C=128 KiB`) | GPU / transfer overlap |
|----------|------------------------------|--------------------------------------|------------------------|
| Full-object serialized gather | ~`N` object reads (block reads serialized) | 8 | none — GPU stalls |
| Parallel-partial read (prior art) | `N × S / C` | 64 | yes |
| **JBoF-offloaded gather (this work)** | `S / C` | **8** | yes |

Beyond the raw command-count reduction (`N × S / C → S / C`, i.e., a factor of
`N`), the offload removes the per-round gathering logic from the cache-layer
CPU and lets block-level parallelism be exploited where the SSDs actually are —
inside the JBoF.

### 1.6 Scope of this design (draft)

In scope:

- Semantics of the gather-read command between the cache layer and the JBoF
  (addressing, chunk-round description, completion/ordering guarantees).
- JBoF-side gather engine: resolving objects to blocks, parallel SSD reads,
  payload aggregation.
- Integration with the KV cache layer (KVCache / LMCache) read path.

Out of scope (assumed unchanged):

- Application/GPU-side computation and its chunk-granular consumption model.
- Cache admission/eviction policy and object placement policy on the JBoF.

### 1.7 Open questions

1. **Where does the gather engine run?** NVMe-oF target software (e.g., an
   SPDK-based target), a DPU on the JBoF, or SSD-internal capability?
   → *§2.1: the virtualized NVMe-oF target of the JBoF.*
2. **Command transport** — a gather-read is not a standard NVMe I/O command.
   Vendor-specific command, NVMe Key-Value, or a thin object protocol above
   NVMe-oF?
   → *§2.2/§2.4: standard NVMe cross-namespace Copy + Read; fused Copy+Read as
   a spec proposal.*
3. **Object-to-block mapping** — does the JBoF already know object layout, or
   must the cache layer ship a block list inside the gather-read command?
   → *§2.2: the cache layer ships the resolved source-range list in the Copy
   command; the JBoF holds no object metadata.*
4. Failure/partial-completion semantics when one SSD read of a round is slow or
   fails. → *carried into §2.8.*
