---
title: "Five GLM-5.3-Flash NVFP4 checkpoints compared: what's actually different between the quantized versions everyone downloads"
date: 2026-10-09
summary: "RadixArk, NVIDIA, RedHatAI, LibertAI and local-inference-lab all ship an NVFP4 GLM-5.3-Flash that differs far less in size (195-204 GB) than in quantization scheme: W4A4 vs weight-only, what stays BF16, MTP handling, calibration, and one checkpoint whose expert weights are actually retrained — with the tensor-scale math to verify each card's claims."
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

Download/like counts: Hugging Face Hub API, 2026-10-09. Popularity ranking method and all precision-scheme verification (scale-tensor counts, config `ignore` lists, `quantization_config` groups) are reproducible from each repo's public `model.safetensors.index.json` and `config.json`.
