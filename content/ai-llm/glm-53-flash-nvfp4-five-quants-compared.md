---
title: "GLM-5.3-Flash quants compared: five NVFP4 checkpoints in depth, plus the top-20 of every precision on accuracy"
date: 2026-10-09
summary: "RadixArk, NVIDIA, RedHatAI, LibertAI and local-inference-lab all ship an NVFP4 GLM-5.3-Flash that differs far less in size (195-204 GB) than in quantization scheme: W4A4 vs weight-only, what stays BF16, MTP handling, calibration, and one checkpoint whose expert weights are actually retrained — with the tensor-scale math to verify each card's claims. A same-day appendix widens the lens to the 20 most-downloaded quants of any precision, accuracy only."
tags: [glm, nvfp4, quantization, vllm, sglang, dgx-spark, blackwell, inference]
---

Z.ai's GLM-5.3-Flash (320B total / 18B active, natively multimodal MoE with hybrid KDA linear attention + DeepSeek sparse attention, 1M context) shipped in August 2026 as a ~643 GB BF16 repo, with a 328 GB "main" repo that is actually a mixed FP8 export (BF16 attention, FP8 experts). NVFP4 — 4-bit E2M1 weights with FP8-E4M3 per-16 block scales and an FP32 global scale, a native Blackwell tensor-core format — is the obvious fit for it on GB10/GB300/RTX-class hardware, and within weeks five distinct quantizations had accumulated 100K, 87K, 51K, 26K and 7K downloads respectively. This note is a deep dive into what actually differs between them: which tensors are quantized and how, on-disk size, claimed accuracy, real measured speed on Spark-class hardware, and the serving gotchas each one carries.

Popularity here means Hugging Face download counts of repos tagged `base_model:quantized:zai-org/GLM-5.3-Flash` (or its BF16 sibling), as of 2026-10-09. The most-downloaded GLM-5.3-Flash quant overall is unsloth's GGUF (~1M downloads) — excluded, it is not NVFP4, and llama.cpp has no `glm5_next` support anyway. [^libert]

## The field

| Repo | Downloads | Likes | Created | Base | Size (safetensors) |
|---|---:|---:|---|---|---:|
| [RadixArk/GLM-5.3-Flash-NVFP4](https://huggingface.co/RadixArk/GLM-5.3-Flash-NVFP4) [^radixark] | 103,478 | 8 | 2026-08-27 | BF16 | 202.9 GB |
| [nvidia/GLM-5.3-Flash-NVFP4](https://huggingface.co/nvidia/GLM-5.3-Flash-NVFP4) [^nvidia] | 87,488 | 153 | 2026-09-02 | FP8-mixed main repo | 204.4 GB |
| [RedHatAI/GLM-5.3-Flash-NVFP4](https://huggingface.co/RedHatAI/GLM-5.3-Flash-NVFP4) [^redhat] | 51,240 | 43 | 2026-08-27 | FP8-mixed main repo | 197.8 GB |
| [LibertAIDAI/GLM-5.3-Flash-NVFP4](https://huggingface.co/LibertAIDAI/GLM-5.3-Flash-NVFP4) [^libert] | 25,727 | 67 | 2026-08-26 | FP8-mixed main repo | 194.7 GB |
| [local-inference-lab/GLM-5.3-Flash-NVFP4](https://huggingface.co/local-inference-lab/GLM-5.3-Flash-NVFP4) [^lil] | 6,415 | 44 | 2026-08-27 | BF16 | 199.4 GB |

(The literal #5 by downloads is [dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4](https://huggingface.co/dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4) at 7,198 — covered separately at the bottom, because it is not a distinct quantization.)

Reference points: the BF16 source is 642.7 GB [^bf16], the FP8-mixed main repo 328.3 GB [^fp8]. Every NVFP4 lands within a 10 GB band (195-204 GB, 30-32% of BF16), because in all five the routed experts (~90-97% of parameters) go to 4 bits and everything else stays high precision. The differences are entirely in *which* everything else, *which* precision the activations use, and *how the weights were produced*.

## TL;DR

- **Want the safest default:** **nvidia/GLM-5.3-Flash-NVFP4** — the only one with a controlled same-harness BF16-vs-NVFP4 accuracy table (and the deltas are noise-level), broadest engine support (vLLM and SGLang), plus the community-validated Spark recipes.
- **Want SGLang with NEXTN speculative decoding:** **RadixArk** — the SGLang-native card, validated on 4× GB300, with audit files (`tensor-audit-b.json`, `precision-contract-b.json`) nobody else ships.
- **Want vLLM with llm-compressor/compressed-tensors tooling:** **RedHatAI** — cleanest W4A4 expert-only scope, MTP layer kept at FP8 for speculative decoding.
- **Want minimal GPU memory / 2× GB10-class boxes:** **LibertAI** — the only weight-only (NVFP4-A16) build, smallest of the five, and by far the best-documented pitfalls (including a wild input-scale saga, below).
- **Want a checkpoint whose quality was *trained* against quantization:** **local-inference-lab** — the only quantization-aware-distilled build (expert weights retrained under a BF16 teacher); no published benchmarks of its own, which is the main caveat.

## The precision map (verified from tensor counts, not just READMEs)

All five are "MoE expert" quants — attention (both KDA linear layers and the 11 DSA sparse layers + indexer), routers, embeddings, `lm_head`, norms, and the vision tower stay BF16 everywhere. The real differences:

| | RadixArk | nvidia | RedHatAI | LibertAI | local-inference-lab |
|---|---|---|---|---|---|
| Format | ModelOpt 0.46 | ModelOpt 0.47 | compressed-tensors (llm-compressor) | ModelOpt 0.45 | ModelOpt 0.39, mixed |
| Scheme | **W4A4** (calibrated input scales) | **W4A4** (calibrated input scales) | **W4A4** (calibrated input scales) | **W4A16 weight-only** (activations BF16) | **W4A16 storage**, optional W4A4 via shipped scales |
| NVFP4 scope | routed experts (42 MoE layers × 288 × 3) + shared experts + dense MLPs of layers 0-2 = 36,423 linears | routed experts + dense MLPs (0-2) = 36,297 linears; shared experts stay BF16 | routed experts only, layers 3-44 (36,288); shared experts stay BF16 | routed experts only, **layers 3-45 including MTP** (37,152) | routed experts layers 3-44 (36,288), **distilled** |
| MTP draft layer | BF16 (excluded) | BF16 (excluded) | **FP8 experts**, dynamic FP8 activations | NVFP4 experts (like every other layer) | **MXFP8** experts (E4M3, pow-2 scales per 32) |
| Calibration | 1,024 cnn_dailymail samples @512 | cnn_dailymail + Nemotron-PTD-v2 | llm-compressor static_minmax | none (weight-only), input scales later borrowed from RedHat's calibration | 200M-token chat corpus, per-expert |
| KV cache in config | not declared | **fp8 (float-8) declared in quant config** | not declared | not declared (recipe uses bf16 on GB10) | not declared |

The scale-tensor arithmetic in each repo's `model.safetensors.index.json` pins these down harder than the READMEs do, and it resolves three card-vs-card contradictions:

- **RadixArk's README says W4A4 with "abs-max scaling, no calibration needed", but ships 36,423 `input_scale` tensors anyway** — exactly 36,288 (routed) + 126 (shared experts, 42×3) + 9 (dense MLPs 0-2). That is a static, calibrated W4A4 checkpoint (their card does list the cnn_dailymail calibration), and the count also independently confirms the shared-expert and dense-MLP scope their README claims. [^radixark]
- **NVIDIA's card sentence "only the linear operators within sparse MoE shared experts and dense MLP are quantized" is misleadingly worded**: the ignore list and the scale counts (36,297 input scales = 36,288 routed + 9 dense-MLP; block+global scales 2×36,297) show the shared experts are *not* quantized — matching their own ignore list and the GLM-5.2 card convention. [^nvidia]
- **LibertAI's "what's quantized" table says the MTP head stays BF16, but the config ignore list contains no layer-45 expert entries and the index ships 37,152 = 43×288×3 weight scales** — the MTP routed experts are NVFP4 like every other layer (only MTP's attention/`eh_proj` stay BF16). Their 37,152 `input_scale` tensors are the August-30 fix: 36,288 real calibrated values *taken from RedHat's calibration of the same base*, 864 MTP entries filled with the median. [^libert]
- **RedHatAI's index shows exactly 36,288 NVFP4 weight scales + 864 FP8-era globals for layer 45**, matching their claim of FP8 MTP experts; it is the only checkpoint where the draft layer's experts are neither NVFP4 nor BF16. [^redhat]

## Size and memory footprint

| Repo | GB | vs BF16 source | Notes |
|---|---:|---:|---|
| LibertAI | 194.7 | 30.3% | smallest; 121 shards (shard-streamed CPU quant); MTP experts at 4-bit |
| RedHatAI | 197.8 | 30.8% | MTP experts FP8 saves vs 4-bit MTP only marginally; 11 shards |
| local-inference-lab | 199.4 | 31.0% | + `amax_checkpoint.json` / distillation metadata |
| RadixArk | 202.9 | 31.6% | from the true-BF16 repo |
| nvidia | 204.4 | 31.8% | from the FP8-mixed repo; + fp8 KV scheme |
| (source) BF16 | 642.7 | 100% | 120 shards [^bf16] |
| (source) FP8-mixed | 328.3 | 51.1% | what three of the five quantized *from* [^fp8] |

Two nuances on "which source is better". Quantizing experts from an FP8 export means the 4-bit values derive from already-8-bit-rounded weights — dabsLabs built their (much-less-downloaded) quant specifically from the BF16 repo to avoid this "double quantization". [^dabs] In practice the measured penalty looks negligible: LibertAI (FP8 source) reports per-expert relative reconstruction error ≈0.0925 vs NVFP4's intrinsic floor ≈0.093, and tattrongvu's FP8-sourced quant measures 0.0918 — both at the format's limit. [^tattrongvu] The other nuance runs the other way: on a *memory*-per-token basis what matters is that all five fit a 2× DGX Spark cluster at TP=2 (≈90-100 GB/rank) where the BF16 original cannot, which is exactly why NVFP4 became the Spark-community default.

## Accuracy: what's claimed, and what it can be compared against

Only NVIDIA publishes a same-harness BF16-vs-NVFP4 A/B — the single most useful table, since it isolates the quantization effect (GB200, temp 1.0, top_p 0.95): [^nvidia]

| Benchmark | BF16 | NVFP4 | Δ |
|---|---:|---:|---:|
| GPQA Diamond | 0.9217 | 0.9211 | −0.06 pp |
| SciCode | 0.5621 | 0.5769 | +1.48 pp |
| MMMU Pro | 0.7688 | 0.7630 | −0.58 pp |
| AA-LCR | 0.7100 | 0.7106 | +0.06 pp |
| IFBench | 0.6130 | 0.6054 | −0.76 pp |
| Terminal Bench 2.1 | 0.8258 | 0.8315 | +0.57 pp |

That is noise-level degradation — consistent with NVFP4's track record on other MoE families (NVIDIA's GLM-5.2 and 5.1 NVFP4 cards show the same pattern). [^glm52]

The others publish absolute numbers under different harnesses/hardware, so they cannot be ranked against each other — treat the following as "is it broken?" checks, not rankings:

- **RadixArk** (4× GB300, SGLang, NEXTN spec): GSM8K 97.14% (4 seeds), AIME 2026 92.45% (1,920 generations), Terminal-Bench 2.1 83.1% pass@1. Note their TB 2.1 lands within 0.1 pp of NVIDIA's 83.15% on a different stack — a decent cross-check. [^radixark]
- **RedHatAI** (vLLM, lm-eval-harness/lighteval, 3 seeds): GSM8K Platinum 97.74%, MATH-500 94.87%, AIME 2025 86.67%, GPQA Diamond 90.57% — no baseline row, so the −1.5 pp GPQA gap vs NVIDIA's table is harness + hardware + seed variance, not evidence of a worse quant. [^redhat]
- **LibertAI publishes nothing, deliberately**: "we would rather publish nothing than publish a number we did not measure." [^libert]
- **local-inference-lab publishes no benchmarks either** — the claim is structural (distillation compensates quantization error) rather than scoreboarded. [^lil]

One qualitative counter-signal from the field: a DGX Spark forum user reported severe vision hallucinations on non-UI imagery while running the **RedHatAI** checkpoint (a second user suggested trying an EXL3 encode instead and reported the same images working there). [^forum-vision] One anecdote, wrong-tool-or-quant unknown — but it is the only "NVFP4 broke something for me" report I found for any of the five.

## Measured speed on Spark-class hardware

All forum numbers below are for NVFP4 checkpoints (mostly NVIDIA's), on GB10 DGX Sparks (121 GB unified memory each, ~270 GB/s bandwidth) unless noted. [^forum-2x] [^forum-3x] [^forum-kindling] [^forum-scaling]

- **2× Spark, vLLM TP=2** (docker-compose patch chain): 262K ctx ≈ 14.3 tok/s bf16 KV → ≈21.8 tok/s with fp8 KV + MTP-4; later standing config 512K ctx, 24-30 tok/s c1, 180-364 tok/s chunked prefill, 1.26M-token fp8 KV pool, 89/100 tool-eval hardmode, byte-exact 440K needle retrieval.
- **3× Spark, TP=3** (LibertAI checkpoint, MTP-4): 35.2 tok/s c1 decode, ~1,800 tok/s prefill, 1.5M KV pool, 512K context. Author's own conclusion: **TP=3 is a memory upgrade, not a throughput upgrade** — prefill and decode identical within noise vs TP=2; only weights/rank (90→64 GiB) and KV pool moved.
- **3× Spark, kindling stack TP=3** (NVIDIA checkpoint + DFlash2 drafter): ~3,100-3,500 tok/s cold prefill (64K prompt ready in 20 s), 156/179 tok/s aggregate prose at 8/12 streams (code ~480), 3.05M-token fp8 KV pool, 64-way serving; GSM8K 96.4%, HumanEval 94.5%. A second user reproduced: prefill ~3,200 tok/s at 260K prompts, decode 56.5 c1 prose / 98.7 JSON, TTFT 151-189 ms.
- **Concurrency scaling is the weak spot**: NVFP4 + DFlash2 on 2× Sparks went 33 → 43 tok/s aggregate from c1 to c4, versus 31 → 98 for DeepSeek-V4-Flash DSpark on identical hardware — the GLM stack "does not scale with concurrency" in that user's testing; a native-MTP k=3 run on a W4A16 Intel quant scaled 58 → 73 from a higher floor.
- **4× RTX PRO 6000 Blackwell (96 GB each)**: the local-inference-lab checkpoint runs over PCIe-only TP=4 — no performance numbers posted. [^forum-rtx6000]

For single-stream decode the NVFP4 Spark numbers cluster around 20-35 tok/s depending on stack, spec decoding, and context — nobody claims more, and the DFlash2-drafter variants trade concurrency headroom for that single-stream speed.

## Serving gotchas that differ per checkpoint

- **The LibertAI input-scale saga (a W4A16-in-vLLM hazard).** vLLM's `ModelOptNvFp4FusedMoE` requires an activation scale; a weight-only checkpoint without one gets an *uninitialized* scale — every expert multiplied by zero, model emits one token repeatedly, no error. LibertAI's first fix (input_scale = 1.0) was itself wrong: the underflow bound is per-16-block, so 1.0 flushed fp8 block scales to zero for low-amax blocks and degraded output *intermittently, worse with context* (reproduced on GB300). Final fix: real per-projection calibrated scales (median 1.58e-03 — the 1.0 placeholder was 632× too high). The cleaner path — the `compressed-tensors` branch with no activation quant at all — still failed to load in their test. [^libert] If you run weight-only NVFP4 through vLLM's ModelOpt MoE path, check for exactly this.
- **Reasoning/tool parsers are engine-specific and fail silently.** SGLang wants `--reasoning-parser glm45`; vLLM's `glm45` is a different parser that silently discards the whole reply against this model (use `deepseek_r1`). Tool calls: `--tool-call-parser glm` (the GLM-4.5 parser) fails *silently* — empty content, `tool_calls: null` — use `glm47`. [^libert]
- **GB10-specific**: the 34 KDA linear-attention layers need a per-request recurrent state cache, so on tight memory **concurrency, not KV, is the first thing that runs out** (fix: lower `--max-running-requests` before context); the DSA TileLang backend is bf16-KV-only and needs a shared-memory tile patch on GB10 (169,984 B requested vs 101,376 B available — `block_I=32, num_stages=1, threads=128`). [^libert] RadixArk's card adds that fp8 KV ≈ 1.8× token capacity vs bf16 KV with the TRT-LLM DSA backends. [^radixark]
- **Vendor image pinned per model**: all five assume the `glm53-flash` per-model vLLM/SGLang images (`glm5_next` is not in upstream vLLM `main`); LibertAI additionally documents that vLLM launches must point at a *local directory*, not the repo id (a `processor_config.json` path-resolution bug). [^libert]

## What about dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4 (the literal #5)?

It is an abliterated ("uncensored") derivative of the base model, not a new quantization technique: 194.7 GB in 121 shards, 37,152 weight scales + globals and **zero input scales** — i.e. the same weight-only ModelOpt recipe as LibertAI's original August-26 build (same shard count, same size), with no evidence of LibertAI's August-30 input-scale fix. Its card's real content is an unusually detailed serving-warning block (reasoning_effort levels resolving to `max`, empty replies under small `max_tokens`, media parameters silently ignored). If you download it for vLLM use, assume the uninitialized-input-scale failure mode applies and use the marlin backend or a scale plugin; for SGLang it should behave like any weight-only checkpoint. [^dealign]

## Which one, practically

For this cluster's world (GB10 Sparks, vLLM/SGLang, agentic serving): **nvidia's** for the validated-accuracy default and the best-covered Spark recipes, **RadixArk's** if you are SGLang-only and want NEXTN spec, **RedHatAI's** if your tooling is compressed-tensors-based, **LibertAI's** when memory is the binding constraint (and you read its warnings), and **local-inference-lab's** if you want to bet that distillation beats post-training quantization — a bet its own repo, unusually, does not ask you to take on faith alone but also does not yet evidence with numbers.

## Sources

[^nvidia]: [huggingface.co — nvidia/GLM-5.3-Flash-NVFP4 model card](https://huggingface.co/nvidia/GLM-5.3-Flash-NVFP4) (plus its `config.json` and `model.safetensors.index.json`).

[^radixark]: [huggingface.co — RadixArk/GLM-5.3-Flash-NVFP4 model card](https://huggingface.co/RadixArk/GLM-5.3-Flash-NVFP4) (plus `tensor-audit-b.json`, `precision-contract-b.json`, config/index).

[^redhat]: [huggingface.co — RedHatAI/GLM-5.3-Flash-NVFP4 model card](https://huggingface.co/RedHatAI/GLM-5.3-Flash-NVFP4) (plus config/index).

[^libert]: [huggingface.co — LibertAIDAI/GLM-5.3-Flash-NVFP4 model card](https://huggingface.co/LibertAIDAI/GLM-5.3-Flash-NVFP4), including the 2026-08-30 input-scale update note, [discussion #7](https://huggingface.co/LibertAIDAI/GLM-5.3-Flash-NVFP4/discussions/7) (GB300 underflow report) and the [Libertai/glm53-flash-vllm-gb10](https://github.com/Libertai/glm53-flash-vllm-gb10) recipe.

[^lil]: [huggingface.co — local-inference-lab/GLM-5.3-Flash-NVFP4 model card](https://huggingface.co/local-inference-lab/GLM-5.3-Flash-NVFP4).

[^dealign]: [huggingface.co — dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4](https://huggingface.co/dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4); scheme verified from its `model.safetensors.index.json` (no input-scale tensors).

[^tattrongvu]: [huggingface.co — tattrongvu/GLM-5.3-Flash-NVFP4](https://huggingface.co/tattrongvu/GLM-5.3-Flash-NVFP4) — source of the NVFP4 reconstruction-floor measurements (0.0918 vs floor ≈0.093) and the SGLang NextN `modelopt_mixed` config fix.

[^dabs]: [huggingface.co — dabsLabs/GLM-5.3-Flash-NVFP4](https://huggingface.co/dabsLabs/GLM-5.3-Flash-NVFP4) — the BF16-sourced (no double-quantization) compressed-tensors build.

[^bf16]: [huggingface.co — zai-org/GLM-5.3-Flash-BF16](https://huggingface.co/zai-org/GLM-5.3-Flash-BF16): 642.7 GB across 120 shards (size from the HF blobs API, 2026-10-09).

[^fp8]: [huggingface.co — zai-org/GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash): 328.3 GB, `fp8` tag (HF blobs API, 2026-10-09); BF16 attention + FP8 experts per [^libert].

[^glm52]: [huggingface.co — nvidia/GLM-5.2-NVFP4](https://huggingface.co/nvidia/GLM-5.2-NVFP4) and [nvidia/GLM-5.1-NVFP4](https://huggingface.co/nvidia/GLM-5.1-NVFP4) — the same noise-level NVFP4 delta pattern on the prior GLM generations.

[^forum-2x]: [forums.developer.nvidia.com — "GLM-5.3-Flash-NVFP4 on 2× DGX Spark — vLLM TP=2, docker compose" (#381541)](https://forums.developer.nvidia.com/t/glm-5-3-flash-nvfp4-on-2x-dgx-spark-vllm-tp-2-docker-compose/381541).

[^forum-3x]: [forums.developer.nvidia.com — "GLM-5.3-Flash NVFP4 on 3× DGX Spark — TP=3, 512K context, 35 tok/s" (#381534)](https://forums.developer.nvidia.com/t/glm-5-3-flash-nvfp4-on-3x-dgx-spark-tp3-512k-context-35-tok-s/381534).

[^forum-kindling]: [forums.developer.nvidia.com — "GLM-5.3-Flash NVFP4 on 3x DGX Spark, stock DGX OS: ~3,300 tok/s prefill, 3M-token KV, 64 concurrent (kindling TP=3)" (#385075)](https://forums.developer.nvidia.com/t/glm-5-3-flash-nvfp4-on-3x-dgx-spark-stock-dgx-os-3300-tok-s-prefill-3m-token-kv-up-to-64-concurrent-requests-kindling-tp-3/385075).

[^forum-scaling]: [forums.developer.nvidia.com — "GLM-5.3-Flash (NVFP4+DFlash2) on 2x Spark: does not scale with concurrency" (#384591)](https://forums.developer.nvidia.com/t/glm-5-3-flash-nvfp4-dflash2-on-2x-spark-does-not-scale-with-concurrency-anyone-else-seeing-this/384591).

[^forum-rtx6000]: [forums.developer.nvidia.com — "Running GLM-5.3-Flash-NVFP4 on 4x RTX PRO 6000 Blackwell" (#384129)](https://forums.developer.nvidia.com/t/running-glm-5-3-flash-nvfp4-on-4xrtx-pro-6000-blackwell/384129).

[^forum-vision]: [forums.developer.nvidia.com — "GLM 5.3 flash NVFP4 lots of hallucinations and spatial confusion on non UI coding tasks" (#383674)](https://forums.developer.nvidia.com/t/glm-5-3-flash-nvfp4-lots-of-hallucinations-and-spatial-confusion-on-non-ui-coding-tasks-is-there-a-fix/383674).

## Appendix, same day: the top 20 of every precision, accuracy only

Ranked strictly by HF downloads (2026-10-09 snapshot) among quants of the base model, **excluding zai-org itself**; any format counts. The NVFP4 five above are #2, #3, #4, #8, #20; the other fifteen slots go to GGUF (8 repos), FP8 (2), MXFP4 (2, AMD and NVIDIA-flavored), MLX (1), W4A16 int4 (2), and two **structurally different** builds (expert-pruned, expert-disk-streamed). This appendix is deliberately accuracy-only: precision/quality claims and measurements, no speed. [^counts-note]

| # | Repo | Downloads | Format | Accuracy evidence on the card |
|---:|---|---:|---|---|
| 1 | unsloth/GLM-5.3-Flash-GGUF | 999,574 | GGUF, UD dynamic tiers 1→8 bit + BF16 | none of its own for this model |
| 2 | RadixArk/GLM-5.3-Flash-NVFP4 | 101,506 | NVFP4 W4A4 | GSM8K 97.14, AIME26 92.45, TB2.1 83.1 (above) |
| 3 | nvidia/GLM-5.3-Flash-NVFP4 | 89,460 | NVFP4 W4A4 | the BF16-vs-NVFP4 A/B (above) |
| 4 | RedHatAI/GLM-5.3-Flash-NVFP4 | 50,089 | NVFP4 W4A4 | GSM8K-P 97.74, MATH-500 94.87, AIME25 86.67, GPQA-D 90.57 (above) |
| 5 | dealignai/GLM-5.3-Flash-UNCENSORED-FP8 | 49,057 | FP8 block e4m3, abliterated | MMLU-logit 87.33 vs base 86.74 (+0.59 pp) [^dealign-fp8] |
| 6 | autotrust/GLM-5.3-Flash-GGUF-DGX-Spark | 34,095 | GGUF 2-bit + 11% expert pruning | 35/40 ds4-eval cases; PPL 12.4 on agent traces |
| 7 | pfeifferj/GLM-5.3-Flash-GSQ-RCO-GGUF | 29,635 | GGUF ~3.0/3.5-bit, learned mixed layout | MMLU-Pro 60.0/60.55 vs Q8_0's 61.95 |
| 8 | LibertAIDAI/GLM-5.3-Flash-NVFP4 | 25,083 | NVFP4 weight-only | none published (above) |
| 9 | amd/GLM-5.3-Flash-Quark-MXFP4 | 22,026 | MXFP4 W4A4 (AMD Quark) | GSM8K 97.19 (TP4) / 97.12 (TP8+EP8), full 1,319 [^amd] |
| 10 | aj9o9/GLM-5.3-Flash-GGUF | 22,013 | GGUF 2.23/2.80 bpw | PPL 4.23/3.01 (1.88×/1.34× BF16), KLD 0.707/0.356 |
| 11 | huihui-ai/Huihui-…-abliterated-GGUF | 21,184 | GGUF, re-upload of unsloth + ablated L15-35 | none; quality inherits unsloth |
| 12 | orcarouter/GLM-5.3-Flash-Uncensored-GGUF | 17,898 | GGUF Q2→Q6, abliterated | vs Q8_0: Q6_K KLD 0.026 → Q2_K 0.486 |
| 13 | peasantsmith/GLM-5.3-Flash-Maya-GGUF | 13,089 | GGUF ~2-bit experts, expert-tiering engine | Maya-L = 99.2% of FP8 zero-shot acc; KLD 0.188 |
| 14 | canada-quant/GLM-5.3-Flash-W4A16-MTP | 11,673 | int4 W4A16 + BF16 MTP | AIME25 0.8833, AIME26 85.0%, GPQA-D 0.8586, MMMU 0.747 [^canada] |
| 15 | autotrust/GLM5.3-Flash-E224-DGX-Spark | 11,534 | NVFP4 + NAS expert-pruned 288→224 | GPQA-D 90.9, AIME25 88.3, HumanEval 98.2 [^e224] |
| 16 | Justvugg/GLM-5.3-Flash-colibri-int4-g64 | 11,475 | int4 g64 (custom disk-stream container) | none for this model; GLM-5.2 analogy |
| 17 | bartowski/GLM-5.3-Flash-BF16-GGUF | 10,967 | GGUF, imatrix, per-tensor computed layouts | layout KL A/B only (Q4_K_M 0.93× std KL) |
| 18 | orcarouter/GLM-5.3-Flash-MLX | 10,918 | MLX, per-module dynamic 2→8 bit | vs FP8: 4-bit PPL +2.96%, KLD 0.0131 |
| 19 | patrickbdevaney/GLM-5.3-Flash-REAP50-GGUF | 10,891 | GGUF 4-bit + REAP 50% expert pruning | top-1 agreement 0.8425 vs unpruned FP8 |
| 20 | OneNexus/GLM-5.3-Flash-MXFP4 | 10,147 | MXFP4 W4A4 (Quark-revised) | paired vs AMD's: MMLU +1.0 pp, GPQA-D +3.5 pp |

(For reference the original publisher's repos are 6.35M / 67.7K downloads.) [^counts-note]

### What the accuracy evidence actually shows

The twenty cards split into three evidence cultures, and the differences between them matter more than any single number:

**Culture 1 — benchmark scoreboards against an external baseline** (the vendor-style quants): NVIDIA, RadixArk, RedHatAI, AMD, canada-quant, autotrust E224, dealignai-FP8, OneNexus. Absolute scores on GSM8K/AIME/GPQA/MMMU-class suites. Canada-quant's companion page is the most transparent of the whole set (every grid, protocol, and a logged retraction of its own earlier NVFP4 comparisons — including one where NVIDIA's checkpoint beat theirs — after discovering a drafter bug had corrupted the read). [^canada] OneNexus is the only repo that runs a *paired statistical test against a competitor checkpoint on identical fixed samples*, and reports its own +3.5 pp GPQA win over AMD as **not significant** (p = 0.265). [^onenexus]

**Culture 2 — token-level fidelity against a reference run** (the llama.cpp/MLX ecosystem): aj9o9, pfeifferj, orcarouter (×2), peasantsmith, patrickbdevaney, bartowski. Same idea everywhere: run the reference (BF16, FP8, or Q8_0) and the quant on identical text and measure perplexity ratio, KL divergence, and top-1 token agreement. The consistent finding across all six:

- **4-bit is nearly free, 2-bit is where models break.** orcarouter-MLX: 4-bit PPL +2.96% (KLD 0.013), 3-bit +9.96%, 2-bit +56.9%, "2bit-lite" +141%. orcarouter-GGUF: Q4_K_M KLD 0.087, Q3_K_M 0.176, Q2_K 0.486 ("pick it for fit, not quality"). [^orca] [^orca-mlx]
- **3-bit mixed-precision layouts can land within ~2 pp of an 8-bit reference** on MMLU-Pro (pfeifferj: 60.55/60.00 vs 61.95 at 3.5/3.0 bpw) — non-uniform allocation buys a lot at small budgets. [^pfeifferj]
- **Careful 2-bit + pruning can retain most capability on narrow domains while collapsing on breadth**: autotrust's 79 GiB 2-bit build passes 35/40 hard reasoning cases, and peasantsmith's Maya-L holds 99.2% of FP8 *zero-shot* accuracy while being ~2-bit in its experts — but REAP50's own per-domain table shows the cost is pushed onto generic text (top-1 agreement 0.92 on math, 0.58 on "ballast" prose). [^autotrust-gguf] [^maya] [^reap]
- **The measurement harness itself is a hazard on this architecture**: aj9o9 documents that llama-perplexity's default multi-sequence batch path silently returns NaN or diverges on glm5_next, and that their own earlier published numbers used it ("any perplexity figure for this architecture published without -b 512 should be treated with suspicion"). [^aj9o9]

**Culture 3 — no measurement at all**: unsloth (the #1 repo by 10× — its card here is a pointer to docs and its own Dynamic-3.0 marketing claim, with the base model's vendor benchmark table reproduced) [^unsloth], huihui-ai (re-quant of unsloth's files with layers 15-35 ablated, zero quality data) [^huihui], Justvugg (honest about it: "no independent benchmark of this container has been published yet", offers a GLM-5.2 analogy) [^colibri], LibertAI (deliberately, as covered above), wtdcode (a card listing only what's quantized — no numbers) [^wtdcode], and the two prune/stream builds' GGUF wrappers beyond what's cited. The most-downloaded GLM-5.3-Flash quant in the world publishes no accuracy evidence for this model.

### Cross-format accuracy reading, in one paragraph

Where numbers overlap, they tell one consistent story. Full-precision-class formats are all noise-level from their sources: NVIDIA's NVFP4 A/B, dealignai's +0.59 pp MMLU after weight editing, bartowski's layout variants within ±8% KL of each other. Everything at ~4 bits (NVFP4, MXFP4, MLX 4-bit, GGUF Q4_K_M, int4 W4A16) lands in the same band — PPL penalties of roughly +3-9% and KLD of 0.01-0.09, or benchmark deltas within a couple of points — regardless of vendor or format, which is the practical meaning of "4-bit is free": *scheme choice matters far less than bit-width at this range*. Quality differentiate at 3 bits and below, where the two learned-allocation attempts (GSQ-RCO's tensor-type assignment, Maya's expert-tiering) measurably beat naive uniform layouts of the same width, and where 2-bit files should be chosen for whether they fit, not for what they preserve — every measurement culture agrees on that cliff. The two caveats that survive scrutiny: pruning moves damage onto the domains its calibration didn't protect (REAP's own tables show it), and any perplexity number on this architecture measured with default batching is suspect (aj9o9's NaN finding). [^aj9o9] [^reap] [^pfeifferj] [^maya]

### Sources (appendix)

[^counts-note]: Downloads/likes snapshot 2026-10-09 via the HF Hub API, deduplicated across the `zai-org/GLM-5.3-Flash` and `-BF16` quantized-from graphs, `zai-org/*` excluded. The previous article body's counts were pulled earlier the same day; both tables are internally consistent.

[^unsloth]: [unsloth/GLM-5.3-Flash-GGUF](https://huggingface.co/unsloth/GLM-5.3-Flash-GGUF) — UD tiers from the repo file listing (UD-IQ1_S through UD-Q4_K_XL, Q8_0, BF16; ~2.5 TB across all tiers).

[^dealign-fp8]: [dealignai/GLM-5.3-Flash-UNCENSORED-FP8](https://huggingface.co/dealignai/GLM-5.3-Flash-UNCENSORED-FP8) — CRACK weight-edit method, MMLU-logit A/B (1,026 questions), HarmBench-320.

[^autotrust-gguf]: [autotrust/GLM-5.3-Flash-GGUF-DGX-Spark](https://huggingface.co/autotrust/GLM-5.3-Flash-GGUF-DGX-Spark) — 2-bit (IQ2_XXS gate/up, Q2_K down) on an 11%-pruned expert set; ds4-eval 35/40; agent-trace PPL 12.4 vs the 744B E192 sibling's 6.2.

[^pfeifferj]: [pfeifferj/GLM-5.3-Flash-GSQ-RCO-GGUF](https://huggingface.co/pfeifferj/GLM-5.3-Flash-GSQ-RCO-GGUF) — GSQ (Gumbel-Softmax Quantization) + RCO (Riemannian Constrained Optimization, per-tensor type assignment under an exact size budget), IST-DASLab methods; MMLU-Pro 2,000 questions paired vs a Q8_0 reference.

[^amd]: [amd/GLM-5.3-Flash-Quark-MXFP4](https://huggingface.co/amd/GLM-5.3-Flash-Quark-MXFP4) — AMD Quark MXFP4, MoE-only weights+activations (shared experts quantized here, unlike NVIDIA's NVFP4), full 1,319-problem GSM8K on MI350X.

[^aj9o9]: [aj9o9/GLM-5.3-Flash-GGUF](https://huggingface.co/aj9o9/GLM-5.3-Flash-GGUF) — the -b 512 NaN/divergence finding and the unsloth KLD comparison table.

[^orca]: [orcarouter/GLM-5.3-Flash-Uncensored-GGUF](https://huggingface.co/orcarouter/GLM-5.3-Flash-Uncensored-GGUF) — Q2→Q6 vs Q8_0 reference on wikitext-2.

[^orca-mlx]: [orcarouter/GLM-5.3-Flash-MLX](https://huggingface.co/orcarouter/GLM-5.3-Flash-MLX) — per-module dynamic OrcaSAQ quant, 2bit-lite→6-bit tables vs FP8.

[^maya]: [peasantsmith/GLM-5.3-Flash-Maya-GGUF](https://huggingface.co/peasantsmith/GLM-5.3-Flash-Maya-GGUF) — Project Maya expert tiering; zero-shot suite + token-level KLD/top-1 vs the FP8 source.

[^canada]: [canada-quant/GLM-5.3-Flash-W4A16-MTP](https://huggingface.co/canada-quant/GLM-5.3-Flash-W4A16-MTP) and its [BENCHMARKS.md](https://huggingface.co/canada-quant/GLM-5.3-Flash-W4A16-MTP/blob/main/BENCHMARKS.md) — including the 2026-10-04 retraction note.

[^e224]: [autotrust/GLM5.3-Flash-E224-DGX-Spark](https://huggingface.co/autotrust/GLM5.3-Flash-E224-DGX-Spark) — NAS-selected 224-of-288 experts, NVFP4, B200-measured.

[^bart]: [bartowski/GLM-5.3-Flash-BF16-GGUF](https://huggingface.co/bartowski/GLM-5.3-Flash-BF16-GGUF) — imatrix quants with published computed layouts; layout-vs-standard KL A/B.

[^reap]: [patrickbdevaney/GLM-5.3-Flash-REAP50-GGUF](https://huggingface.co/patrickbdevaney/GLM-5.3-Flash-REAP50-GGUF) — REAP saliency pruning to 144/288 experts; teacher-forced agreement over 241,516 held-out tokens.

[^onenexus]: [OneNexus/GLM-5.3-Flash-MXFP4](https://huggingface.co/OneNexus/GLM-5.3-Flash-MXFP4) — paired comparison against the AMD Quark checkpoint with protocol and per-question data published.

[^colibri]: [Justvugg/GLM-5.3-Flash-colibri-int4-g64](https://huggingface.co/Justvugg/GLM-5.3-Flash-colibri-int4-g64) — int4 group-64 for the colibrì disk-streaming engine; ~24 s/token floor from disk bandwidth.

[^huihui]: [huihui-ai/Huihui-GLM-5.3-Flash-abliterated-GGUF](https://huggingface.co/huihui-ai/Huihui-GLM-5.3-Flash-abliterated-GGUF) — unsloth files with layers 15-35 ablated.

[^wtdcode]: [wtdcode/GLM-5.3-Flash-AWQ-W4A16](https://huggingface.co/wtdcode/GLM-5.3-Flash-AWQ-W4A16) — AWQ int4 g128 from the dequantized FP8 source, compressed-tensors pack-quantized; card carries scheme detail but no measurements.

Download/like counts: Hugging Face Hub API, 2026-10-09. Popularity ranking method and all precision-scheme verification (scale-tensor counts, config `ignore` lists, `quantization_config` groups) are reproducible from each repo's public `model.safetensors.index.json` and `config.json`.
