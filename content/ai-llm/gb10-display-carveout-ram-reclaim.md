---
title: "Reclaiming the GB10 display carve-out: what 'more RAM on DGX Spark' actually buys a TP4 serving cluster"
date: 2026-10-06
summary: "Two community techniques unlock the GB10's idle 2 GiB display-reserved memory: a patched-driver kernel reclaim into Linux RAM (self-reported, no KV-pool benefit proven) and a DRM display-buffer route into CUDA (community-confirmed, +250k KV tokens but ~60-70% bandwidth). Neither helps glm-v53-flash-4x-noswitch today; verdict monitor-and-wait."
tags: [dgx-spark, gb10, memory, nvidia-driver, vllm, kv-cache, glm, llama]
---

## The claim, and why it was worth digging into

A recent NVIDIA forum thread ([384621](https://forums.developer.nvidia.com/t/reclaim-2gib-of-ram-on-headless-sparks/384621/1)) reports reclaiming **2,046 MiB per machine into ordinary Linux RAM** on headless ASUS GX10 systems — "free RAM on DGX Spark", discovered by tracing the firmware memory map. My `glm-v53-flash-4x-noswitch` recipe is memory-tight by design (~5 concurrent sessions at 262k context; a 6th dies), so any claim of "more memory" deserves scrutiny. The question: does this actually grow the KV pool or the session count? Short answer after reading all five relevant threads and the repos behind them: **no — not the way the claim reads.** One *related* technique does buy KV, at a real cost. Details below.

## What is actually reserved (the mechanism)

The GB10 firmware/UEFI carve-out map (per [jontaylor's RM probe](https://github.com/jontaylor/gb10-ram-reclaim/blob/main/docs/design.md), ASUS GX10):

| Region | Range | Size | Owner |
|---|---|---|---|
| `DISPLAY_FRM` | `[0x280200000, 0x300000000)` | **2,046 MiB** | NVIDIA RM display/scanout carve-out allocator; excluded from the Linux memory map (`MEMBLOCK_NOMAP`) |
| UEFI framebuffer reservation | `[0x300000000, 0x303000000)` | 48 MiB | firmware — deliberately left alone |

On a **headless** machine this 2 GiB just sits idle: not Linux RAM, and not used by any display. Two independent techniques have been published to exploit it:

### Technique 1 — kernel reclaim into Linux RAM (jontaylor, thread 384621)

A **patched NVIDIA open driver 580.173.02** makes both GB10 scanout-carveout allocation paths return `NV_ERR_NOT_SUPPORTED` (so the driver can never hand those pages out again), plus **kernel helper modules** (livepatch-format ELF relocations to unexported Ubuntu-kernel symbols) that clear `MEMBLOCK_NOMAP` on the region, verify it with pattern tests, and `free_reserved_page()` it into the buddy allocator. Measured result: **MemTotal 127,535,016 → 129,630,120 KiB (+2,046 MiB)** on both test machines, usable by ordinary `malloc`. Manual activation only, nothing at boot, reboot restores stock. Repo: [jontaylor/gb10-ram-reclaim](https://github.com/jontaylor/gb10-ram-reclaim).

### Technique 2 — CUDA via a DRM display buffer (emihuang, thread [383583](https://forums.developer.nvidia.com/t/deepseek-v4-1-flash-for-2x-dgx-spark-exl3-3bpw-3m-kv-cache-c6-new-2gb-free-ram-unlock-for-all-gb10s/383583/1))

The original discovery: on headless GB10s the same 2 GiB is **CUDA-allocatable** by allocating a display buffer through `/dev/dri/card0` and registering it with CUDA (`DEVICEMAP | IOMEMORY`), with `nvidia_drm modeset=1 fbdev=0`. It stays under the display allocator and needs a custom allocator ([display_kv.c](https://github.com/coolbho3k/DeepSeek-v4.1-Flash-2x-DGX-Spark/blob/878e0eecd893fadc69ad2d58b2df0fabb0fae2ee/release/runtime/sources/display_kv.c#L50-L92)).

## Claims vs evidence

| Claim | Evidence quality | Verdict |
|---|---|---|
| 2,046 MiB can be returned to ordinary Linux RAM | Self-reported, 2 machines, ~2 days of shakedown at announcement (author's own words: "not enough for primetime"); **zero** GitHub issues = no replication *and* no failure reports; **no NVIDIA acknowledgment** | Plausible, unverified |
| Reclaimed RAM is usable by **CUDA** | Proven only via `cudaHostRegisterMapped` **pinned-host** memory (380/998 MiB exercised); `cudaMalloc` backing uncounted; no device-total before/after published | Partially proven; device-memory path unproven |
| Display-reserved memory is CUDA-allocatable headless (technique 2) | Self-reported + **independently integrated** by 0rand into a GLM recipe: "+250k KV cache tokens. No speed degradation in decode" | Confirmed (community) |
| Display region bandwidth | Two independent measurements agree: ~160 GB/s vs 250–260 GB/s main pool (0rand); "~70% speed" (fabiopili) | Confirmed |
| +2 GiB Linux RAM → more vLLM KV pool / extra session | **No evidence anywhere**; vLLM's KV pool is `cudaMalloc` inside a firmware-fixed CUDA device total (~119.7–121.7 GiB), which is *not* Linux MemTotal | Unproven, likely false for cudaMalloc-based pools |
| Works on stock NVIDIA DGX Spark (non-ASUS) | Untested; the compat tool refuses other boards/BIOS by design | Unknown |
| Works on kernel 6.17.0-1032-nvidia + driver 580.173.02 | Exactly the tested combo (on GX10 hardware) | Yes for that hardware |

Two adjacent findings for completeness:

- **"Memory Saver"** ([thread 384884](https://forums.developer.nvidia.com/t/introducing-dgx-spark-memory-saver-more-memory-headroom-for-cuda-workloads/384884/1), christopher_owen): a UVM page-table-packing patch that recovers **1.78–1.86 GiB/node** — but only on **64 KiB-page kernels** (it removes a 64k-kernel penalty; on a 4 KiB kernel it yields nothing). Well-executed (3-node trial, no perf regression, [repo](https://github.com/christopherowen/dgx-spark-memory-saver)), inapplicable to a 4 KiB-kernel cluster.
- **The counter-movement** ([thread 383222](https://forums.developer.nvidia.com/t/dgx-os-7-5-0-ota-uefi-5-36-0acum027-7-2-gib-less-ram-available-at-boot/383222/1)): the DGX OS 7.5.0 OTA (kernel 7.0.0-1019) costs **−7.2 GiB** of boot-time RAM via Kexec HandOver (KHO) — NVIDIA-confirmed, mitigations rolling out, `kho=off` as workaround. Reminder that OS updates silently move the memory map.

## What it would buy `glm-v53-flash-4x-noswitch`

**Technique 1 (kernel reclaim): no serving benefit — proven or plausible.** The KV pool (`--kv-cache-memory-bytes`, GMU 0.85) comes out of the firmware-fixed CUDA device total, not MemTotal. The reclaim blocks the RM allocator from the region — if anything it *removes* it from the CUDA side. What it does buy is ~8 GiB of **host** headroom cluster-wide: rank-0's API server + OpenResty, page cache during weight loads, docker. Real (rank 0's measured MemAvailable floor is ~3.9 GiB), but it's OOM margin, not capacity.

**Technique 2 (DRM display buffer): the only route with a measured KV payoff.** 0rand's +250k KV tokens per 2 GiB on GLM-5.3-Flash, scaled to 4 ranks, is roughly **+50% on top of the 16 GiB KV pool** — plausibly the 6th session. But it costs: `nvidia_drm modeset=1 fbdev=0` on the host, `/dev/dri` in the serving container, and integrating `display_kv.c` into a heavily customized vLLM (DFlash2 + SparkCache/SIRCL + patched NCCL 2.30.7), while accepting ~60–70% KV bandwidth.

**Risks, technique 1 specifically:** documented memory-corruption risk by construction ("can corrupt memory if another owner still uses them"; guards cover only reviewed driver paths); no unload-based reverse operation (reboot only); manual activation after **every** reboot; livepatch + out-of-tree kernel taints; version-locked to exactly 6.17.0-1032.32. It replaces the host driver — the same layer the switchless-ring NCCL stack depends on — though nothing in any thread reports NCCL/RoCE breakage from it.

## Verdict: monitor-and-wait

1. **Do not deploy the kernel reclaim.** Self-reported on 2 machines, unreplicated, no NVIDIA response, corruption risk by design, per-boot manual activation, and no proven path from Linux RAM to vLLM KV. Negative risk/reward for a production, pinned, ring-NCCL cluster.
2. **The memory-bounded recipe (E31-MB) rollout comes first** — it targets the actual binding constraint at near-zero risk.
3. **If the 6th session is a real need afterwards**: emihuang's DRM route is a legitimate single-node canary in a maintenance window. Decisive cheap steps: reproduce the `display_kv.c` allocation + a bandwidth microbenchmark (expect ~160 GB/s) before any vLLM integration; and for technique 1, run only the repo's read-only preflight on one node — on non-ASUS hardware it should refuse, ending the evaluation for the cost of one command.

## Sources

- [Thread 384621 — Reclaim 2GiB of RAM on headless sparks](https://forums.developer.nvidia.com/t/reclaim-2gib-of-ram-on-headless-sparks/384621.json) · [jontaylor/gb10-ram-reclaim](https://github.com/jontaylor/gb10-ram-reclaim) ([design.md](https://github.com/jontaylor/gb10-ram-reclaim/blob/main/docs/design.md), [validation.md](https://github.com/jontaylor/gb10-ram-reclaim/blob/main/docs/validation.md))
- [Thread 383583 — emihuang's 2 GB display-memory unlock for all GB10s](https://forums.developer.nvidia.com/t/deepseek-v4-1-flash-for-2x-dgx-spark-exl3-3bpw-3m-kv-cache-c6-new-2gb-free-ram-unlock-for-all-gb10s/383583.json) · [display_kv.c](https://github.com/coolbho3k/DeepSeek-v4.1-Flash-2x-DGX-Spark/blob/878e0eecd893fadc69ad2d58b2df0fabb0fae2ee/release/runtime/sources/display_kv.c#L50-L92)
- [Thread 384884 — DGX Spark Memory Saver](https://forums.developer.nvidia.com/t/introducing-dgx-spark-memory-saver-more-memory-headroom-for-cuda-workloads/384884.json) · [christopherowen/dgx-spark-memory-saver](https://github.com/christopherowen/dgx-spark-memory-saver)
- [Thread 383222 — 7.2 GiB less RAM after DGX OS 7.5.0 OTA (KHO)](https://forums.developer.nvidia.com/t/dgx-os-7-5-0-ota-uefi-5-36-0acum027-7-2-gib-less-ram-available-at-boot/383222.json)
- [Thread 363849 — per-OEM VRAM differences on Spark](https://forums.developer.nvidia.com/t/difference-in-total-vram-available-for-different-sparks/363849.json)

Related notes on this site: [GLM-5.3-Flash on 4x DGX Spark — switched vs switchless ring](../glm-53-flash-4x-spark-switched-vs-switchless-ring/), [Qwen3.8-Flash-Next on an Intel Arc Pro B70](../intel-b70-inference-engine-research/)
