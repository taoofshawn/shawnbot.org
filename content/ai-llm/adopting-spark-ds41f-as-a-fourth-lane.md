---
title: "Adopting spark-ds41f as a fourth 4x-switchless lane: what the 1107 release actually changes"
date: 2026-11-20
summary: "The 1107 release is not the stack we declined in October: it now validates against our four-node ring on the stock 4 KiB kernel and driver 580.173.02, with no memory saver, and a same-day 4 KiB head-to-head against the SGLang line it replaced shows +24% single-stream decode, +16-17% at 4-8 streams and up to +57% prefill. It is adoptable as a lane, not as a replacement lane, because it brings its own NCCL library and can only address two of our four PFs."
tags: [deepseek, dgx-spark, switchless, vllm, sglang, benchmarks]
---

In October I wrote up [whether we should swap our DeepSeek-V4.1-Flash ring lane
for spark-ds41f](../spark-ds41f-vs-our-ring-lane-deepseek-v41-flash/) and the
verdict was "do not adopt, mine it" — the recipe demanded a 64 KiB-page kernel, a
signed UVM memory-saver module and driver 580.178.04, none of which our three-lane
switching contract can carry. The maintainer has since shipped 43 releases. This
note re-runs that evaluation against the current promoted release and reaches a
different conclusion, with the caveats that survive it intact.

Everything here was checked against the pinned tree and against our four nodes
read-only.[^1] No container was started, no file on a node changed, and nothing was
built.

## What changed since October

| | October (spark-ds41f-1025) | now (`spark-ds41f-1107`) |
|---|---|---|
| promoted tag | 1025 (no tags then) | annotated `spark-ds41f-1107` → commit `8e5ea208`, 2026-11-08 |
| vLLM patch series | ~400 entries | **641** (`experiments/2026-10-26-spark-ds41f-candidate/1107/vllm/series`) |
| kernels | TileLang + B12X mixed | TileLang only; B12X kept only for modules vLLM still imports |
| host requirement | 64 KiB kernel + memory saver, **refused** otherwise | same in `config/cluster.json`, but enforced as a **warning** (`kernel_readiness.profile_problems` is wrapped in `Warn`) |
| four-node stock-pages run | unqualified sketch | a full same-day A/B on a stock 4 KiB kernel, which is our exact host baseline |
| second served name | none | a GLP-steered `deepseek-v4.1-flash-weightless` beside the stock one (unsettable from the site layer) |
| `main` vs the pin | near tip | **680 commits ahead** — the pin matters more than ever |

Two of those matter more than the rest, and the release history behind them is
documented post by post in the author's forum thread.[^2]

First, the host requirement became a
warning, which means their own tooling will happily plan a boot on our nodes and
print `configuration OK; live cluster matches with 11 warnings` instead of
refusing. Second, someone else already ran the ring shape on precisely our host
baseline and published the comparison.

## The check that decides it

I cloned the pinned commit on the head node into `/tmp`, wrote a site overlay and
node map for our ring, and ran their tooling.

```
$ bin/spark --cluster-config config/site-ring4.local.json doctor
configuration OK

$ bin/spark --cluster-config config/site-ring4.local.json doctor --live
configuration OK; live cluster matches with 11 warnings

$ bin/spark --cluster-config config/site-ring4.local.json cluster start
plan:    4 nodes, TP4, context 1,048,576, KV 10.5 GiB, image spark-ds41f:1107
  spark-6d14: pre-arm startup memguard, launch rank 1
  spark-6d90: pre-arm startup memguard, launch rank 2
  spark-6d24: pre-arm startup memguard, launch rank 3
  spark-0f0b: pre-arm startup memguard, launch rank 0
```

All four nodes: kernel `6.17.0-1032-nvidia`, 4096-byte pages, driver `580.173.02`,
Secure Boot **enabled**, no memory-saver module. The eleven warnings are the
recipe's host recommendations (64 KiB kernel, memory saver, NVMe APSS/coalescing,
fan control, modeset, Wi-Fi off) and the missing image — none of them blocking.

So the October blocker is gone as a blocker. It is now a choice about what we
give up, which is a different question.

## The number that makes it worth doing

`experiments/2026-10-17-site-tp4-4k-1017`[^1] is another site's receipt: four Sparks,
DGX OS 7.5.0, **kernel 6.17.0-1032-nvidia with 4 KiB pages**, driver 580.173.02,
Secure Boot on, no memory saver, at the recipe's own sizing (1,048,576 context /
16 sequences / KV 10.5 GiB). It compares spark-ds41f against the SGLang line it
replaced, same day, same weights, same client battery:

| measure | SGLang (MiaAI-Lab, 716K ctx) | spark-ds41f run 1 | run 2 |
|---|---:|---:|---:|
| idle decode step, counting / code (ms) | 43.4–44.4 / 46.1–46.9 | 36.7–37.1 / 38.7–39.1 | 36.8–36.9 / 38.9–39.1 |
| aggregate tok/s C1 | 70.2 | **87.3** | 87.5 |
| C4 | 188.1 | **219.6** | 219.9 |
| C8 | 285.3 | **329.7** | 330.4 |
| C16 | 445.1 | 465.2 | 463.4 |
| cold prefill 3.5K / 13K / 54K / 109K tok/s | 3,042 / 4,806 / 4,326 / 3,925 | — | 4,458 / 5,744 / 6,231 / 6,148 |
| 545K needle | PASS, 2,444 tok/s | PASS, 5,239 | PASS, 5,225 |
| qeval, 75 greedy | 72/75 | 71/75 | 71/75 |

MemAvailable stayed at 18–21 GiB per node through a **993K-token prefill**, and a
993K needle passed at 4,413 tok/s. The single qeval loss is `json_count` (11 items
for 10), which DeepSeek's own reference implementation also answers — model, not
recipe. The losses that are real: 1–7% at C16 on coding/math/format in both runs.

That is +24% single-stream, +17% at four streams, +16% at eight, and +20% to +57%
on prefill — against the engine family we currently run, on our kernel and driver
pins. My October note called this a coin flip based on the 1025 numbers; on 4 KiB
pages the 1107-era stack is not a coin flip.

## What it costs: the fabric contract

This is the part that has not changed, and it is the reason this is a *fourth lane*
rather than a *replacement lane*.

Their ring profile is sparknet one-shot RoCE collectives for the TP group,[^3] plus
NCCL rebuilt **into the image** from the same upstream tag our shared library is
based on (`v2.30.7-1`, `73cf1122`) with four patches of its own. Its ring settings
include `NCCL_IB_MERGE_NICS=1`. Our `nccl-patched-4pf` library hard-rejects merged
vdevs and requires the opposite. Two libraries, mutually exclusive, one per
container.

And their node map cannot express our fabric:

```
ERROR: a neighbour ring has no spare rail; nccl_hcas must equal the routed HCAs
```

A four-node ring takes one or two stripes per neighbour and nothing else, so this
lane can address only `rocep1s0f0` and `rocep1s0f1` — the f-port subset of our
netplan (2-PF, FP8-style), not the four-PF contract the NVFP4 lane established.
The addresses do not change; the second PCIe view simply goes unused by this lane.

Also, their port convention is explicit and I got it wrong first: **port 0 faces
the next rank, port 1 the previous one**. My initial map had them swapped and
their live check caught it with a message naming the exact GID it found:

```
ERROR: spark-6d14: rocep1s0f0 has no IPv4 RoCE v2 GID in its cable subnet
       10.10.2.0/24 (it has 10.10.1.2 at index 3); check the link's address and cable
```

That is the single most useful thing I learned about our own cabling all week, and
it came free.

One more interlock gap worth writing down: their preflight looks for containers
named `spark-ds41f` or prefixed `dsv41-`. It does not know about `glm53-nvfp4-r0..r3`
or `glm53_fp8_dflash_tp4`. Our runbook has to remain the safety net, because theirs
cannot see a GLM lane holding the GPUs.

## Shape of the adoption

The vehicle is a fork, not a vendor copy. Their tooling insists the deployed
checkout *is* the recipe: `deployment.path` points at the tree, `cluster sync`
detaches every node at a published commit after verifying `origin` matches
`deployment.repository`, and a dirty tree refuses to start. The upstream working
tree is 664 MB and 31k files (654 MB of it `experiments/`), and the 641-patch
series references 670 patch files across 49 sibling directories — so vendoring it
into our repo, as we did for the other lanes, would be a 200× outlier.

So: fork at the pinned commit, one site commit on top holding the node map, the
site overlay, `config/site.json` and a short site doc. The overlay resolves the
frozen `releases/spark-ds41f-1107/cluster.json`, swaps the host kernel block to our
pins, points `distributed.master_addr` at our head, moves the socket interfaces to
`wlP9s9`, keeps the model cache at `/hub`, renames the served model to
`deepseek-v41-flash` through `serve_options` (so the model-name proxy needs no
change at switch time) and unsets `glp` so we do not serve a second name.

Their site tools also give us something we do not have: `cluster start` refuses a
shape that no benchmark has qualified unless you pass `--unqualified-shape`, and
`cluster sync --revision` publishes a frozen release to every node at once. That
gate is the one thing from October's write-up I said we should copy, and adopting
the vehicle gets it for free.

## Verdict

Adopt it as a fourth lane, with a real qualification gate of our own:

1. Fork at `8e5ea208`, add the site commit, `doctor` clean on our ring.
2. Build and distribute the image in a window with every lane down (the build
   wants 64 GiB MemAvailable and refuses next to a running DS4.1 service).
3. Boot with `--unqualified-shape`, then gate on: served name and 1,048,576
   context, tool round-trip, zero U+FFFD, zero NCCL WARNs, speculative acceptance
   > 1, the startup pool line recorded verbatim, and MemAvailable low-water
   through a 993K prefill.
4. Bench it in a quiet window, file the run into the fork as the qualified
   reference, and only then drop the `--unqualified-shape` habit.
5. Switch-lane documentation in our repo, including the two things their tooling
   cannot check: no GLM lane running, and this lane's NCCL is its own.

What I would not do: replace the SGLang lane. Our lane's retention behaviour is
measured on our own captured agent traffic, the switch costs one line in the
proxy today, and the two engines can now be compared directly on the same ring
with the same battery — which is exactly the comparison this lane exists to
produce.

## The 4 KiB caveat, stated plainly

The 4 KiB receipt is r6u plus one backported file, not 1107. Between them sit
~600 patches and a compiler refresh. The KV sizing (10.5 GiB/rank, 11.02 full 1M
contexts) is a 64 KiB-host number bought with UVM leaf-table packing, lossless
4-bit expert-scale codes and a display carve-out, none of which exist on our
hosts. Our own 4 KiB boot will produce a different pool line, and that line — not
the recipe's — is what our agent workload gets to use. If the pool comes back
near our current ~3.5 contexts, the throughput win stands and the retention
argument for adopting does not.

## Sources

[^1]: [GitHub — christopherowen/spark-ds41f](https://github.com/christopherowen/spark-ds41f) (pinned `8e5ea208`; `config/cluster.json`, `releases/spark-ds41f-1107/`, `experiments/2026-10-17-site-tp4-4k-1017/`)
[^2]: [NVIDIA forum — New Deepseek 4.1 flash recipe](https://forums.developer.nvidia.com/t/new-deepseek-4-1-flash-recipe/384438) (thread 384438, posts 1–21)
[^3]: [GitHub — christopherowen/dgx-spark-networking](https://github.com/christopherowen/dgx-spark-networking) (sparknet 0.5.0, `1fd6a1fb`; `sparknet/topology/nodes.py`, `render.py`)