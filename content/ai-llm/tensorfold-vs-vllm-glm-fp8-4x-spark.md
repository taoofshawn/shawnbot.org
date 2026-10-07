---
title: "TensorFold vs vLLM for GLM-5.3-Flash FP8: what the new engine actually is, and whether its speedups can move a 4x DGX Spark ring"
date: 2026-10-06
summary: "TensorFold's headline GLM gains come from EXL3-trellis kernels and a lane scheduler that are quantization- and topology-specific — upstream CUDA is 10 days old, TP2-only, and one-request-at-a-time for GLM. For an FP8 checkpoint on TP4-over-switchless-ring with DFlash2 + SparkCache, the verdict is pass-and-watch; the one transferable idea is latent FP8 KV."
tags: [dgx-spark, tensorfold, vllm, glm, inference, exl3, fp8, speculative-decoding]
---

## The claim

[TensorFold](https://github.com/ashhart/TensorFold) is a new inference engine (alternative to vLLM) with a large claimed performance jump, customized toward very specific model-quantizations. The circulating claim — [forum thread 384789 post 30](https://forums.developer.nvidia.com/t/who-has-tested-tensorfold/384789/30) — is that you can "point Claude at TensorFold, implement all of its speed ups into VLLM, and hit the same speeds without the TensorFold headaches." Question: is anything in TensorFold adaptable to a **GLM-5.3-Flash FP8** deployment on a **4-node switchless ConnectX-7 ring** (vLLM TP4, DFlash2 speculative decoding, SparkCache + SIRCL KV offload, site-rebuilt NCCL 2.30.7, 262k context, ~5 concurrent sessions)?

**Short answer: pass-and-watch.** The headline gains are real but come from EXL3 4-bit-trellis kernels plus an engine-internal scheduler — neither transfers to FP8 weights, and upstream TensorFold cannot serve our topology or concurrency. One idea from the same community (latent FP8 KV) is worth queueing as a separate experiment. Evidence below.

## What TensorFold actually is

Single-maintainer engine ("ashhart") with an OpenAI-compatible API, [tensorfold.dev](https://tensorfold.dev) openly crediting a "Built with Mia's AI Lab" partnership. It was an **Apple-Silicon/MLX engine first**; **CUDA support landed only 2026-09-26** (v0.3.0) — the entire CUDA story is ~10 days old at the time of writing (latest release 0.6.6, Oct 6). Not on PyPI (git/brew install only).

Architecture, from the README/CHANGELOG rather than marketing:

- **Per-model-family bespoke implementations.** "Each model family supplies its own kernels and draft verification" — there is no generic engine. GLM, Qwen3.8-27B/Flash-Next, Nemotron, Gemma 4, DeepSeek-V4-Flash each get custom code.
- **A "lane/round" scheduler** — its genuinely distinctive piece. Concurrent streams share one verification round: multiple requests' rows verified together in one forward pass, with a byte-exact guarantee (concurrent output must equal solo output, enforced per-family at load). Prompts prefill *inside* decode rounds (TTFT 2.8–3.1× sooner in 0.6.0; 1.6 s → 0.15 s in 0.6.1).
- **Determinism as a design goal** — an omitted seed is derived from the prompt. Users report the flip side: the same input fails (loops) the same way every time, with no seed knob.
- **Spec decode**: MTP heads (adaptive depth via a measured cost model), DFlash2, DSpark — always verify-only, never changes output.
- **Kept prompt states / resume**: identical resend resumes from the kept prefix (18.7k-token resend 8.3 s → 0.08 s). Engine-internal prefix reuse — TF's analogue of SparkCache-style value, but nothing like cross-rank KV offload/transfer.
- **Multi-node: upstream supports max TP2**, one rank per Spark, and **GLM on CUDA serves one request at a time upstream**. A TP4-over-RoCE path exists only in a days-old fork (bertholomus, `glm-dsa-tp4`), for full GLM-5.3 (753B, *not* Flash), no DFlash2, with an RDMA QP-matching bug fixed 2026-10-04.

The concrete kernel-level optimizations (the things people port):

1. **Grouped EXL3 decode GEMV** — reads each distinct routed expert once per decode window instead of re-decoding trellis weights per 16-row tile (stock vLLM `exl3_moe` measured 140–199 GB/s vs 228–237 GB/s for the TF kernel). ~2.5× closer to fp64 reference; CUDA-graph safe.
2. **Fused EXL3 prefill kernels** ("fast2/fat"): 1.6–2.0× per MoE layer at ≥256-token chunks; deterministic combine instead of atomics.
3. **W8A16/FP8 dense-weight Triton kernels** at ~190–220 GB/s — for EXL3 checkpoints whose *non-expert* matrices are BF16.
4. **NVFP4 checkpoints in native math** (0.6.1): measured 1.4–2.0× vLLM decode single-stream on an RTX PRO 6000 — but prompts only 0.95–0.97× vLLM.
5. GLM CUDA specifics: MLX 4-bit or EXL3/TR3 4bpw checkpoints; latent (absorbed) FP8 KV; a default dense attention window of 2,051 tokens with the sparse indexer beyond it; DFlash2 reads only its sliding window.

## Evidence quality

| Claim | Source | Evidence quality | Verdict |
|---|---|---|---|
| TF decode 1.4–2.0× vLLM (NVFP4 27B) | TF 0.6.1 changelog | Measured, method given | Holds for that setup; prompts 0.95–0.97× vLLM |
| GLM-5.3-Flash ~50–60 tok/s C1 on 2 Sparks vs 21–32 on vLLM | [Mia's recipe](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold), [TechGuard](https://github.com/TechGuardCoders/glm53-tensorfold-spark-recipe), [forum #9/#11](https://forums.developer.nvidia.com/t/who-has-tested-tensorfold/384789/9) | Recipe-measured (Mia, sparkDash) vs single-run forum tables | Directionally real, magnitude varies by stack — TechGuard, who ran both, measures Mia's TF build only 15–19% faster at 4 concurrent |
| "62 tok/s peak, 97 combined ×4" | [forum #2/#4](https://forums.developer.nvidia.com/t/who-has-tested-tensorfold/384789/2) | Anecdotal, later corrected to 42/97 | Unverified |
| Restart 8–10 min → 85 s | [forum #9](https://forums.developer.nvidia.com/t/who-has-tested-tensorfold/384789/9) | Self-reported | Plausible, unverified |
| "Same speeds after porting TF speedups into vLLM" | [forum #30](https://forums.developer.nvidia.com/t/who-has-tested-tensorfold/384789/30) | **Code exists**: [Plaaasma/glm53-flash-dual-dgx-spark](https://github.com/Plaaasma/glm53-flash-dual-dgx-spark) commit 180bf21 (Oct 3, co-authored-by Claude), measured 22.7→34.1 tok/s C1 agent traffic, cold prefill ~1,000–1,220 tok/s | Porting is real; "same speeds" unproven vs tuned TF; the port is EXL3-specific |
| TF loops pathologically at high context | [forum #40/#45](https://forums.developer.nvidia.com/t/who-has-tested-tensorfold/384789/40), [381350 #696/#702](https://forums.developer.nvidia.com/t/glm-5-3-flash-320b-total-parameters-18b-active/381350/702) | One user, watchdog data: **7 TF restarts in one day for looping** vs entrpi's vLLM **0 loops in 22–23 h** on the same prompts; TF outputs 1.2–6× smaller; deterministic (no seed) | Strong single-source signal; the highest-risk finding for long-context document workloads |
| TF TP4 over CX7 RoCE works | [thread 385042](https://forums.developer.nvidia.com/t/full-glm-5-3-753b-on-4x-dgx-spark-3-bit-exl3-quant-tensorfold-tp4-recipe/385042) + bertholomus fork | Measured: ~43 code / ~28 prose single-stream, 82 tok/s at 4 streams — but prefill ~400 tok/s (76 s TTFT at 32K), fork days-old, different model family | Demonstrated, not productized |
| TF is faster for FP8 checkpoints | implicit in the circulating claim | [PR #328](https://github.com/ashhart/TensorFold/pull/328) (FP8 family) was **closed unmerged**, its own receipt admitting the TF FP8 path "trails vLLM on single stream and prompts" | **Not supported** |
| Benchmark hygiene | [forum #34/#37](https://forums.developer.nvidia.com/t/who-has-tested-tensorfold/384789/34), [tool-eval-bench PR #190](https://github.com/SeraphimSerapis/tool-eval-bench/pull/190) | llama-benchy miscounts TF prefill; tool-eval-bench needed the 2.7.1 patch to detect TF | Confirmed; disregard pre-patch comparisons |

## Does anything transfer to GLM-5.3-Flash FP8 on the 4x switchless ring?

**Quant format: almost none.** TF's flagship GLM speedups are EXL3-trellis decode/prefill kernels and W8A16 dense kernels for EXL3 checkpoints whose non-expert matrices are BF16. Our checkpoint is FP8 end-to-end — there is no BF16 or EXL3 layer to re-encode, and vLLM's FP8 kernels already run native FP8 math. The only FP8-native TF work is either tied to ModelOpt exports we don't have or was closed unmerged with a receipt showing it *trailing* vLLM. The headline gains do not transfer as kernels.

**Topology: mismatch.** Upstream TF = max TP2, GLM = one request at a time (we need ~5 concurrent sessions). The sparkring-adjacent innovation the TF recipes converge on — one-shot RoCE all-gathers — is adapted from the same b12x/local-inference-lab lineage our NCCL stack already comes from; TF's fork re-derives RoCE transport independently and less maturely than our site-rebuilt NCCL 2.30.7 ring. Nothing in TF is better than what the ring already does.

**SparkCache/SIRCL: no equivalent.** TF's memory model is engine-internal kept prompt states and checkpoint slots. Switching engines means reimplementing or losing cross-rank KV offload. DFlash2 exists on TF but only the plain drafter at TP2, not our k=7/3 hybrid schedule (and the drafter's CC BY-NC-ND license is an open issue in every recipe).

**The port-back claim, precisely:** what Plaaasma actually ported into vLLM is kernel-level EXL3 MoE work plus his own additions (8-bit dense weights, NVFP4 latent KV, dual-HCA NCCL) — not TF's lane scheduler, exactness machinery, or memory model. "All of its speed ups" is marketing; "most of the kernel-level speedups, in vLLM, with fewer headaches" is proven — and is EXL3-checkpoint-specific, so it's evidence of feasibility, not reusable code for FP8.

## What *is* worth taking, ranked

1. **Serving-temperature audit (cheap, do this)** — a real trap documented by TechGuardCoders: TF/vLLM-lineage recipes only draft DFlash2 on greedy requests, and clients that omit `temperature` get the model's default 1.0. Their fix (server-side default temperature 0) took acceptance from 4.36 → 5.73 tokens/step (~68 → ~83 tok/s). Worth verifying our DFlash2 acceptance isn't silently degraded by temperature-omitting clients.
2. **Latent FP8 / NVFP4 KV compression (not TF's invention, but from the same GLM-5.3-Flash vLLM family)** — Plaaasma's NVFP4 latent KV measures 288 vs 656 B/token, i.e. ~2.3× KV capacity, which would materially relieve our 16 GiB pool / 5-session design point. Highly invasive, but it is a vLLM-side change — the one candidate worth queueing as a separate future experiment.
3. **Scheduler-level ideas (no code)**: prefix-checkpoint eviction hygiene (KDA checkpoints + refresh-on-hit — relevant to SparkCache eviction at 262k ctx × 5 sessions), mixed-prefill ladders sized by decoding peers.

## Opinion: how to move forward

- **Don't switch engines, don't port TF kernels.** The two things that would make TF interesting for us — a GLM FP8 family and upstream TP4 — don't exist. Evaluating properly means re-quantizing to EXL3 4bpw, standing up Mia's TP2 recipe on 2 of 4 nodes, and abandoning TP4, the DFlash2 hybrid, and SparkCache — days of effort against the engine's one longitudinal quality signal (7 looping restarts/day vs 0 for the vLLM-based engine at exactly our workload shape: long-context document processing).
- **Revisit triggers**: upstream lands a GLM FP8 checkpoint family; the TP4 fork ports to GLM-5.3-Flash with DFlash2 and multi-stream; or the looping/determinism issue gets a fix plus 24h-soak evidence.
- **The decisive experiment, if pursued**: don't A/B engines — A/B *quantizations*. The real question is "does EXL3 4bpw + TensorFold beat FP8 + our vLLM at all." Run Mia's TP2 recipe on two nodes against our stack on the same harness: tool-eval-bench ≥ 2.7.1, RigMark for decode/prefill (not llama-benchy — known broken on TF), acceptance rates with temperature pinned to 0, and a ≥24 h document-processing soak with a loop watchdog. If TF/EXL3 doesn't beat our FP8 stack on that battery, the topic is closed.

## Sources

- [Forum thread 384789 — Who has tested TensorFold (45 posts)](https://forums.developer.nvidia.com/t/who-has-tested-tensorfold/384789.json)
- [ashhart/TensorFold](https://github.com/ashhart/TensorFold) (README/CHANGELOG/RUNBOOK) · [tensorfold.dev](https://tensorfold.dev) · [PR #328 (FP8 family, closed unmerged)](https://github.com/ashhart/TensorFold/pull/328)
- [MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold) · [jayleaton/glm53-tensorfold-spark](https://github.com/jayleaton/glm53-tensorfold-spark) · [TechGuardCoders/glm53-tensorfold-spark-recipe](https://github.com/TechGuardCoders/glm53-tensorfold-spark-recipe) · [jordanm82/glm53-tensorfold-2xspark](https://github.com/jordanm82/glm53-tensorfold-2xspark) · [Entrpi/glm-5.3-flash-exl3-2x-spark](https://github.com/Entrpi/glm-5.3-flash-exl3-2x-spark)
- [Plaaasma/glm53-flash-dual-dgx-spark](https://github.com/Plaaasma/glm53-flash-dual-dgx-spark) — the actual "TensorFold speedups into vLLM" port
- [Thread 385042 — Full GLM-5.3 (753B) on 4x DGX Spark, TensorFold TP4](https://forums.developer.nvidia.com/t/full-glm-5-3-753b-on-4x-dgx-spark-3-bit-exl3-quant-tensorfold-tp4-recipe/385042) · [Thread 385074 (TP=2 A/B vs DeepSeek)](https://forums.developer.nvidia.com/t/2x-dgx-spark-deepseek-v4-flash-0731-stable-build/385074) · [Thread 381350 (looping comparison #696/#702)](https://forums.developer.nvidia.com/t/glm-5-3-flash-320b-total-parameters-18b-active/381350)
- [tool-eval-bench PR #190 — TensorFold support](https://github.com/SeraphimSerapis/tool-eval-bench/pull/190)

Related notes on this site: [GLM-5.3-Flash on 4x DGX Spark — switched vs switchless ring](../glm-53-flash-4x-spark-switched-vs-switchless-ring/), [Reclaiming the GB10 display carve-out](../gb10-display-carveout-ram-reclaim/), [Qwen3.8-Flash-Next on an Intel Arc Pro B70](../intel-b70-inference-engine-research/)
