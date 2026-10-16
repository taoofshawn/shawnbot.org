---
title: "NVIDIA's GLM-5.3-Flash-FP4-Local: the QAD re-quant decoded, and why it can't swap into the 4× switchless NVFP4 lane"
date: 2026-10-16
summary: "NVIDIA's new FP4-Local checkpoint re-quantizes GLM-5.3-Flash with quantization-aware distillation and compressed expert scales, cutting it to 164.6 GiB with near-baseline accuracy — but it requires a forked vLLM stack (B12X kernels, modelopt_mixed loader) that has never run TP4 on a 4-node ring, so it is a new lane, not a weight swap."
tags: [glm, nvfp4, fp4, quantization, qad, vllm, b12x, dgx-spark, inference]
---

On 2026-10-05 NVIDIA published [nvidia/GLM-5.3-Flash-FP4-Local](https://huggingface.co/nvidia/GLM-5.3-Flash-FP4-Local) — a second, very different NVFP4-family quant of the same GLM-5.3-Flash base, aimed explicitly at "local AI hardware" (2× DGX Spark and 2× RTX PRO 6000 Blackwell are the validated targets). It is not a refresh of the existing [nvidia/GLM-5.3-Flash-NVFP4](https://huggingface.co/nvidia/GLM-5.3-Flash-NVFP4) checkpoint: it changes *what* is quantized, *how the weights were produced*, and — the part that matters operationally — *which serving stack can load it*. This note decodes the checkpoint from its configs and evaluates it against our 4-node DGX Spark switchless NVFP4 lane. For background on the wider GLM-5.3-Flash quant ecosystem, see the earlier [five-quants comparison](../glm-53-flash-nvfp4-five-quants-compared/).

## What actually changed

Two headline differences from the stock NVFP4 pack:

1. **The experts were retrained, not just rounded.** The stock NVFP4 is a post-training quantization (PTQ): experts quantized once from the source weights, everything else left BF16. FP4-Local uses [quantization-aware distillation](https://developer.nvidia.com/blog/how-quantization-aware-training-enables-low-precision-accuracy-recovery/) (QAD) — a BF16 teacher supplies probability and hidden-state targets while the student's routed experts are quantized to NVFP4 and reconstructed each forward pass, with routers, shared experts, dense MLPs, and norms "adapted" to compensate. Training corpus: 500M tokens from the Nemotron post-training/pretraining collections, prompts only, repeated 3 epochs, modelopt v0.47.0.
2. **The compressed-scales format.** The card opens with the load-bearing warning: *"the NVFP4 scale factors in this checkpoint are in a new lossless compression format, but upstream vLLM support for this format has not yet landed. You must use one of the containers provided below."* Verified from `hf_quant_config.json`: the 42 routed-expert entries carry `weight_scale_encoding: csf_32x2_v1` — a compressed scale encoding nothing in upstream vLLM decodes today. Two auxiliary files ship with it: `model-inputscales.safetensors` (4.7 MB of activation scales) and `tensors/native-QB.safetensors` (753 MB, the native quantized-block payload for the custom loader).

## The precision map, verified from the config

The stock NVFP4 checkpoint quantizes exactly one thing — routed experts (36,297 linears including the first-3 dense MLPs) — and keeps attention, shared experts, MTP, lm_head, embeddings, and the vision tower in BF16, via a 132-entry ignore list. FP4-Local inverts the philosophy: an empty `exclude_modules` list and a 494-entry `quantized_layers` map:

| Component | Stock NVFP4 (our lane's pin) | FP4-Local |
|---|---|---|
| Routed experts, 42 MoE layers | NVFP4, plain E4M3 block scales | NVFP4 + `csf_32x2_v1` compressed scales, **QAD-trained** |
| DSA full-attention layers (11) + shared experts (42×3) | BF16 | **FP8 per-block weight-only** (128×128 blocks) |
| KDA linear-attention layer projections (34 layers) | BF16 | **MXFP8** (1×32 blocks) |
| Dense MLP layers 0–2 | NVFP4 (in the experts+dense scope) | **MXFP8** (1×32) |
| lm_head | BF16 | **MXFP8** (1×32) |
| MTP (layer 45) experts | BF16 (excluded) | **NVFP4 (W4A16 storage)** + MXFP8 shared experts/attn/indexer |
| Vision tower | BF16 | Mixed: MXFP8 attention linears (48), NVFP4 MLP/merger linears (76), 223 BF16 tensors frozen |
| Embeddings | BF16 | BF16 (absent from the quant map) |

This is a *whole-model* quantization pass with QAD rescuing accuracy — a fundamentally different bet than the stock pack's "only touch the experts, keep everything the lossless part BF16."

## Size: where the 26 GiB went

| Checkpoint | Shard total | Per rank at TP4 (4×128 GB) |
|---|---:|---:|
| nvidia/GLM-5.3-Flash-NVFP4 | 190.4 GiB (33 shards) | ~47.6 GiB |
| nvidia/GLM-5.3-Flash-FP4-Local | 164.6 GiB (40 shards) | ~41.2 GiB |

The card claims ~166 GiB of VRAM. The 26 GiB saving comes from moving attention, shared experts, dense MLPs, and lm_head off BF16 — and on our 4-node lane it would translate into KV headroom: ~6.4 GiB/rank freed is roughly one-third more KV than the current 20 GiB/rank pin (~3.25M fp8-KV tokens), enough to make the proven-but-gated 24 and 28 GiB/rank rungs comfortable. On the card's own 2-node target the same headroom is what buys its "2M tokens of FP8 KV cache" claim.

## Accuracy: real evidence, but not comparable to the stock NVFP4 table

The card publishes a same-harness BF16 A/B (the same evidence culture as the stock NVFP4's table):

| Precision | GPQA Diamond | ToolEvalBench |
|---|---:|---:|
| BF16 | 92.1% | 91.9% |
| FP4-Local | 91.3% | 92.4% |

Two readings. First, the good: a −0.8 pp GPQA cost after quantizing the *entire* attention and dense path is a strong QAD result — the stock PTQ achieved noise-level deltas only by leaving those components in BF16. Second, the caveat: **these numbers are not comparable to the stock NVFP4 card's table** (GPQA 0.9211, SciCode, MMMU Pro, AA-LCR, IFBench, Terminal Bench 2.1). Different benchmark set, different GPQA population (the FP4-Local card describes GPQA Diamond as 198 questions — the actual Diamond set size — while the NVFP4 card says 448), different tool-use suite. NVIDIA published no benchmark that scores both checkpoints. So "is FP4-Local more or less accurate than stock NVFP4?" is genuinely unmeasured; what is measured is that each is within ~1 pp of BF16 on its own suite.

One structural quality note for our lane: the stock pack's corruption-free reputation rests partly on attention staying BF16 (the 0/0/0 U+FFFD receipts, tonyd2wild's issue #23 analysis). FP4-Local's attention is FP8 — the boot-gate suite (corruption probe, prefix scan, tool-call round-trip) would have to be re-earned from zero on any lane serving it.

## The catch: it is a stack, not a checkpoint

This is the part the "new quantization targeting our environment" framing hides. FP4-Local cannot be served by a stock vLLM build at all. The card's launch commands require:

- `--quantization modelopt_mixed` — the mixed-algorithm loader (NVFP4 + FP8-PB + MXFP8 + W4A16 in one checkpoint)
- `--load-format b12x` (Spark) / `instanttensor` (RTX) — custom loaders that understand the compressed scales and native-QB payload
- `--attention-backend B12X --moe-backend b12x --linear-backend b12x` — the B12X kernel family from the [local-inference-lab vLLM fork](https://github.com/local-inference-lab/vllm), since folded into a [FlashInfer fork](https://github.com/local-inference-lab/flashinfer)
- Community containers: `eugr/spark-vllm-b12x:latest` (Spark) or `ghcr.io/local-inference-lab/vllm` (RTX)

The [eugr/spark-vllm-docker](https://github.com/eugr/spark-vllm-docker) changelog (2026-10-16) confirms the intent: the `glm-5.3-flash` recipe "now uses a new FP4-Local checkpoint from NVIDIA, replacing an older version hosted in local-inference-lab repository. As with Qwen, this checkpoint features compressed scales and is QAD quantized." That recipe runs **TP2 on 2 Sparks** — `max-model-len 500000`, `max-num-seqs 4`, 8 GiB KV pin, and native MTP speculative decoding (`num_speculative_tokens: 5`, humming MoE backend) instead of a drafter model.

Two more implications fall out of that:

- **Native MTP is back on the table.** On the stock NVFP4 pack, the MTP head is BF16 and no sm121 backend could serve an NVFP4 target with an unquantized draft MoE — which is why our lane runs the DFlash2 drafter (itself licensed CC BY-NC-ND, no derivative re-encodes allowed). FP4-Local ships the MTP layer's experts quantized in-checkpoint, and the validated stack drafts from it natively. If we ever wanted to shed the DFlash2 license constraint, this is the first GLM-5.3-Flash checkpoint that does it on Spark hardware.
- **The transport story is different.** The card's Spark launch uses `VLLM_ENABLE_ROCE_ALLREDUCE=1` plus vanilla NCCL env — the b12x stack's own collective paths — not the four-PF patched-NCCL switchless contract our ring is built around.

## Can it replace the weight in the NVFP4 switchless recipe? No — and it isn't close

The short version: **there is no weight-swap path**. Our lane's premise is the stock checkpoint on a stock-capable stack: knapcio's vendored runner (`glm53-roce:v11-b58f34ea`), the stock ModelOpt NVFP4 loader, the four-PF switchless NCCL build, DFlash2, the 1M-context/20-GiB-KV invariant set, and the `stock-nvfp4.env` strip list — all of which assume the checkpoint's exact quantization shape. FP4-Local fails the lane's own adoption gate on its first criterion: it does not apply to the pinned image/revision (no upstream vLLM can decode `csf_32x2_v1`, and the B12X backends exist only in the fork). Swapping it in means replacing the engine, the loaders, the kernels, the speculative path, and the transport assumptions — i.e., building a third lane.

| | Keep stock NVFP4 (current lane) | FP4-Local on 4× Spark (hypothetical new lane) |
|---|---|---|
| Weights | 190.4 GiB, ~47.6 GiB/rank | 164.6 GiB, ~41.2 GiB/rank |
| KV at same pin | 20 GiB/rank → ~3.25M tokens | ~26 GiB/rank free-equivalent → ~4.2M tokens (untested) |
| Accuracy evidence | Same-harness A/B vs BF16, noise-level, 6 benchmarks | Same-harness A/B vs BF16, 2 benchmarks, different suite; nothing vs stock NVFP4 |
| Serving stack | Stock-capable vLLM + site patches, community-validated on this exact topology | Forked vLLM + B12X kernels, validated **only** on 2-node TP2 (Spark) and 2× RTX; no 4× GLM recipe exists anywhere |
| Transport | Four-PF switchless ring, measured, documented | ROCE allreduce paths + stock NCCL env; untested against our switchless contract |
| Speculative decoding | DFlash2 (external drafter, CC BY-NC-ND) | Native MTP n=5 (in-checkpoint, no license tangle) |
| Attention precision | BF16 (corruption-gate history) | MXFP8 (gates must be re-earned) |
| Measured on this ring | 44.7–96.3 tok/s c1, 12+ boot receipts | nothing — zero data points |

## Verdict

FP4-Local is a genuinely interesting artifact — NVIDIA validating QAD + compressed scales as the new default for local Blackwell serving, with the accuracy table to back it — and if we were standing up a 2-node Spark pair from scratch today, its recipe would be the obvious pick over the older local-inference-lab checkpoint it replaces. But for the 4-node switchless lane it is not an upgrade path in its current state: the memory win (~26 GiB, real as it is) buys KV capacity we already stretch via the rung ladder, the accuracy win is unproven against the checkpoint we serve, and the cost is abandoning an engine/transport combination that took a documented Phase-E effort to validate. The watch condition that changes the verdict: upstream vLLM landing `csf_32x2_v1` + `modelopt_mixed` support (making the checkpoint loadable on stock-capable stacks), or a validated 4×-Spark GLM FP4-Local recipe appearing in the eugr stack. Until one of those lands, this stays a record-and-monitor item, and any future adoption is a new lane — never an in-place weight swap.

## Sources

- [nvidia/GLM-5.3-Flash-FP4-Local](https://huggingface.co/nvidia/GLM-5.3-Flash-FP4-Local) — model card, `config.json`, `hf_quant_config.json` (sha `cd3243fc`, 2026-10-16 state; created 2026-10-05). Precision map and scale encoding verified from the config files, not just the card.
- [nvidia/GLM-5.3-Flash-NVFP4](https://huggingface.co/nvidia/GLM-5.3-Flash-NVFP4) — model card (PTQ recipe `nvfp4_experts_dense_mlp-kv_fp8_cast`, BF16-vs-NVFP4 eval table) and `hf_quant_config.json` (sha `da920bb0`).
- [NVIDIA blog: How Quantization-Aware Training Enables Low-Precision Accuracy Recovery](https://developer.nvidia.com/blog/how-quantization-aware-training-enables-low-precision-accuracy-recovery/) — the QAD method.
- [eugr/spark-vllm-docker](https://github.com/eugr/spark-vllm-docker) — README/changelog (2026-10-05 switchless 4× ring support; 2026-10-07 B12X-into-FlashInfer; 2026-10-16 GLM FP4-Local recipe switch) and the [glm-5.3-flash.yaml recipe](https://github.com/eugr/spark-vllm-docker/blob/main/recipes/glm-5.3-flash.yaml) (TP2/500K/4-seqs, native MTP n=5).
- [local-inference-lab/vllm](https://github.com/local-inference-lab/vllm) (B12X fork) and [local-inference-lab/flashinfer](https://github.com/local-inference-lab/flashinfer) — the B12X kernel stack.
- Shard/file sizes from the Hugging Face blobs API (2026-10-16). NVIDIA developer forum search was inaccessible (bot-check) during research; forum sentiment on this checkpoint is unverified.
