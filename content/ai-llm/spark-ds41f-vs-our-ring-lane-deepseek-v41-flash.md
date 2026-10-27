---
title: "Should we swap our 4x Spark DeepSeek-V4.1-Flash lane for spark-ds41f?"
date: 2026-10-26
summary: "spark-ds41f is the best-engineered DeepSeek-V4.1-Flash recipe in the DGX Spark community and lands within about 10% of our 4-node SGLang ring lane on decode, but its 2-3x KV-cache edge is welded to a 64 KiB-page kernel and a non-NCCL transport that would break our three-lane switching contract. Verdict: keep our vehicle, steal their benchmark methodology."
tags: [deepseek, dgx-spark, vllm, sglang, benchmarks, switchless]
---

A question came up while our `deepseek-v41-flash-tp4-switchless` lane was
serving: [christopherowen's "new Deepseek 4.1 flash recipe" thread][thread] and
his [spark-ds41f][repo] repo claim 74–75 tok/s single-stream on a four-Spark
ring, 8×1M contexts in cache, and near-daily measured releases. Should we
adopt it — is it worth the time, or is it not even close to what we run?

Short answer: **it is close, it is not a vehicle we can adopt, and the part
that is genuinely better is not the part we can copy.** This note is the
comparison and the reasoning.

Both stacks serve the *same* checkpoint — `deepseek-ai/DeepSeek-V4.1-Flash-1017`
at revision `1bae0e10`, MIT, native quantized weights, DSpark speculative
decoding with 5 draft tokens, Engram n-gram tables on NVMe. So this is purely an
engine + transport + operations comparison. There is no model-quality variable
in it.

## TL;DR

1. **Performance is a tie within measurement error, not a blowout.** On paper
   they show 75.3 tok/s single-stream; a clean-window probe of our live lane
   today got 67–69 tok/s. Their own numbers measured with *our* kind of harness
   (llama-benchy defaults) are 54.5–58.9 tok/s on three nodes, while an
   independent user running their recipe on a stock-pages host reports
   single-stream 74.8 tok/s and 4-stream 109.6 tok/s — and our 4-stream is 111.6.
   That is a coin flip, not a generation gap.
2. **The one real gap is KV-cache headroom: ~10.5 GiB/rank (8–11 full 1M
   contexts) against our 3.24 GiB/rank (~3.5).** For our actual workload — two
   concurrent 280–480K-token agent sessions fighting for retention — that is the
   difference that matters. It is also the one thing we cannot have without
   changing the host, because it is bought with a 64 KiB-page kernel, a UVM
   memory-saver DKMS patch, lossless expert-scale code packing and a display
   carve-out.
3. **The adoption blockers are concrete and threefold:** their recipe requires
   kernel `7.0.0-1019-nvidia-64k` with 64 KiB pages plus driver 580.178.04 per
   `config/cluster.json`; it moves serving onto `sparknet` one-shot RoCE
   collectives so "serving never touches the PyTorch NCCL process group"; and
   our site's whole lane-switching story is one shared four-PF NCCL library and
   one netplan across three lanes. Taking their stack means re-imaging all four
   nodes per switch. That is disqualifying on its own.
4. **What is genuinely superior is their engineering discipline**, not their
   tok/s: a determinism gate that fails any release whose output text changes,
   an A/B/A release comparison with drift bounds, frozen recipes and locks per
   release, an explicit adoption gate that refuses to start an unqualified
   shape. We should copy that. It costs a document and some scripts and needs
   no host change.
5. **Verdict: do not adopt as a lane; do mine it.** Reject as an alternative
   vehicle with the reasons recorded, adopt the release-gate methodology, and
   set one explicit re-open trigger (a kernel/driver pin move), because that is
   the moment the memory-saver and carve-out become legal for us.

## The two lanes

| | spark-ds41f-1025 (4-node ring) | our lane (4-node ring) |
|---|---|---|
| engine | vLLM fork, Local Inference Lab `karmic-kraken-beta`, all-TileLang kernel family (SM121 sparse MLA, MXFP4 indexer, FP8×FP4 routed experts) | SGLang dsv4.1 canary + b12x/b12x_next MoE line + `DSV41_*` adapters |
| transport | `sparknet` one-shot RoCE all-reduce/all-gather for every TP collective; NCCL 2.30.7 rebuilt with the AArch64 send-path fence, used for bring-up only | shared four-PF switchless NCCL build (`nccl-patched-4pf`), same netplan/HCA/env across all three site lanes |
| context / seqs | 1,048,576 / 16 | 1,048,576 / 16 |
| KV budget | 10.5 GiB/rank = pool arithmetic of 11.0 full 1M contexts (vLLM's own startup line reads 6.21, because its counter charges two chunks per request) | 3.24 GiB/rank (3,641,856 pooled tokens) ≈ 3.5 full 1M contexts |
| host baseline | kernel `7.0.0-1019-nvidia-64k`, **64 KiB pages**, Memory-Saver DKMS, driver 580.178.04 | stock 4 KiB pages, kernel `6.17.0-1032-nvidia`, driver 580.173.02 (site pin, shared with both GLM lanes) |
| shapes from one image | 3-node triangle 1M, 4-node ring 1M, 3-node 4K-pages 262K | 4-node ring 1M only |
| release cadence | 34 promoted baselines in the 36 days to 2026-10-25 (~1/day), each with a frozen recipe *and* upstream lock; no git tags or GitHub Releases — images and manifests are the release record | 9 days old, one vehicle swap already (sparkring → MiaAI → knapcio) |

## The numbers, with the harness warning attached

| metric (4-node ring, 1M ctx) | spark-ds41f-1025 | our lane |
|---|---|---|
| single-stream decode | **75.3 tok/s** — 33.0 steps/s × 2.284 tokens/step, TPOT p50 13.03 ms (their closed-loop suite) | **67–69 tok/s** (my live probe, clean window); 58.6 tok/s via llama-benchy pp2048/tg128 |
| 8 / 16 streams | 194.9 (11.7 steps/s × 16.7) / 251.4 tok/s (8.1 steps/s × 30.9) | not benched since the 2026-10-26 vehicle swap; engine telemetry peak 216 tok/s aggregate under mixed agent+bench load |
| Poisson 0.7 req/s open loop | 180.4 tok/s, goodput 0.65 req/s, TTFT p50 0.280 s / p99 6.29 s | not measured |
| prefill 32K / 128K / 256K / 512K / 1M | 6,762 / 6,796 / 6,482 / 5,863 / 4,942 tok/s | ~5.5–6.0K at 32–44K; 5,696 tok/s at 396K (69 s cold) |
| TTFT p50 | 0.128 s (1 stream), 0.407 s (16 streams) | 310–340 ms (my live probe, 1 stream) |
| draft acceptance | 2.266 tokens/step; 0.726 of verified drafts accepted | 2.61–2.81 (boot gates; measured differently, not directly comparable) |
| mid-prompt concurrency | 4×485K concurrent in cache, zero preemptions | 2 concurrent 480K agent sessions, retention fixed 2026-10-26 but pool-limited |

Read that table with two facts in hand.

**First, harness dominates the last 25%.** The author himself reports that his
TP3 configuration reads "54.5 to 58.9 tok/s" under llama-benchy defaults while
his own suite says 60.5 — a 10% swing from the tool alone. Our 58.6 is
llama-benchy. Comparing his best harness number to our worst is how you
manufacture a 30% gap that does not exist.

**Second, an independent user already ran the crossover test.** `vedcsolution`
runs their 1025 release on a four-node TP4 rig on stock 4 KiB pages: 4,738 pp
tok/s, 74.8 tg tok/s single stream, 94.0 at 2 streams, 109.6 at 4 streams. Our
comparable cell is 111.6 at 4 streams. Whatever separates the two stacks, it is
not decode throughput at realistic concurrency.

Where they do look genuinely ahead is prefill in the 32K–256K band (their CED
row-selection skip plus the all-TileLang kernels gave +11.8–13.9% over their own
previous release, on top of an already-solid base), and raw KV headroom.

The most instructive single pair of numbers is the decompose. Their single
stream is 33.0 engine steps/s at 2.284 tokens/step; ours works out to roughly
25–26 steps/s at 2.6–2.8 tokens/step. So **their decode step is genuinely
shorter (~30 ms against our ~39 ms) and our drafting is genuinely better**, and
the two products land within 10% of each other. That is what "we are running
different optimisations of the same problem" looks like, not what a generation
gap looks like.

## Where spark-ds41f is genuinely better

1. **KV capacity per rank — the only gap that changes what we can serve.**
   10.5 GiB/rank against our 3.24 GiB. Their recipe's 1M context is not the
   achievement; *eight-ish simultaneous full-1M contexts* is. Our 2026-10-26
   retention investigation ended with "the pool could not hold two 280–480K
   agent conversations plus growth, so LRU evicted between turns", and the fix
   was a ratio change that recovered +170% of pool (1.35M → 3.64M tokens). Their
   budget would have made that problem disappear. It comes from four stacked
   memory tricks: 64 KiB UVM leaf-table packing (+1.78–1.86 GiB/node), lossless
   4-bit expert-scale codes (2.1–2.7 GiB/rank), the GB10 display carve-out
   (842 MiB/rank), and pushing `gpu_memory_utilization` to 0.82 with a 3 GiB
   memguard.
2. **Release discipline.** Every promotion runs three gates: the release test
   suite, a determinism gate (output token hashes must equal the previous
   release's), and a four-hour A/B/A comparison of candidate / previous /
   candidate again in one session, with a 95% interval plus the repeat's own
   drift as the bar for "better" or "worse". Deployments they cannot qualify are
   refused at start (`cluster start` will not launch an unqualified shape). That
   is a stronger contract than anything we run today, and our own 2026-10-23
   bench-contamination incident is exactly the failure mode it prevents.
3. **One image, three shapes.** The same image and `config/cluster.json` serve
   3-node triangle, 4-node ring and a stock-pages 262K profile. Our lane is a
   4-node-only recipe with a separate build step per node.
4. **Kernel depth and upstream citizenship.** A TileLang kernel family for
   SM121 that they moved the whole serving path onto (247 prepared calls, ~11 s
   on four nodes), the `tilelang#3430` SM121 patch accepted upstream, the
   `NCCL#2393` AArch64 fence fix, and vLLM patches for ring-routed all-to-all
   and late admission. Even when we do not adopt it, this is the frontier work
   the whole Spark community reads.
5. **Documented failure modes.** The best public writeup of the GB10 clock latch
   (EC stops publishing power limits, GPU pinned at 555–656 MHz and 9–11 W,
   `nvidia-smi` reports no clock-event reason because the cap comes from
   platform firmware, only a full AC disconnect clears it) lives in that thread
   and their `dgx-spark-power-control` repo. We already carry the ops rule; they
   are the source.

## Where our lane is better

1. **Switch cost is nearly zero, and that is a hard requirement here.** Three
   lanes (GLM NVFP4, GLM FP8, DeepSeek V4.1) share one four-PF netplan, one
   patched NCCL library and one model-name proxy. Switching lanes is one line in
   the proxy `.env`. Adopting spark-ds41f would mean two mutually exclusive host
   baselines on the same four machines — re-imaging nodes every time we want the
   GLM lane back. No amount of tok/s pays for that.
2. **Stock pages, pinned kernel.** We serve 1M context on a stock 4 KiB-page
   kernel, on the same driver/kernel pin as the GLM lanes, with no DKMS patch
   and no driver surgery. Their equivalent stock-pages profile supports 262K,
   not 1M — which is the clearest single statement of what the memory work buys
   and what it costs.
3. **Our engine choice is the one our own A/B supported.** The one controlled
   same-prompt comparison on this hardware (4× Spark, 100G switch, DSpark k=5,
   original weights) had vLLM at 41.0 tok/s prose c1 against SGLang at 72.3, and
   prefill 1,950 vs 4,617 at 17K — SGLang won decisively for DeepSeek, with the
   wins attributed to DeepSeek-specific kernel/indexer work rather than generic
   flags. Their stack is a heavily-forked vLLM that closes much of that gap, but
   "heavily forked vLLM" is also a maintenance liability we do not currently
   own.
4. **Our retention is measured on our traffic, not inferred.** After the
   2026-10-26 fix, real captured agent bodies (479K tokens, 1,629 messages)
   return 99% cached on revisit, including cross-session, with 3–9 s warm
   revisits. Their recipe documents the opposite problem in their own engine
   family — the V4.1 template drops earlier turns' reasoning when a new user
   message arrives, so agent prefixes can move and no cache can hit.
5. **We do not have the sink bug they had to fix.** I probed our live lane with
   five short prompts at temperature 0 and 1.0 (`Say hi.`, `Hello`,
   `Hi there!`, `Say hello.`, `Hey`): coherent answers every time, no empty
   completions. Their 1022 release added attention-sink detection (residual
   column 2455) and draft-zero rejection specifically because short prompts
   collapsed. Nothing to port.

## The blocker, in their own words

Their `config/cluster.json` is unambiguous:

```json
"host": { "kernel": { "release": "7.0.0-1019-nvidia-64k",
                      "page_size": 65536,
                      "memory_saver_required": true } }
```

and the ring shape declares `"fabric": {"transport": "oneshot-ring4"}`, with an
NCCL profile built around `NCCL_IB_MERGE_NICS=1`, four channels and
`NCCL_SWITCHLESS_BIDIRECTIONAL=2`. Our site contract is the opposite in every
one of those dimensions: 4 KiB pages, kernel `6.17.0-1032-nvidia` (the 7.x
kernel broke ring NCCL for the GLM lanes and that pin is an invariant),
`NCCL_IB_MERGE_NICS=0` with four separate PCIe views, and serving traffic that
flows through that same NCCL library.

It is worth being precise about what is *not* the problem. The cabling is
compatible: they run the same physical ring we do — one ConnectX-7 card, two
200 GbE ports per node, each port appearing twice over PCIe, so one cable
carries two RDMA paths — and they even list the same four HCA devices we do. The
incompatibility is one level up, in the collective layer that consumes that
fabric.

The rest of the host footprint is just as load-bearing, and none of it is
optional for the 1M ring shape: DGX OS 26.09.2, `kho=off` on the kernel
cmdline, driver 580.178.04, Secure Boot with an enrolled MOK key to sign the
`nvidia-uvm` memory-saver DKMS module, a 16 GiB 64 KiB-header swap file, THP
never, `vm.watermark_boost_factor=0`, NVMe APST pinned, `nvidia-drm` modeset
enabled (required by the carve-out), headless boot, a fan-control package, and
cpuset pinning to ten fast cores. Their own `doctor --live` refuses a cluster
whose kernel, driver, page size or memory policy differs from the recipe.

We already evaluated and rejected the memory-saver and display-carve-out on
exactly these grounds when the recipe was adopted; nothing has changed since
except their numbers getting better.

Two more costs come with the cadence rather than the host. At ~1 promoted
baseline per day (34 in 36 days, ~45 commits/day, 20 open issues, no tags) you
are tracking a moving target, and the freezing discipline that makes that safe
is *their* tooling, not ours: each release's recipe and upstream lock are frozen
as a rollback directory, and a precision change fails their determinism gate by
construction. And the recipe has hard product limits we do not currently share —
at most 4 images per request (a fifth image anywhere in the chat history makes
every later turn fail `400`), and top-logprobs capped at 32.

## What I would actually take from them

1. **The release-gate methodology.** A determinism hash gate plus an A/B/A
   single-session comparison with drift bounds, applied to our own lane swaps
   and config changes. This is the highest-value transfer in the whole exercise
   and it needs no host change. Our 2026-10-23 "bench with the agents running"
   invalidation is the argument for it.
2. **A refusal to start unqualified shapes.** Their `cluster start` will not
   launch a shape that no release benchmark has qualified without an explicit
   override. Our equivalent gate is prose in a runbook.
3. **Their prefix-moves-under-agent-traffic warning as a test case.** Their
   claim that V4.1's template drops earlier reasoning on a new user turn is a
   hypothesis worth re-testing against our captured bodies, because our
   evidence says our renders are prefix-stable. One related trap we should
   document regardless: our server default reasoning effort is rendered into
   the first message, so a client that *changes* effort mid-conversation
   changes its own prefix and forces a full re-prefill. That is a client-facing
   note, not a bug.
4. **Their prefill lever.** The CED non-final-chunk row-selection skip with a
   long-prefill budget (16,384 on the ring) is worth ~12–14% prefill in their
   stack. It is engine-specific and not portable to SGLang directly, but the
   concept — spend a bigger budget on long prefills and skip non-final rows in
   the attention's CED selection — is the kind of thing to watch for upstream
   in SGLang.
5. **Their speculative-verification budget rule.** They choose the number of
   verification rows per step as `k = argmax [expected accepted tokens] /
   (1 + 0.035 × rows)`, where each extra row is modelled as 3.5% of a step — a
   rule of the inputs, so nothing is timed at boot and every build drafts the
   same way. Our equivalent is a confidence cap (`DSV41_VERIFY_CAP=conf:0.1`)
   plus block verify. The "no per-build cost curves, no boot-time timing"
   property is the transferable idea, and it is the reason their releases can be
   compared across images at all.
6. **Keep reading their thread.** It is the best running record of what breaks
   on GB10 (clock latch, R580/610 pageable HtoD hangs above 128 KiB from
   unaligned file-backed pages, NVMe APST sleep costing ~3% at 8 streams).

## What would change this verdict

One trigger, and it is a host-level one: **if the site's kernel/driver pin ever
moves to the 7.x line with 64 KiB pages**, revisit immediately. At that moment
the memory-saver, the display carve-out and the scale-code packing all become
legal for us, the KV gap becomes addressable, and spark-ds41f turns from "a
faster stack we cannot run" into "the reference implementation for the profile
we just enabled". Second trigger: if our agent workload starts running more than
about three concurrent 500K-class sessions as normal traffic, our 3.5-context
pool becomes the binding constraint and the calculus changes even without the
host move.

Until then: keep the SGLang lane, keep the shared fabric, and copy their
homework on measurement.

## Method notes

Performance numbers attributed to spark-ds41f come from their release records
and the forum thread, on their harness. Numbers attributed to our lane come
either from our recipe's `research.md` receipts (llama-benchy `pp2048/tg128` at
depth 0, and prefill observations) or from a live probe I ran on 2026-10-26
against `http://10.69.43.170:8000` while the lane was also serving agent
traffic: five short prompts for the sink check, then 256-token greedy
generations measured by first-content-byte to last-content-byte over the
streamed response, excluding prefill. The live probe is deliberately labeled as
such — it is a clean-window observation, not a bench, and two of six runs show
obvious interference (21 s TTFT, 8.4 tok/s), which is exactly why our own
methodology needs their discipline.

[thread]: https://forums.developer.nvidia.com/t/new-deepseek-4-1-flash-recipe/384438
[repo]: https://github.com/christopherowen/spark-ds41f