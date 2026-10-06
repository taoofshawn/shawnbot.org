---
title: "GLM-5.3-Flash on 4x DGX Spark: switched vs switchless ring research"
date: 2026-10-05
summary: "Why 4-node switchless ring recipes are topology-coupled (an NCCL rank-pair constraint, not a preference), what measured data says about switched vs switchless 4x DGX Spark, and which GLM-5.3-Flash TP4 recipes to pick."
tags: [glm, dgx-spark, nccl, rdma, llm-serving]
---

Research notes. Compiled 2026-09-22 from the NVIDIA DGX Spark forum and
GitHub. Question: why is the switchless 4x topology so recipe-coupled when
the 2x CX-7 crossover setup isn't, and how does 4x switchless GLM perform
vs 4x switched and vs the normal 2x crossover cluster?

## TL;DR

1. **The topology coupling is real and it's an NCCL constraint, not a preference.**
   On 2 nodes every rank is a direct L2 neighbor, so stock NCCL works with any recipe.
   On a 4-node switchless *ring*, non-adjacent ranks (0↔2, 1↔3) have no direct link, and
   stock NCCL/RoCE tries to establish queue pairs between all rank pairs → the communicator
   fails *before* it even picks a collective algorithm. Every working switchless stack
   patches around this (patched NCCL, custom collective layer, or a custom engine), and
   which patch layer you use dictates which recipe/image runs. That's why the recipe is
   topology-bound.
2. **Measured evidence says switchless ≈ switched, not meaningfully slower.** The only
   like-for-like data (DeepSeek-V4-Flash TP4) shows ~90 tok/s single-stream decode on both
   a QRS812-switched 4-node and SparkRing's switchless 4-node, with ~2,500 tok/s prefill on
   both. The ring's extra hop costs ~1.8 µs latency with no bandwidth loss (measured).
3. **No published switched-vs-switchless GLM-5.3 A/B exists.** Someone asked exactly this
   (FujitsuPolycom thread, post 20: "I wonder if somebody benchmarked similar TP4 setups
   using a switch… this would really help me decide if a switch brings any benefit for a
   TP4 setup at all") — no answer landed.
4. **4x GLM-5.3 vs the 2x crossover cluster:** ~1.5–2x single-stream decode (43–54 vs
   24–33 tok/s typical vLLM numbers), ~2.5–4x aggregate under concurrency, and far larger
   KV pools (8.4M–2.3M tokens vs ~1.1M). The single-stream gain is sub-linear because
   decode is memory-bandwidth-bound, not interconnect-bound.
5. **For a GLM 5.3 Flash TP4 switchless goal**, the most mature candidates are
   jacopo.nardiello's FP8 ring recipe (Rigmark-benched, 262K ctx) and SparkRing's validated
   NVFP4 GLM-5.3 TP4 profile (1M ctx). Both use SparkRing/SIRCL + patched NCCL.

## Why 2x crossover "just works" but 4x switchless doesn't

| | 2x + CX-7 crossover | 4x switchless ring | 4x + switch |
|---|---|---|---|
| physical fabric | each node's RoCE port → the other node | ring 0↔1↔2↔3↔0, 4 DACs, 2 ports/node | all nodes → switch (CRS804/CRS812/CRS504) |
| every rank is L2-adjacent? | yes | **no** (0↔2, 1↔3 are 2 hops) | yes |
| stock NCCL | works; only env (HCA, GID, IPs) | **fails** — tries QPs on non-adjacent pairs | works |
| recipe coupling | none — swap models/flags freely | recipe must carry the transport patch layer | low — near-stock recipes run |
| data-plane links | 1 link, ~200 Gb/s | 2 links/node, custom collectives | per-link ~107–200 Gb/s |

Key quotes/sources:

- **Pcessna (FujitsuPolycom), SparkRing origin thread** ([378451](https://forums.developer.nvidia.com/t/glm-5-2-on-4x-gb10s-switchless-ring-22-tps-coding/378451)):
  "Stock NCCL/RoCE on a four-node ring tries to establish queue pairs between non-adjacent
  ranks. Those ranks are not direct layer-2 neighbors, so the communicator fails before
  choosing a collective algorithm."
- Same failure mode independently reproduced on 6-node rings
  ([377435](https://forums.developer.nvidia.com/t/6-node-dgx-spark-ring-topology-nccl-fails-on-non-adjacent-node-pairs-routed-rdma/377435))
  — this is a general switchless-ring property, not a SparkRing quirk.
- The patch layers that make it work:
  - **SparkRing / SIRCL** (Switchless Inference RDMA Collective Layer,
    [FujitsuPolycom/sparkring](https://github.com/FujitsuPolycom/sparkring)): direct-neighbor
    RDMA RC links, mapped pinned-memory arenas, custom TP4 all-reduce, custom DCP
    query/combine, custom all-gather, CUDA-graph-aware command rings, explicit software
    relay for non-adjacent ops, plus a **patched ring-only NCCL fallback** for the rest.
  - **josephdrose/nccl-spark-switchless**: 2-hop diagonal relay + tree-skip patches on
    NCCL 2.30.7 (the "patched NCCL" both jacopo and Mashie credit).
  - **RoCEnante / virtual mesh** (in SparkRing): custom RoCE RDMA routing + hardware
    forwarding in the ConnectX ASICs create non-adjacent paths over the existing ring
    cables without touching host CPUs — this is what gives "mesh over a physical ring".
  - **DGPP** ([HawkBearPig/dgpp](https://github.com/HawkBearPig/dgpp)): a C++/CUDA engine
    that sidesteps NCCL entirely — talks to libibverbs directly and stripes bulk traffic
    over both CX-7 RoCE interfaces (~196 Gb/s aggregate measured).
- A practical consequence of the coupling: switchless rings are also fragile across
  driver/kernel updates — kernel 7.0.0-1019-nvidia caused NCCL/RoCE `ibv_reg_mr_iova2`
  ENOMEM failures on a 4-node TP4 switchless ring; 6.17.0-1032 works
  ([383023](https://forums.developer.nvidia.com/t/dgx-spark-regression-kernel-7-0-0-1019-nvidia-causes-nccl-roce-ibv-reg-mr-iova2-enomem-6-17-0-1032-works/383023)).

This is exactly why 2x recipes (aiden compose, etc.) never needed
topology-specific variants: two 2x recipes differ by *image/flags*, never by
fabric — there is only one fabric possible. At 4x, the fabric choice (ring
vs switch) selects the NCCL patch layer, which selects the image, which
selects the flags. The coupling is:
**topology → transport layer → image → recipe**.

## Fabric-level numbers: switch vs ring

| path | latency | bandwidth | source |
|---|---|---|---|
| QRS812 switch, full mesh, RDMA write (2B) | 2.93–3.49 µs (p99 4.2–4.9) | 107.66 Gb/s/link | [378878](https://forums.developer.nvidia.com/t/4-node-dgx-spark-cluster-with-deepseek-v4-flash-0731-dspark-benchmark-prefill-2-500-t-s-decode-90-t-s/378878) (Jeffery2011.jc) |
| QRS812, RDMA read / send | 5.64–6.34 µs / 2.55–3.44 µs | — | same |
| QRS812 vs *direct QSFP112 baseline* | — | identical (107.66 Gb/s both) | same |
| switchless ring, direct DAC node0↔node1 (64 KiB) | 8.65 µs | same as mesh | [381032](https://forums.developer.nvidia.com/t/switchless-2x-4x-6x-gb10-clusters-serving-glm-deepseek-and-qwen/381032) post 18 (Pcessna) |
| switchless ring + 1 extra hop (VirtualDiagonalMesh, 64 KiB) | 10.51 µs (+1.78 µs avg) | same, "very little loss" | same |
| DGPP libibverbs striping over both ports | — | ~196 Gb/s aggregate | [383406](https://forums.developer.nvidia.com/t/dgpp-a-gb10-optimized-c-cuda-inference-engine/383406) (Stephen Douglas Hawkins) |

Takeaways: the switch adds nothing at the link level vs a direct cable (identical
bandwidth); the ring's non-adjacent-hop penalty is ~1.8 µs — small against a multi-ms
decode step. The switch also draws ~34 W and adds heat/noise/cost (MikroTik CRS812 has
repeatedly been out of stock — the whole switchless effort exists because of that).

## DeepSeek-V4-Flash TP4 — the only like-for-like switched vs switchless data

| setup | transport | C1 decode | prefill | aggregate under load | source |
|---|---|---|---|---|---|
| 4-node, QRS812 switch, TP4 | switched, stock NCCL | ~90 tok/s (50K cold) | ~2,500 tok/s | C12 cache-hit 208.7 tok/s | [378878](https://forums.developer.nvidia.com/t/4-node-dgx-spark-cluster-with-deepseek-v4-flash-0731-dspark-benchmark-prefill-2-500-t-s-decode-90-t-s/378878) |
| 4-node SparkRing, TP4 | switchless ring | 68.8 tok/s (16K) | 2,488 tok/s | C8 265 / C32 508 tok/s | [SparkRing benchmarks.md](https://github.com/FujitsuPolycom/sparkring/blob/main/performance/benchmarks.md) |
| 2-node crossover, TP2 | direct DAC | 58.4 tok/s (16K, SparkRing) / 88.3 peak-73.3 mean (jovan3) / ~53–60 typical | ~1,900 tok/s | C8 162.7 / C32 307 tok/s (SparkRing) | same + [378878](https://forums.developer.nvidia.com/t/4-node-dgx-spark-cluster-with-deepseek-v4-flash-0731-dspark-benchmark-prefill-2-500-t-s-decode-90-t-s/378878) post 3 |
| 2-node crossover, TP4 historical benchmark | direct DAC | — | — | C12 230.1 tok/s | [378878](https://forums.developer.nvidia.com/t/4-node-dgx-spark-cluster-with-deepseek-v4-flash-0731-dspark-benchmark-prefill-2-500-t-s-decode-90-t-s/378878) |

Observations worth trusting:

- **Switched 4x ≈ switchless 4x.** Both land in the ~90 tok/s-class C1 / ~2.5K tok/s
  prefill band for the same model. Nothing measured suggests the ring costs real throughput.
- **Single-stream scaling 2x → 4x is weak** even switched: jovan3's same-stack comparison
  (DeepSeek 0731 + Patch 4) shows 2-node TP2 crossover at 88.3 peak / 73.3 mean vs 4-node
  TP4's 90–94 — a few percent, not 2x. Decode is memory-bandwidth-bound; the interconnect
  is not the bottleneck at C1.
- **Aggregate scaling 2x → 4x is strong**: SparkRing numbers show C8 162.7 → 265.2 (+63%)
  and C32 307 → 508 (+65%) for TP2 → TP4, switchless.
- Counter-anecdote: Jeffery2011.jc's switched 4-node C12 (208.7) was *below* a historical
  2-node TP2 C12 result (230.1) — Mashie: "with 50% more compute you got a 10% reduction."
  Caveat: different workloads/fingerprints, but it shows 4x TP4 is not automatically faster
  in aggregate; workload shape and config dominate.
- Pcessna's own TP2 vs TP4 table (381032) showed 53 → 90 tok/s single-stream, which
  paxren2020 challenged as too good (70%); tonyd2wild's switched 4-node implies ~50%. Treat
  large 2→4 single-stream claims skeptically.

## GLM-5.3-Flash numbers by topology

All numbers are single-stream (C1) decode unless noted; "aggregate" = summed output tok/s.
Workloads/contexts/checkpoints differ — treat rows as bands, not matched comparisons.

### 4x switchless (ring)

| stack / quant | ctx | C1 | aggregate | prefill | notes |
|---|---|---|---|---|---|
| SparkRing NVFP4-Spark, MTP3 + mesh (R33-era record) | 8K | 48.2 | C8 168.8, C16 231.3 | 2,703 (8K) | [benchmarks.md](https://github.com/FujitsuPolycom/sparkring/blob/main/performance/benchmarks.md) |
| SparkRing NVFP4-Spark, DFlash2 exact-graphs | 16K | 43.05 | C8 134.3, C16 187.0 | 2,717 | same |
| SparkRing NVFP4-Spark, DFlash2/B12X-KDA DCP4 | 16K | 37.97 | C4 90.36 | 2,649 | same |
| jacopo.nardiello FP8 + DFlash2 (Rigmark, E03) | 262K | 53.8 code / 31.2 prose | C2 61.8, C4 86.9 | 2,558 cold / 9,417 replay (8K) | TTFT ~0.4 s; 15 GiB KV/rank; [repo](https://github.com/jnardiello/GLM-5.3-Flash-FP8-4-DGX-Spark-Switchless) |
| alexellis NVFP4 (LibertAIDAI) + DFlash2 | 262K | ~45 (agentic traffic) | — | — | [383673](https://forums.developer.nvidia.com/t/nvidia-glm-5-3-flash-tp-4-recipes/383673) summary |
| DGPP C++/CUDA engine, GLM-5.3 hybrid NVFP4/FP8 | — | 50.3–58.5 | C4 94.5–104.2 | 2,210 (2K) | FP8 lane 42.2–48.7 C1, C4 62.2–67.5 |

### 4x switched / near-stock (no ring transport)

| stack | C1 | notes |
|---|---|---|
| mpfaffenberger GLM-5.3-Flash-TP4 (unsloth FP8, **native NCCL, no Ray**) | 36–37 | published 65K ctx, max-num-seqs 4; marks 100K@C10 unsupported (KDA kernel wedge) |
| tonyd2wild GLM-5.3-Flash-NVFP4-1M-KV-4x-DGX-Spark (marlin MoE, DFlash2) | — | TP4 @ full 1,048,576 ctx, 3.83M-token fp8 KV pool; **same images run at TP2 @ 262K — diffable against a 2-node recipe** |
| Wpnx330 GLM-5.3-Flash FP8 TP4 (k=4) | 35–45 avg ~37 | 1M-ctx lanes 15@200k/5@500k/3@1M; [381543](https://forums.developer.nvidia.com/t/glm-5-3-flash-on-4x-dgx-spark-30-43-tok-s-1m-context-uncensored-multimodal-cuda-graphs-on/381543) |

Note the contrast: the switched/native-NCCL 4x recipes are *not* topology-coupled — same
images run at TP2 or TP4, exactly like a 2x setup. Only the switchless ring recipes
bake the transport in.

### 2x crossover + 1x reference

| stack | C1 | notes |
|---|---|---|
| vLLM NVFP4 TP2, MTP-5 (day-0) | 24.7–30.3 | [381433](https://forums.developer.nvidia.com/t/glm-5-3-flash-running-on-2x-dgx-spark-sm-121-day-0-24-7-30-3-tok-s-with-mtp-5-two-silent-gb10-gotchas-worth-knowing/381433) |
| toNYD2WiLD NVFP4 + DFlash2 TP2 | 60 peak | "60 tok/s PEAK" — peak, not sustained |
| SparkRing NVFP4-Spark TP2 (R33) | 33.1 | C4 aggregate 66.1, prefill 2,340 |
| DGPP GLM-5.3, 2 Sparks | ~22–24 (MTP off) | MTP1 is its optimal setting |
| 1 Spark GLM-5.3 | up to ~60 claimed | [382140](https://forums.developer.nvidia.com/t/60-tok-s-glm-5-3-flash-on-a-single-dgx-spark/382140) — single-box, small ctx |

### Reading the GLM bands together

- **4x switchless GLM C1 band: ~38–54 tok/s** (vLLM-family; DGPP hybrid up to ~58).
- **2x GLM C1 band: ~25–33 tok/s** sustained (60-tok/s posts are peaks or spec-decode-
  inflated streaming numbers — streamed deltas distort tok/s; quote E2E/TTFT or
  non-streamed completion tokens).
- So 4x switchless is roughly **1.5–2x the 2x single-stream**, and **2.5–4x aggregate**
  at C8–C16 — the aggregate gain is where 4x really pays off for parallel agents.
- The sub-linear single-stream gain is structural: GLM-5.3-Flash is 18B active params on a
  320B MoE; TP splits the weight reads across nodes (additive HBM bandwidth) but adds a
  per-layer all-reduce over the fabric. Whether that all-reduce crosses a switch, a DAC,
  or two ring hops changes microseconds — not milliseconds — so ring-vs-switch is noise
  at C1. The recipe-coupling pain of switchless is about *making it boot at all*, not
  about speed.

## Recipes to consider for "4 spark GLM 5.3 Flash"

| recipe | transport | quant / drafter | status / notes |
|---|---|---|---|
| [jnardiello/GLM-5.3-Flash-FP8-4-DGX-Spark-Switchless](https://github.com/jnardiello/GLM-5.3-Flash-FP8-4-DGX-Spark-Switchless) | SparkRing image + SIRCL/patched NCCL ring | FP8 + DFlash2 (adaptive verification, draft-budget cap), E03 mHC prefill sharding | best-documented switchless GLM recipe: IaC, Rigmark-frozen baselines, 262K ctx, agent-installable; DFlash2 is non-commercial (check CREDITS.md); verified on ASUS Ascent GX10 |
| [FujitsuPolycom/sparkring](https://github.com/FujitsuPolycom/sparkring) `glm53-flash-spark-tp4-dcp1-sparkcache` profile | SparkRing ring (+optional virtual mesh) | NVFP4-Spark, MTP3 | **Validated** profile, 1M ctx / 2.3M–8.4M KV pool, optional SparkCache; also a TP2 profile if you stay on 2 nodes |
| [alexellis/glm-5.3-flash-4x-dgx-spark-switchless](https://github.com/alexellis/glm-5.3-flash-4x-dgx-spark-switchless) | tonyd2wild's image + his own switchless NCCL patches | NVFP4 (LibertAIDAI) + DFlash2 | ~45 tok/s agentic, 262K ctx; human-written long-form writeup [383349](https://forums.developer.nvidia.com/t/how-and-why-we-bought-4x-dgx-sparks-for-work/383349) |
| [tonyd2wild/GLM-5.3-Flash-NVFP4-1M-KV-4x-DGX-Spark](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-1M-KV-4x-DGX-Spark) | stock NCCL (switched fabric) | NVFP4, marlin MoE, DFlash2 | 1M ctx; only relevant if you add a switch — same images run at TP2 |
| [HawkBearPig/dgpp](https://github.com/HawkBearPig/dgpp) | own libibverbs transport (no NCCL) | GLM-5.3 hybrid/FP8 | 50–58 tok/s C1 hybrid, 15–30 s warm restarts; different engine, not vLLM |

If you stay switchless, the hardware prereq (all ring recipes agree): 4 DACs in
0↔1↔2↔3↔0, two usable CX-7/RoCE ports per node, verified 200 Gb/s, MTU 9000; management
traffic (SSH/API/Gloo/NCCL bootstrap) on a separate 10 GbE interface; ~330 GiB free per
node for the model.

## Bottom line

- The instinct is right that the 4x switchless recipes are topology-coupled and the 2x
  recipes aren't — but the cause is NCCL's rank-pair connectivity assumption, not anything
  model-specific. Ring → patched NCCL/SIRCL → specific image → specific recipe.
- The switched 4x variant is **not measurably faster** than the switchless ring on the
  evidence available (~1.8 µs/hop penalty, equal bandwidth, DeepSeek TP4 parity at ~90
  tok/s). The switch buys you *stock-NCCL recipe compatibility* (any recipe works, TP2/TP4
  diffable), not speed. The switchless ring buys you no switch purchase, and costs you a
  pinned transport stack + fragility across kernel updates.
- Vs the current 2x crossover GLM setup: expect ~1.5–2x single-stream and ~2.5–4x
  aggregate throughput, plus much bigger KV pools — driven by more HBM bandwidth and
  capacity across 4 nodes, not by interconnect choice.
- Open gap: no controlled GLM-5.3 switched-4x vs switchless-4x benchmark exists publicly.
  If you ever run both on the same hardware/quant/workload, that would be genuinely new
  data for the forum (TK asked for exactly this).

## Sources

- Threads: [382459](https://forums.developer.nvidia.com/t/glm-5-3-flash-on-tp4-dgx-sparks-switchless/382459)
  (jacopo switchless GLM), [381032](https://forums.developer.nvidia.com/t/switchless-2x-4x-6x-gb10-clusters-serving-glm-deepseek-and-qwen/381032)
  (SparkRing 2x/4x/6x + ring-vs-switch discussion), [378451](https://forums.developer.nvidia.com/t/glm-5-2-on-4x-gb10s-switchless-ring-22-tps-coding/378451)
  (original SparkRing, "how the switchless part works"), [378878](https://forums.developer.nvidia.com/t/4-node-dgx-spark-cluster-with-deepseek-v4-flash-0731-dspark-benchmark-prefill-2-500-t-s-decode-90-t-s/378878)
  (QRS812 switched 4-node DeepSeek bench), [383673](https://forums.developer.nvidia.com/t/nvidia-glm-5-3-flash-tp-4-recipes/383673)
  (three 4x GLM recipes), [383406](https://forums.developer.nvidia.com/t/dgpp-a-gb10-optimized-c-cuda-inference-engine/383406)
  (DGPP), [381543](https://forums.developer.nvidia.com/t/glm-5-3-flash-on-4x-dgx-spark-30-43-tok-s-1m-context-uncensored-multimodal-cuda-graphs-on/381543),
  [381433](https://forums.developer.nvidia.com/t/glm-5-3-flash-running-on-2x-dgx-spark-sm-121-day-0-24-7-30-3-tok-s-with-mtp-5-two-silent-gb10-gotchas-worth-knowing/381433),
  [382927](https://forums.developer.nvidia.com/t/2-spark-cluster-v-s-4-spark-cluster/382927),
  [383023](https://forums.developer.nvidia.com/t/dgx-spark-regression-kernel-7-0-0-1019-nvidia-causes-nccl-roce-ibv-reg-mr-iova2-enomem-6-17-0-1032-works/383023) (kernel regression),
  [377435](https://forums.developer.nvidia.com/t/6-node-dgx-spark-ring-topology-nccl-fails-on-non-adjacent-node-pairs-routed-rdma/377435) (6-node NCCL failure)
- Repos: [FujitsuPolycom/sparkring](https://github.com/FujitsuPolycom/sparkring) +
  [performance/benchmarks.md](https://github.com/FujitsuPolycom/sparkring/blob/main/performance/benchmarks.md),
  [jnardiello/GLM-5.3-Flash-FP8-4-DGX-Spark-Switchless](https://github.com/jnardiello/GLM-5.3-Flash-FP8-4-DGX-Spark-Switchless),
  [josephdrose/nccl-spark-switchless](https://github.com/josephdrose/nccl-spark-switchless),
  [HawkBearPig/dgpp](https://github.com/HawkBearPig/dgpp)
