---
title: "The three DeepSeek-V4.1-Flash switchless recipes for 4x Spark: two are the same lane, and TensorFold is not the newer one"
date: 2026-11-06
summary: "Two of the three repos are one SGLang lane at different vintages (Mia's TP4 line is knapcio's, vendored), and knapcio pushed within the last day while TensorFold last moved two days ago — so the recency premise is inverted. On the ring the two engines land within 5-9% of each other on the only comparable cell; TensorFold's real difference is that it shapes the ring with generated NCCL graph files on stock NCCL instead of a patched library."
tags: [deepseek, dgx-spark, switchless, sglang, tensorfold, benchmarks]
---

Three repos are circulating for DeepSeek-V4.1-Flash on four DGX Sparks, and we
run one of them on the switchless ring:

- [MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks][mia] — the origin recipe, 3-node
  triangle first, TP4 as an opt-in line.
- [knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4][knap] — the tuned TP4 profile
  built on top of Mia's.
- [MiaAI-Lab/DeepSeek-V4.1-Flash-1017-4x-DGX-Sparks-TensorFold][tf] — the same
  checkpoint on TensorFold's native Zig engine, "switchless support" in the
  description.

The question was whether to move to the TensorFold one, on the grounds that it
is newer. Working through them inverted two premises and confirmed a third.

## TL;DR

1. **The recency premise is backwards.** TensorFold the *repo* is newer (created
   2026-10-17 against knapcio's 2026-09-17), but on activity knapcio is the live
   one: last push 2026-11-06, a v2.6.4 release gate dated 2026-11-05 with
   A/B/A control boots. TensorFold's last push was 2026-11-04 and its most
   recent commits are tool-call parser fixes; the ring performance table in its
   README is dated 2026-10-25. Mia's base repo has not been pushed since
   2026-10-17.
2. **There are two lanes here, not three.** Mia's four-Spark TP4 production
   line *is* knapcio's, vendored — Mia's own README says so, and Mia's
   `docs/switchless-ring.md` is knapcio's ring document carried forward. Mia's
   repo is the parent (TP3 padding, the b12x MXFP8 route, the Engram row store);
   knapcio's fork is where the four-node work happens. Treating them as
   separate candidates double-counts one option.
3. **The ring performance is a tie within the noise.** On the one cell that is
   roughly comparable across all three — greedy code at concurrency 1 —
   TensorFold reads 117.4 tok/s, our switched SGLang line 112.0, our ring 107.5.
   On prefill at 64K, TensorFold's ring 4,134 tok/s sits with our ring's 4,249
   and well under our switched 6,137. The ring costs both engines about the
   same, which is what a one-link bisection should do.
4. **Where TensorFold genuinely differs is the switchless mechanism, not the
   speed.** It never patches NCCL. It shapes the ring with a generated NCCL
   graph file per rank plus a 2×2 split whose every partner is a physical
   neighbour, on the stock 2.30.7 in the NVIDIA image. Our lane needs a marked,
   patched `libnccl` on all four nodes and its preflight refuses a stock build.
   That is the real architectural contrast, and it is worth understanding even
   if we do not switch.
5. **Verdict: keep the SGLang lane as the vehicle.** We have already paid the
   patched-NCCL cost, our agent-serving features are on that side, and
   TensorFold's own docs carry enough unmeasured and self-inconsistent surface
   that a move would be a research project, not an upgrade. What is worth doing
   is a time-boxed ring A/B on one harness, and stealing two mechanisms.

## The three repos, as they actually stand

| | Mia base (TP4 line) | knapcio TP4 | TensorFold-1017 |
|---|---|---|---|
| engine | SGLang `dsv4.1` + b12x MoE + `DSV41_*` adapters | same, much further | TensorFold native (Zig 0.17.0) + `zig/patches` |
| role | parent; TP3 triangle; TP4 line contributed by knapcio | the active TP4 line | independent reimplementation |
| last push | 2026-10-17 | **2026-11-06** | 2026-11-04 |
| release discipline | changelog + research notes | A/B/A release gates, byte-exactness vs prior version, KLD, T=1 distribution, needles | `tools/validate.py`, needle 45/45, "612 replies token-identical" for the NVFP4 path |
| open issues | 32 | 1 | 16 |
| licence | AGPL-3.0 | AGPL-3.0 | Apache-2.0 |
| ring entry point | `docs/switchless-ring.md`, env block in `.env.tp4` | `NCCL_SWITCHLESS_RING_ONLY=1`, `doctor` preflight per rank | `./start-switchless.sh` |

Mia's README is unusually plain about the dependency: the TP4 production line,
the RoCEnante image, EP 1 with the routed MoE on b12x, prefill sequence
parallel, the fast loader and the gated decode adapters all came in as knapcio's
PR #36, and the TP4 profile's decode adapters are credited to knapcio at
`4d8f4c0`. Mia's TP4 doc says the improvements are for TP=4 only and do not
affect TP3. So Mia's repo is the right place to read the *engine's* history and
the wrong place to read the *four-node ring's* state.

## How each one actually builds a ring

This is the part that decides whether a candidate is interesting, and it is
where the two stacks are genuinely unalike.

### SGLang (Mia and knapcio): defeat NCCL's tree, with a patched library

The failure is specific and well documented: NCCL builds a tree in addition to
the ring, in a four-node ring the tree wants a direct path between opposite
nodes, and RoCE queue-pair setup does not follow IP routing. The boot dies in
`ncclCommInitRank`. The fix is `NCCL_ALGO=Ring` plus a build that refuses the
tree connect outright, and the launcher preflight **rejects a stock library** by
grepping for a `SWITCHLESS_RING_ONLY` marker.

Two ways to get that library, per the doc: sparkring's published historical
binary (`native-runtime-sm121-aa8fa11831af`), or build NVIDIA/nccl
`v2.30.7-1` with sparkring's `nccl-2.30.7-dual-pci-domain.patch` alone plus a
backport of [NVIDIA/nccl#2393][nccl2393] (the AArch64 acquire fence for the IB
CTS FIFO — without it, the sender polls `idx` then `nreqs` and a weakly-ordered
CPU can observe a recycled slot's stale count and spin forever).

Around that sit operational requirements: one `/24` per cable with routes for
the two subnets a node is not on, MTU 9000, a non-zero IPv4-mapped RoCE v2 GID
at one index on every port, and — to use the second PCIe plane — a dual-domain
build with `NCCL_IB_EXTENDED_IPV4_GIDS=1`, `NCCL_IB_PRESERVE_PCI_DOMAIN=1` and
four channels over four devices. The doc is honest that this is easy to get
wrong: devices past the second are silently never advertised (`gidSlot < 2`),
and the symptom is a channel plan that names device 2 while the port moves zero
bytes. Their fix moved 49.7% of inter-node traffic to the second plane for a
low-single-digit prefill gain.

Weights are local: `NFS_SHARE=0`, a checkpoint copy per node (476 GiB each), and
the doc's argument for it is that the ring's four DACs are needed for
collectives and a dead exporter takes the serve down.

The opposite-node path for RoCEnante is called **research-only** by its own
authors and is off by default. It is still the most interesting idea in the
document: re-tag the opposite-node QPs to EtherType `0x88b5`, route them to a
neighbour, and have a `skip_sw` tc flower rule restore and hairpin them out the
other port — no CPU in the path, `IpForwDatagrams` flat. With it, the ring ran
qeval 81.8/84.7/85.9 against the switched 83.5, and prose c1 80.9 against 86.5.
It also needs `hairpin_queue_size` 8192 and a size cap picked from it, because
at the driver default of 1024 a 120 KB all-reduce overflows the hairpin and
go-back-N makes it 3–4× slower than NCCL.

### TensorFold: shape the ring instead of patching the library

TensorFold takes the opposite approach and it is cleaner on paper:

1. **`scripts/nodes.sh` derives the topology** from the nodes' own subnets
   (`pair_links`), detects that every rank has exactly two links and that the
   workers are listed in ring order, and sets `FABRIC=ring`. It refuses the
   wrong launcher by name and refuses a ring whose worker order is wrong. No
   hand-written env block.
2. **It generates an NCCL graph file per rank** (`ring_graphs`), pinning each
   channel to a device facing the previous rank, with the port and its PCIe
   twin alternating; subnet-aware routing then moves each send to the right
   device. Measured on four Sparks: a decode-sized all-gather **109 µs against
   184 µs** with NCCL's fused devices. A prefix-length trick keeps a port and
   its twin in separate subnets, which took prompt-sized all-gathers from 16.7
   to 25.6 GB/s.
3. **The 2×2 split makes the ring a topology match, not a degradation.** Each
   Spark is node `g = 2p + r` of a 2×2 grid with row partner `g ^ 1` and column
   partner `g ^ 2`; `ORDER=auto` places the nodes `0, 1, 3, 2` around the ring
   so **every partner pair has its own cable**. Partner exchanges run over
   two-rank communicators on a single cable, each with its own graph file, and
   only the all-gathers go round the ring in rank order under
   `NCCL_ALGO=Ring`. Their comment records the failure this avoids: a send/recv
   on the world communicator picked a port without that peer and produced
   `ncclGroupEnd "unhandled system error"` on every prompt past a few hundred
   tokens.
4. **Across-ring decode traffic is relayed by neighbours** (patch `0099`,
   `COMM=roce`, `TF_ROCE_RING=1`) rather than routed by a hairpin rule in the
   NIC: the two neighbours forward half each.

Both stacks share `NCCL_IB_MERGE_NICS=0` and both use four channels over four
devices, which suggests the two designs converged on the same hardware
constraint from opposite directions.

**The claim I could not fully verify** is that TensorFold needs no patched
NCCL. It documents stock `NCCL 2.30.7` in `nvcr.io/nvidia/pytorch:26.07-py3`
and no skip-tree patch anywhere in its requirements, and it plainly runs a ring
— but the document never explains *why* `NCCL_ALGO=Ring` alone is enough to
avoid the tree-connect failure that ours hits. Either its NCCL version defers
tree setup differently, or the two-rank-communicator design never creates a
4-rank communicator that would build one. If that holds on our fabric it is the
single most valuable thing in the repo, because it retires the marked library,
the netplan-per-cable scheme and the GID-index dance. It is also the first thing
I would test, on a spare window, before believing it.

## The numbers, with the harness warning first

The three stacks were measured by three different harnesses on three different
dates, and the mismatches are large enough that only one row survives as a
comparison.

| metric (4-node ring unless noted) | knapcio (SGLang) | TensorFold-1017 |
|---|---|---|
| prose c1 | 60.5 tok/s, thinking off, sparkDash | 65.8 tok/s, T=0.7, thinking **on** |
| prose c8 aggregate | 186.1 | 165.3 |
| **code c1, greedy** | **107.5** (ring) / 112.0 (switched, v2.6.4) | **117.4** |
| code c8 aggregate | 521.6 | 183.7 |
| prefill 64K cold | 4,249 tok/s (ring) / 6,137 (switched) | 4,134 tok/s |
| needle | PASS at 1,030,651 tokens | 45/45 cells, to 997,530 tokens |
| measured | 2026-09-25 (ring table), 2026-11-05 (switched) | 2026-10-25 |

Read it like this.

**The prose rows are not the same task.** TensorFold's is sampled at T=0.7 with
thinking on; knapcio's speedbench table is thinking off. Thinking-on changes both
output length and draft acceptance, so 65.8 against 60.5 measures two prompt
classes.

**The code c8 pair is a harness artefact, not a 2.8× gap.** SGLang's ring table
shows 521.6 aggregate at 8 streams while its own c4 is 326.4 — near-linear
scaling that its per-stream numbers (65.2 at c8) do not obviously support — on a
sparkDash protocol with 400 output tokens, on a boot from 2026-09-25, i.e. six
weeks and about ten releases before v2.6.4. TensorFold's 183.7 is its own
harness, median of three. I would not defend either number as the other's
comparator.

**The greedy code c1 cell is the only one that lines up**, and there TensorFold
is 5–9% ahead of both SGLang figures — smaller than the drift between harnesses.
That is the honest size of the difference.

**Our own independent ring reproduction sits between them.** Mia's
`docs/tp4-switchless-ring-results.md` reports ~67.4 tok/s at c1 and 224.8
aggregate at c8 on the switchless ring, from a fresh clone and an idle cluster.
Those are the numbers I would use for an SGLang ring expectation, not the
2026-09-25 table.

**And the ring-vs-switch gap is real and belongs to the fabric, not the engine.**
Switched SGLang does 6,137 tok/s at 64K cold; its own ring does 4,249. Both
stacks' ring prefill numbers land within 3% of each other, which is what you
would expect when both are limited by a one-link bisection through a transit
node.

## The capacity claim I would pin down before treating TensorFold as a KV play

The README's tip block says the KV pool "runs at its true ceiling: 16,777,216
positions total (`POOL`)" — 16 streams × the full 1M window — and that this
leaves three Sparks at ~15–18 GiB free. The configuration table in the same
README says `POOL` defaults to `2,097,152`, and `scripts/config.sh` confirms
`POOL="${POOL:-2097152}"`. So the headline is a tuned deployment value and the
shipped default is 2M positions, an eighth of it.

That matters because our lane's binding constraint has been the KV pool, not
decode speed — the 2026-10-26 retention work recovered 1.35M → 3.64M tokens and
that was the fix that made two long agent sessions survive. If TensorFold's
published numbers ran at 16.7M and ours at 3.4–5.1M, then its capacity headroom
is the largest single difference in the comparison, and it is the thing to
verify from `POOL` in the boot banner rather than from the README.

## Where TensorFold is genuinely better

1. **No patched NCCL, if it holds up.** One artefact fewer on every node, and no
   marker-gated preflight that can refuse a correct-looking library.
2. **Topology detection instead of topology configuration.** `pair_links` reads
   the cabling out of the addresses and refuses a misordered ring by name. Our
   equivalent is a netplan file and a runbook.
3. **The 2×2 split is the right shape for a ring.** Every partner on a cable is
   a design decision our TP4 layout does not make; it is why their decode
   exchanges do not need the opposite-node path at all for the partner traffic.
4. **Fewer moving parts between the API and the kernels.** No Python engine, no
   adapter import-hook layer, no FlashInfer autotune cache to clear across four
   nodes: Zig engine, pinned kernel kit, one image per patch set.
5. **Patch-level honesty in the docs.** Flags are marked "on, this cluster"
   separately from the shipped default; `0018`, `0020` and `0024` are listed as
   measured-slower and kept for later; `ENGRAM_INSTREAM` says outright that it
   is new and unmeasured. That is better hygiene than most.

## Where our lane is better

1. **The agent-serving work is all on the SGLang side, and it is recent.** v2.6.4
   keeps idle sessions' prefix-cache resume points (384 SWA prefix tails,
   superseded checkpoints evicted first) so a resumed 300–330K-token session
   answers in 3.9–6.5 s instead of 61–64 s, and a resume point that is evicted
   anyway costs one 8,192-token chunk replay (~2 s) instead of a full
   re-prefill. It also yields decode time to running streams during a long
   prefill (0.080 → 0.393 of their pre-decode-prefill rate). TensorFold has the
   analogous pieces — `TF_DS_PREFILL_YIELD`, admission between chunks, kept
   prompt states — but ours is tuned against the exact long-session workload we
   serve.
2. **Decode-side loop protection.** Our lane finishes a request on an n-gram
   cycle, a same-token run or a repeated line, with a named error so a client can
   tell it from a normal stop. TensorFold's DeepSeek recipe documents no
   equivalent, and its GLM lineage has the worst longitudinal quality signal in
   the community write-ups — one user logged **7 TensorFold restarts in a day for
   looping against 0 for a vLLM stack on the same prompts**. That was a different
   model family and a different month, and the DeepSeek family is bespoke code,
   so it is a risk to measure rather than a verdict — but it is exactly the
   workload shape we would run it on.
3. **Release gates we can read.** v2.6.4 shipped with three boots in
   A/B/A order, per-category tok/s, qeval 71/71/71, byte-identical T=0 outputs
   against the previous version on 74 of 75 prompts, KLD, a T=1 distribution
   check over 12,000 samples, a 1M needle and an idle-CPU measurement. Whatever
   else changes, that is a comparable record.
4. **The cost is already paid here.** Four nodes on a four-PF patched NCCL, one
   netplan, one model-name proxy, one shared fabric contract across our lanes.
   A TensorFold move re-opens the host layer: a ~510 GB checkpoint on spark1, a
   ~203 GB Engram copy per worker (or `ENGRAM_PACKED=1` at ~51 GB owned per
   node), four ~80 GB weight files, and per-worker disk planning.
5. **NFS-on-the-ring is a documented TensorFold trap.** Its default is workers
   reading spark1's cache over NFS, and on a four-Spark ring the worker across
   from the head reaches it *through a neighbour*: it measured 9 MB/s until
   `net.ipv4.conf.all.send_redirects=0` on spark1, then 39 MB/s against 590 MB/s
   of raw TCP. Our ring doc's answer is the opposite and simpler — do not put
   NFS on the ring at all. TensorFold offers `RANK_LOCAL=1` to match that, but
   it is opt-in and costs ~80 GB on each worker.

## What I would actually do

**Keep the SGLang lane.** Not because the numbers favour it — they do not, on
the ring they are a tie — but because the two things that would justify a move
are missing: a measured ring win, and a workload fit we do not already have.

**Two things worth stealing, both cheap:**

1. **The generated-graph-file channel plan.** Whether or not we ever drop the
   patched library, `NCCL_GRAPH_FILE` with one file per rank, pinning each
   channel to the device facing the previous rank, is a 109 µs vs 184 µs
   difference on decode-sized all-gathers in their measurement, and it is a
   static artefact we could generate from our own netplan. Our dual-plane work
   improved *where* traffic goes; this improves *which device a channel starts
   on*, which is a different lever. Their prefix-length trick for keeping a port
   and its PCIe twin in separate subnets is the same family as our
   `PRESERVE_PCI_DOMAIN`, independently arrived at.
2. **`TF_DS_PREFILL_YIELD`'s shape as a target for our own deferral.** Their
   number is that with 15 requests decoding, a 25,000-token prompt stalled them
   ~7.5 s and ~1 s with the switch on, at +35–41% on that prompt's own TTFT —
   the mirror image of our v2.6.4 decode yield, which trades the long prompt's
   TTFT for the streams. Both are cost-model deferrals through
   `--prefill-decode-interval`; theirs is a constant fitted to a measured round
   table, ours is a share of chunk time. Worth an A/B at share 50/33 if we ever
   care about the long-prompt side of that trade.

**One experiment worth a window, if the ring ever underperforms:** run both on
the same harness, same prompts, greedy, thinking off, at c1/c4/c8 and 64K
prefill. That is one page of results and it settles the 5–9% question for good.
Rules: not llama-benchy (known broken on TensorFold prefill), pin temperature,
discard the first run after boot, and compare step time rather than tok/s
wherever the acceptance differs.

## What would change this verdict

- **A measured ring win on a shared harness.** If TensorFold's ring is
  demonstrably ahead at c4–c8 *and* its 16.7M-position pool is real at the
  shipped default, the capacity argument alone would reopen it.
- **A 24-hour soak without a lost session.** Their loop behaviour is the risk
  that matters for agent traffic; a documented soak at 300K+ contexts with no
  session loss would retire it.
- **Our patched NCCL becoming a maintenance problem** — a driver or kernel move
  that breaks the four-PF build would make "no patched library" weigh much more
  than 5–9%.
- **The opposite trigger already on record:** if the site's kernel/driver pin
  moves to 7.x with 64 KiB pages, the whole memory calculus changes and this
  comparison gets re-run against whatever TensorFold is then.

## Method notes

Every performance number here is attributed to its source and dated; none were
measured by me. The SGLang ring table is from `docs/switchless-ring.md`
("Measured", 2026-09-25 era, sparkDash, one engine, no other load) — it predates
v2.6 through v2.6.4 and I have flagged it wherever it could mislead. Switched
SGLang figures are the v2.6.4 release gate of 2026-11-05 (speedbench 0.3, 73
frozen prompts, thinking off, abliterated weights for that gate). TensorFold
figures are its README's 2026-10-25 run, median of three, non-greedy prose at
T=0.7 with thinking on and greedy code at T=0. Repository facts (push dates,
issue counts, commit subjects) come from the GitHub API on 2026-11-06; the
`POOL` default comes from `scripts/config.sh` at `main`, not from the README.

The claim that TensorFold needs no patched NCCL is from the absence of any such
requirement in its docs and its use of the in-image 2.30.7 — an inference I
could not confirm against a design note, and the first thing to test on a spare
window.

## Sources

- [MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks][mia] — README, `docs/tp4.md`, `docs/switchless-ring.md`, `docs/tp4-switchless-ring-results.md`
- [knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4][knap] — README, `docs/switchless-ring.md`, `docs/results/ring-mesh-20260925.txt`, `CHANGELOG.md`
- [MiaAI-Lab/DeepSeek-V4.1-Flash-1017-4x-DGX-Sparks-TensorFold][tf] — README, `scripts/config.sh`, `scripts/nodes.sh`, `start-switchless.sh`, `CREDITS.md`
- [FujitsuPolycom/sparkring](https://github.com/FujitsuPolycom/sparkring) — the switchless-cycle and dual-PCI-domain NCCL patches, and `cx7_hairpin_diagonal`
- [NVIDIA/nccl#2393][nccl2393] — AArch64 acquire fence for the IB CTS FIFO
- [ashhart/TensorFold](https://github.com/ashhart/TensorFold) · [bertholomus/TensorFold `deepseek-v41-zig-tp4`](https://github.com/bertholomus/TensorFold/tree/deepseek-v41-zig-tp4)
- [knapcio/speedbench](https://github.com/knapcio/speedbench) — the harness behind the v2.6.4 release gate

Related notes on this site: [Should we swap our 4x Spark DeepSeek-V4.1-Flash lane for spark-ds41f?](../spark-ds41f-vs-our-ring-lane-deepseek-v41-flash/), [TensorFold vs vLLM for GLM-5.3-Flash FP8](../tensorfold-vs-vllm-glm-fp8-4x-spark/), [GLM-5.3-Flash on 4x DGX Spark — switched vs switchless ring](../glm-53-flash-4x-spark-switched-vs-switchless-ring/), [Three serving lanes, one fabric core](../spark-recipes-three-lanes-dependency-map/)

[mia]: https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks
[knap]: https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4
[tf]: https://github.com/MiaAI-Lab/DeepSeek-V4.1-Flash-1017-4x-DGX-Sparks-TensorFold
[nccl2393]: https://github.com/NVIDIA/nccl/pull/2393